import 'dart:convert';
import 'dart:io';
import 'dart:math' as m;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart';
import 'package:printing/printing.dart' show Printing;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(VordooApp(initial: await _incoming()));
}

/// A PDF handed to the app by Android's "Open with" (null when launched normally).
Future<Uint8List?> _incoming() async {
  try {
    return await const MethodChannel('vordoo/intent').invokeMethod<Uint8List>('get');
  } catch (_) {
    return null;
  }
}

class VordooApp extends StatelessWidget {
  const VordooApp({super.key, this.initial});
  final Uint8List? initial;
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vordoo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF5B3DF5), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF8D78FF), brightness: Brightness.dark, useMaterial3: true),
        home: Home(initial: initial),
      );
}

typedef PageImg = (Uint8List, double, double);

Future<Uint8List> makePdf(List<PageImg> pages) async {
  final d = pw.Document();
  for (final (png, w, h) in pages) {
    d.addPage(pw.Page(
      pageFormat: PdfPageFormat(w, h),
      margin: pw.EdgeInsets.zero,
      build: (_) => png.isEmpty ? pw.SizedBox() : pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.fill),
    ));
  }
  return d.save();
}

// Page rendering runs one at a time (Android's renderer opens a single page at once).
Future<void> _lock = Future.value();
Future<T> _serial<T>(Future<T> Function() f) {
  final r = _lock.then((_) => f());
  _lock = r.then((_) {}, onError: (_) {});
  return r;
}

// Syncfusion documents (text layer, annotations, saving) are opened once per source file.
final _sfc = Expando<sf.PdfDocument>();
sf.PdfDocument _sf(Uint8List b) => _sfc[b] ??= sf.PdfDocument(inputBytes: b);

const _pal = [0xFFFFD400, 0xFFFF3B5C, 0xFF1FA971, 0xFF2F6BFF, 0xFF111111];

/// kind: 0 pen, 1 highlighter, 2 text, 3 line, 4 arrow, 5 rect, 6 oval, 7 redact, 8 signature,
/// 9 text highlight, 10 text underline, 11 text strikeout, 12 selection preview. Coordinates are 0..1 of the page.
class Ann {
  Ann(this.kind, this.rgb, this.pts, {this.text, this.strokes, this.rects});
  final int kind;
  final int rgb;
  final List<Offset> pts;
  final String? text;
  final List<List<Offset>>? strokes;
  final List<Rect>? rects;
  Color get color => Color(rgb);
}

class _W {
  _W(this.r, this.t);
  final Rect r; // unrotated, 0..1 of the page
  final String t;
}

/// One page of the working document: a PDF page, an image, or a blank sheet.
class P {
  P({this.doc, this.i = 0, this.img, this.bytes});
  final PdfDocument? doc;
  final int i; // 1-based page number in its source PDF
  final Uint8List? img;
  final Uint8List? bytes; // source PDF bytes
  int rot = 0;
  final ann = <Ann>[];
  Future<_Pg>? f;
  List<_W>? words;
}

class _Pg {
  _Pg(this.png, this.size);
  final Uint8List png;
  final Size size;
}

Rect _nr(Rect b, Size s) => Rect.fromLTRB(b.left / s.width, b.top / s.height, b.right / s.width, b.bottom / s.height);

Rect _rot(Rect r, int k) {
  Offset f(Offset o) => k == 1 ? Offset(1 - o.dy, o.dx) : k == 2 ? Offset(1 - o.dx, 1 - o.dy) : k == 3 ? Offset(o.dy, 1 - o.dx) : o;
  return Rect.fromPoints(f(r.topLeft), f(r.bottomRight));
}

void paintAnn(Canvas c, Size s, List<Ann> list) {
  Offset o(Offset p) => Offset(p.dx * s.width, p.dy * s.height);
  for (final a in list) {
    final p0 = o(a.pts.first), p1 = o(a.pts.last);
    final st = Paint()
      ..color = a.color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.width * .004;
    final k = a.kind;
    if (k == 2) {
      (TextPainter(text: TextSpan(text: a.text, style: TextStyle(color: a.color, fontSize: s.width * .03)), textDirection: TextDirection.ltr)
            ..layout(maxWidth: s.width * .9))
          .paint(c, p0);
    } else if (k < 2) {
      if (k == 1) {
        st.color = a.color.withAlpha(90);
        st.strokeWidth = s.width * .025;
        st.strokeCap = StrokeCap.butt;
      }
      final path = Path()..moveTo(p0.dx, p0.dy);
      for (final q in a.pts.skip(1)) {
        path.lineTo(q.dx * s.width, q.dy * s.height);
      }
      if (a.pts.length == 1) path.lineTo(p0.dx + .1, p0.dy);
      c.drawPath(path, st);
    } else if (k == 3 || k == 4) {
      c.drawLine(p0, p1, st);
      if (k == 4) {
        final t = m.atan2(p1.dy - p0.dy, p1.dx - p0.dx), len = s.width * .03;
        for (final d in [2.7, -2.7]) {
          c.drawLine(p1, p1 + Offset(m.cos(t + d), m.sin(t + d)) * len, st);
        }
      }
    } else if (k == 5) {
      c.drawRect(Rect.fromPoints(p0, p1), st);
    } else if (k == 6) {
      c.drawOval(Rect.fromPoints(p0, p1), st);
    } else if (k == 7) {
      c.drawRect(Rect.fromPoints(p0, p1), Paint()..color = Colors.black);
    } else if (k == 8) {
      final w = s.width * .28, h = w / 3;
      st.color = const Color(0xFF14206B);
      st.strokeWidth = s.width * .003;
      for (final ks in a.strokes!) {
        final path = Path();
        for (var j = 0; j < ks.length; j++) {
          final q = p0 + Offset(ks[j].dx * w, ks[j].dy * h);
          if (j == 0) {
            path.moveTo(q.dx, q.dy);
          } else {
            path.lineTo(q.dx, q.dy);
          }
        }
        c.drawPath(path, st);
      }
    } else {
      for (final r0 in a.rects!) {
        final r = Rect.fromLTRB(r0.left * s.width, r0.top * s.height, r0.right * s.width, r0.bottom * s.height);
        if (k == 9) {
          c.drawRect(r, Paint()..color = a.color.withAlpha(90));
        } else if (k == 12) {
          c.drawRect(r, Paint()..color = const Color(0x552F6BFF));
        } else {
          st.strokeWidth = s.width * .002;
          c.drawLine(k == 10 ? r.bottomLeft : r.centerLeft, k == 10 ? r.bottomRight : r.centerRight, st);
        }
      }
    }
  }
}

class _Painter extends CustomPainter {
  _Painter(this.list);
  final List<Ann> list;
  @override
  void paint(Canvas c, Size s) => paintAnn(c, s, list);
  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _HitPainter extends CustomPainter {
  _HitPainter(this.rs, this.cur);
  final List<Rect> rs;
  final Rect? cur;
  @override
  void paint(Canvas c, Size s) {
    Rect z(Rect r) => Rect.fromLTRB(r.left * s.width, r.top * s.height, r.right * s.width, r.bottom * s.height);
    for (final r in rs) {
      c.drawRect(z(r), Paint()..color = const Color(0x66FFA000));
    }
    if (cur != null) c.drawRect(z(cur!).inflate(1), Paint()..color = const Color(0x99FF6D00));
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

class _SigPainter extends CustomPainter {
  _SigPainter(this.ks);
  final List<List<Offset>> ks;
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..color = const Color(0xFF14206B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final k in ks) {
      final path = Path();
      for (var j = 0; j < k.length; j++) {
        final q = Offset(k[j].dx * s.width, k[j].dy * s.height);
        if (j == 0) {
          path.moveTo(q.dx, q.dy);
        } else {
          path.lineTo(q.dx, q.dy);
        }
      }
      c.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}

Future<String?> _askPassword(BuildContext c, [String title = 'This PDF is password protected']) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
          controller: ctl, obscureText: true, autofocus: true, decoration: const InputDecoration(hintText: 'Password'), onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('OK')),
      ],
    ),
  );
}

/// Opens PDF bytes; asks for the password when the file is protected.
Future<List<P>?> openPdfBytes(BuildContext c, Uint8List b) async {
  try {
    final d = await PdfDocument.openData(b);
    return [for (var i = 1; i <= d.pagesCount; i++) P(doc: d, i: i, bytes: b)];
  } catch (_) {
    for (var tries = 0; tries < 3 && c.mounted; tries++) {
      final pass = await _askPassword(c);
      if (pass == null) return null;
      try {
        final d = sf.PdfDocument(inputBytes: b, password: pass);
        d.security.userPassword = '';
        d.security.ownerPassword = '';
        final out = Uint8List.fromList(await d.save());
        d.dispose();
        final pd = await PdfDocument.openData(out);
        return [for (var i = 1; i <= pd.pagesCount; i++) P(doc: pd, i: i, bytes: out)];
      } catch (_) {
        if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Wrong password or unreadable file')));
      }
    }
    return null;
  }
}

class Home extends StatefulWidget {
  const Home({super.key, this.initial});
  final Uint8List? initial;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  @override
  void initState() {
    super.initState();
    final b = widget.initial;
    if (b != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ps = await openPdfBytes(context, b);
        if (ps != null && mounted) await _go(ps, 'Document');
      });
    }
  }

  Future<void> _go(List<P> pages, String n) async {
    if (pages.isNotEmpty && mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => Reader(pages: pages, name: n)));
    }
  }

  Future<void> _pdf() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
    final f = r?.files.single;
    if (f?.bytes == null || !mounted) return;
    final ps = await openPdfBytes(context, f!.bytes!);
    if (ps != null) await _go(ps, f.name.replaceAll(RegExp(r'\.[^.]+$'), ''));
  }

  Future<void> _img(bool cam) async {
    final b = cam
        ? await (await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90))?.readAsBytes()
        : (await FilePicker.platform.pickFiles(type: FileType.image, withData: true))?.files.single.bytes;
    if (b != null) await _go([P(img: b)], cam ? 'Scan' : 'Image');
  }

  @override
  Widget build(BuildContext c) {
    Widget b(String t, IconData i, VoidCallback f, [bool pri = false]) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: SizedBox(
            width: 240,
            child: pri
                ? FilledButton.icon(onPressed: f, icon: Icon(i), label: Text(t))
                : OutlinedButton.icon(onPressed: f, icon: Icon(i), label: Text(t))));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Vordoo', style: Theme.of(c).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
            const Text('Read, mark up, sign and edit PDFs.'),
            const SizedBox(height: 16),
            b('Open PDF', Icons.folder_open, _pdf, true),
            b('New blank PDF', Icons.note_add_outlined, () => _go([P()], 'Untitled')),
            b('Image to PDF', Icons.image_outlined, () => _img(false)),
            b('Scan to PDF', Icons.document_scanner_outlined, () => _img(true)),
          ]),
        ),
      ),
    );
  }
}

const _inv = ColorFilter.matrix(<double>[-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]);
const _kinds = {'pen': 0, 'hl': 1, 'ul': 3, 'line': 3, 'arrow': 4, 'rect': 5, 'oval': 6, 'redact': 7};
const _tools = <(String, IconData, String)>[
  ('scroll', Icons.pan_tool_alt_outlined, 'Scroll'),
  ('pen', Icons.edit_outlined, 'Pen'),
  ('hl', Icons.highlight_outlined, 'Highlight'),
  ('ul', Icons.format_underlined, 'Underline or strikeout line'),
  ('line', Icons.horizontal_rule, 'Line'),
  ('arrow', Icons.arrow_right_alt, 'Arrow'),
  ('rect', Icons.crop_square, 'Rectangle'),
  ('oval', Icons.circle_outlined, 'Oval'),
  ('text', Icons.text_fields, 'Text'),
  ('sign', Icons.draw_outlined, 'Sign'),
  ('erase', Icons.cleaning_services_outlined, 'Erase'),
  ('redact', Icons.visibility_off_outlined, 'Redact'),
];

class Reader extends StatefulWidget {
  const Reader({super.key, required this.pages, required this.name});
  final List<P> pages;
  final String name;
  @override
  State<Reader> createState() => _RS();
}

class _RS extends State<Reader> {
  late final List<P> pages = widget.pages;
  final marks = <P>{};
  final hist = <(P, Ann)>[];
  final hits = <(int, Rect)>[];
  final isc = ItemScrollController();
  final ipl = ItemPositionsListener.create();
  final tc = TextEditingController();
  String tool = 'scroll', stamp = '✓', tmk = 'hl';
  int color = _pal[0], cur = 0, hi = -1;
  double zoom = 1, _sy = 0;
  Offset _st = Offset.zero;
  bool night = false, _fy = false, searching = false;
  Ann? live;
  List<List<Offset>>? sig;

  int get _ink => color == _pal[0] ? 0xFF111111 : color;

  void say(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final s = p.getString('sig');
      if (s != null) {
        sig = [
          for (final k in jsonDecode(s) as List) [for (final q in k as List) Offset((q[0] as num).toDouble(), (q[1] as num).toDouble())]
        ];
      }
    });
    ipl.itemPositions.addListener(() {
      final v = ipl.itemPositions.value.where((e) => e.itemTrailingEdge > .35);
      if (v.isEmpty) return;
      final n = v.map((e) => e.index).reduce(m.min);
      if (n != cur && n < pages.length && mounted) setState(() => cur = n);
    });
  }

  @override
  void dispose() {
    tc.dispose();
    for (final d in pages.map((p) => p.doc).toSet()) {
      d?.close();
    }
    super.dispose();
  }

  Future<_Pg> _pg(P p) => p.f ??= _render(p);

  Future<_Pg> _render(P p) async {
    if (p.doc != null) {
      return _serial<_Pg>(() async {
        final g = await p.doc!.getPage(p.i);
        final r = await g.render(width: g.width * 2, height: g.height * 2, format: PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
        final s = Size(g.width, g.height);
        await g.close();
        return _Pg(r!.bytes, s);
      });
    }
    if (p.img != null) {
      final im = (await (await ui.instantiateImageCodec(p.img!)).getNextFrame()).image;
      return _Pg(p.img!, Size(im.width.toDouble(), im.height.toDouble()));
    }
    return _Pg(Uint8List(0), const Size(595, 842));
  }

  /// Words of a PDF page with their bounds (from the real text layer).
  Future<List<_W>> _words(P p) async {
    if (p.words != null) return p.words!;
    final out = <_W>[];
    if (p.bytes != null) {
      final d = _sf(p.bytes!);
      final sz = d.pages[p.i - 1].size;
      final lines = sf.PdfTextExtractor(d).extractTextLines(startPageIndex: p.i - 1, endPageIndex: p.i - 1);
      for (final l in lines) {
        for (final w in l.wordCollection) {
          out.add(_W(_nr(w.bounds, sz), w.text));
        }
      }
    }
    return p.words = out;
  }

  Future<void> _find(String s) async {
    hits.clear();
    hi = -1;
    final q = s.trim();
    if (q.isEmpty) {
      setState(() {});
      return;
    }
    say('Searching…');
    for (var k = 0; k < pages.length; k++) {
      final p = pages[k];
      if (p.bytes == null) continue;
      final d = _sf(p.bytes!);
      final sz = d.pages[p.i - 1].size;
      for (final it in sf.PdfTextExtractor(d).findText([q], startPageIndex: p.i - 1, endPageIndex: p.i - 1)) {
        hits.add((k, _nr(it.bounds, sz)));
      }
      if (k % 5 == 4) await Future<void>.delayed(Duration.zero);
    }
    if (!mounted) return;
    setState(() => hi = hits.isEmpty ? -1 : 0);
    if (hits.isEmpty) {
      say('No matches');
    } else {
      isc.jumpTo(index: hits[0].$1);
    }
  }

  void _hop(int d) {
    if (hits.isEmpty) return;
    setState(() => hi = (hi + d) % hits.length);
    isc.jumpTo(index: hits[hi].$1);
  }

  void _add(P p, Ann a) => setState(() {
        p.ann.add(a);
        hist.add((p, a));
      });

  void _end(P p) {
    final l = live;
    live = null;
    if (l != null && l.kind == 12) _markup(p, l);
  }

  /// Turns a dragged selection into a text-snapped highlight / underline / strikeout.
  Future<void> _markup(P p, Ann sel) async {
    final box = sel.rects![0];
    setState(() => p.ann.remove(sel));
    final ws = await _words(p);
    final hit = [for (final w in ws) if (_rot(w.r, p.rot).overlaps(box)) _rot(w.r, p.rot)];
    if (hit.isEmpty) {
      if (mounted) say('No text found there');
      return;
    }
    final out = <Rect>[];
    for (final r in hit) {
      if (out.isNotEmpty && (out.last.center.dy - r.center.dy).abs() < r.height * .5) {
        out[out.length - 1] = out.last.expandToInclude(r);
      } else {
        out.add(r);
      }
    }
    if (mounted) _add(p, Ann(tmk == 'hl' ? 9 : tmk == 'ul' ? 10 : 11, color, [box.topLeft], rects: out));
  }

  Future<String?> _ask() async {
    final ctl = TextEditingController();
    final t = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        content: TextField(controller: ctl, autofocus: true, maxLines: null, decoration: const InputDecoration(hintText: 'Type text')),
        actions: [TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Add'))],
      ),
    );
    return t == null || t.trim().isEmpty ? null : t.trim();
  }

  Future<void> _pad() async {
    final ks = <List<Offset>>[];
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, set) => AlertDialog(
          title: const Text('Draw your signature'),
          content: Container(
            width: 300,
            height: 100,
            color: Colors.white,
            child: GestureDetector(
              onPanStart: (e) => set(() => ks.add([Offset(e.localPosition.dx / 300, e.localPosition.dy / 100)])),
              onPanUpdate: (e) => set(() => ks.last.add(Offset(e.localPosition.dx / 300, e.localPosition.dy / 100))),
              child: CustomPaint(painter: _SigPainter(ks), size: const Size(300, 100)),
            ),
          ),
          actions: [
            TextButton(onPressed: () => set(ks.clear), child: const Text('Clear')),
            FilledButton(
              onPressed: () async {
                final k = ks.where((s) => s.length > 1).toList();
                if (k.isNotEmpty) {
                  sig = k;
                  final sp = await SharedPreferences.getInstance();
                  await sp.setString('sig', jsonEncode([for (final s in k) [for (final q in s) [q.dx, q.dy]]]));
                }
                if (ctx2.mounted) Navigator.pop(ctx2);
              },
              child: const Text('Use'),
            ),
          ],
        ),
      ),
    );
  }

  bool _hit(Ann a, Offset n) {
    if (a.kind < 2) return a.pts.any((q) => (q - n).distance < .03);
    if (a.kind >= 9) return a.rects!.any((r) => r.inflate(.01).contains(n));
    final o = a.pts.first;
    final r = a.kind == 2 || a.kind == 8 ? Rect.fromLTWH(o.dx, o.dy, .35, .06) : Rect.fromPoints(o, a.pts.last);
    return r.inflate(.02).contains(n);
  }

  Future<void> _tap(P p, Offset n) async {
    if (tool == 'text') {
      final t = await _ask();
      if (t != null) _add(p, Ann(2, _ink, [n], text: t));
    } else if (tool == 'stamp') {
      _add(p, Ann(2, _ink, [n], text: stamp == 'date' ? DateTime.now().toString().substring(0, 10) : stamp));
    } else if (tool == 'sign') {
      if (sig == null) await _pad();
      if (sig != null) _add(p, Ann(8, color, [Offset(m.min(n.dx, .7), n.dy)], strokes: sig));
    } else if (tool == 'erase') {
      Ann? f;
      for (final a in p.ann) {
        if (_hit(a, n)) f = a;
      }
      if (f != null) setState(() => p.ann.remove(f));
    }
  }

  Widget _item(int i, double w) {
    final p = pages[i];
    return FutureBuilder<_Pg>(
      future: _pg(p),
      builder: (_, s) {
        if (!s.hasData) return SizedBox(height: w * 1.3, child: const Center(child: CircularProgressIndicator()));
        final g = s.data!, odd = p.rot.isOdd;
        final h = w * (odd ? g.size.width / g.size.height : g.size.height / g.size.width);
        Offset nrm(Offset o) => Offset(o.dx / w, o.dy / h);
        final dr = _kinds.containsKey(tool) || tool == 'tm';
        Widget img = g.png.isEmpty
            ? const ColoredBox(color: Colors.white)
            : RotatedBox(quarterTurns: p.rot, child: Image.memory(g.png, width: odd ? h : w, height: odd ? w : h, fit: BoxFit.fill, gaplessPlayback: true));
        if (night) img = ColorFiltered(colorFilter: _inv, child: img);
        final found = [for (final x in hits) if (x.$1 == i) _rot(x.$2, p.rot)];
        final now = hi >= 0 && hits[hi].$1 == i ? _rot(hits[hi].$2, p.rot) : null;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(children: [
              Positioned.fill(child: img),
              if (found.isNotEmpty) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _HitPainter(found, now)))),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: tool == 'scroll',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: dr
                        ? (d) {
                            final n = nrm(d.localPosition);
                            if (tool == 'tm') {
                              final a = Ann(12, 0, [n], rects: [Rect.fromPoints(n, n)]);
                              _st = n;
                              live = a;
                              setState(() => p.ann.add(a));
                              return;
                            }
                            final a = Ann(_kinds[tool]!, color, tool == 'pen' || tool == 'hl' ? [n] : [n, n]);
                            _fy = tool == 'ul';
                            _sy = n.dy;
                            live = a;
                            _add(p, a);
                          }
                        : null,
                    onPanUpdate: dr
                        ? (d) {
                            final l = live;
                            if (l == null) return;
                            final n = nrm(d.localPosition);
                            setState(() {
                              if (l.kind == 12) {
                                l.rects![0] = Rect.fromPoints(_st, n);
                              } else if (l.kind < 2) {
                                l.pts.add(n);
                              } else {
                                l.pts[1] = _fy ? Offset(n.dx, _sy) : n;
                              }
                            });
                          }
                        : null,
                    onPanEnd: (_) => _end(p),
                    onPanCancel: () => _end(p),
                    onTapUp: ['text', 'stamp', 'sign', 'erase'].contains(tool) ? (d) => _tap(p, nrm(d.localPosition)) : null,
                    child: CustomPaint(painter: _Painter(p.ann)),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }

  /// One page as a flat image (rotation, annotations and redactions burned in).
  Future<PageImg> _flatPage(P p, double q) async {
    final g = await _pg(p);
    final odd = p.rot.isOdd;
    final pw0 = odd ? g.size.height : g.size.width, ph0 = odd ? g.size.width : g.size.height;
    final k = (p.img != null ? 1.0 : 2.0) * q;
    final w = (pw0 * k).round(), h = (ph0 * k).round();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    if (g.png.isNotEmpty) {
      final im = (await (await ui.instantiateImageCodec(g.png)).getNextFrame()).image;
      final iw = im.width.toDouble(), ih = im.height.toDouble();
      c.save();
      c.scale(w / (odd ? ih : iw));
      if (p.rot == 1) {
        c.translate(ih, 0);
        c.rotate(m.pi / 2);
      } else if (p.rot == 2) {
        c.translate(iw, ih);
        c.rotate(m.pi);
      } else if (p.rot == 3) {
        c.translate(0, iw);
        c.rotate(-m.pi / 2);
      }
      c.drawImage(im, Offset.zero, Paint());
      c.restore();
    }
    paintAnn(c, Size(w.toDouble(), h.toDouble()), p.ann);
    final bd = await (await rec.endRecording().toImage(w, h)).toByteData(format: ui.ImageByteFormat.png);
    return (bd!.buffer.asUint8List(), pw0, ph0);
  }

  Future<List<PageImg>> _flat(double q) async => [for (final p in pages) await _flatPage(p, q)];

  Future<(Uint8List, Size)> _textPng(String t, int rgb, double pageW) async {
    const z = 3.0;
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(color: Color(rgb), fontSize: pageW * .03 * z)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: pageW * .9 * z);
    final rec = ui.PictureRecorder();
    tp.paint(Canvas(rec), Offset.zero);
    final w = tp.width.ceil() + 2, h = tp.height.ceil() + 2;
    final bd = await (await rec.endRecording().toImage(w, h)).toByteData(format: ui.ImageByteFormat.png);
    return (bd!.buffer.asUint8List(), Size(w / z, h / z));
  }

  /// Adds one page's annotations to the output page: standard PDF annotations where they exist,
  /// vector drawing for pen and signature, and an image for text (so any script is kept).
  Future<void> _vector(sf.PdfPage page, P p, double w, double h) async {
    final gr = page.graphics;
    Rect px(Rect r) => Rect.fromLTRB(r.left * w, r.top * h, r.right * w, r.bottom * h);
    for (final a in p.ann) {
      final c = sf.PdfColor((a.rgb >> 16) & 255, (a.rgb >> 8) & 255, a.rgb & 255);
      final p0 = Offset(a.pts.first.dx * w, a.pts.first.dy * h), p1 = Offset(a.pts.last.dx * w, a.pts.last.dy * h);
      final k = a.kind;
      if (k < 2) {
        final st = gr.save();
        if (k == 1) gr.setTransparency(.35);
        final pen = sf.PdfPen(c, width: w * (k == 1 ? .025 : .004));
        for (var j = 1; j < a.pts.length; j++) {
          gr.drawLine(pen, Offset(a.pts[j - 1].dx * w, a.pts[j - 1].dy * h), Offset(a.pts[j].dx * w, a.pts[j].dy * h));
        }
        gr.restore(st);
      } else if (k == 2) {
        final t = await _textPng(a.text!, a.rgb, w);
        gr.drawImage(sf.PdfBitmap(t.$1), Rect.fromLTWH(p0.dx, p0.dy, t.$2.width, t.$2.height));
      } else if (k == 3 || k == 4) {
        final pts = [p0.dx.round(), p0.dy.round(), p1.dx.round(), p1.dy.round()];
        final bd = sf.PdfAnnotationBorder(w * .004);
        page.annotations.add(k == 4
            ? sf.PdfLineAnnotation(pts, 'Arrow', color: c, border: bd, endLineStyle: sf.PdfLineEndingStyle.openArrow, setAppearance: true)
            : sf.PdfLineAnnotation(pts, 'Line', color: c, border: bd, setAppearance: true));
      } else if (k == 5) {
        page.annotations.add(sf.PdfRectangleAnnotation(Rect.fromPoints(p0, p1), 'Rectangle', color: c, border: sf.PdfAnnotationBorder(w * .004), setAppearance: true));
      } else if (k == 6) {
        page.annotations.add(sf.PdfEllipseAnnotation(Rect.fromPoints(p0, p1), 'Ellipse', color: c, border: sf.PdfAnnotationBorder(w * .004), setAppearance: true));
      } else if (k == 8) {
        final pen = sf.PdfPen(sf.PdfColor(20, 32, 107), width: w * .003);
        final sw = w * .28, sh = sw / 3;
        for (final s in a.strokes!) {
          for (var j = 1; j < s.length; j++) {
            gr.drawLine(pen, p0 + Offset(s[j - 1].dx * sw, s[j - 1].dy * sh), p0 + Offset(s[j].dx * sw, s[j].dy * sh));
          }
        }
      } else if (k >= 9 && k <= 11) {
        final rs = [for (final r in a.rects!) px(r)];
        final mk = sf.PdfTextMarkupAnnotation(
          rs.first,
          'Markup',
          c,
          textMarkupAnnotationType: k == 9
              ? sf.PdfTextMarkupAnnotationType.highlight
              : k == 10
                  ? sf.PdfTextMarkupAnnotationType.underline
                  : sf.PdfTextMarkupAnnotationType.strikethrough,
          setAppearance: true,
        );
        mk.boundsCollection = rs;
        page.annotations.add(mk);
      }
    }
  }

  /// Builds the PDF with real text, vector pages and standard annotations.
  /// Image pages and pages with redactions are flattened so nothing hides under the black boxes.
  Future<Uint8List> _editable(String? pass) async {
    final out = sf.PdfDocument();
    out.pageSettings.margins.all = 0;
    for (final p in pages) {
      final g = await _pg(p);
      final odd = p.rot.isOdd;
      final w = odd ? g.size.height : g.size.width, h = odd ? g.size.width : g.size.height;
      final sec = out.sections!.add();
      sec.pageSettings.size = Size(w, h);
      sec.pageSettings.margins.all = 0;
      final page = sec.pages.add();
      final gr = page.graphics;
      if (p.img != null || p.ann.any((a) => a.kind == 7)) {
        final flat = await _flatPage(p, 1);
        gr.drawImage(sf.PdfBitmap(flat.$1), Rect.fromLTWH(0, 0, w, h));
        continue;
      }
      if (p.bytes != null) {
        final t = _sf(p.bytes!).pages[p.i - 1].createTemplate();
        final st = gr.save();
        if (p.rot == 1) {
          gr.translateTransform(w, 0);
          gr.rotateTransform(90);
        } else if (p.rot == 2) {
          gr.translateTransform(w, h);
          gr.rotateTransform(180);
        } else if (p.rot == 3) {
          gr.translateTransform(0, h);
          gr.rotateTransform(270);
        }
        gr.drawPdfTemplate(t, Offset.zero);
        gr.restore(st);
      }
      await _vector(page, p, w, h);
    }
    if (pass != null) out.security.userPassword = pass;
    final b = Uint8List.fromList(await out.save());
    out.dispose();
    return b;
  }

  Future<void> _export(String a) async {
    try {
      say('Preparing…');
      if (a == 'png' || a == 'small') {
        final pg = await _flat(a == 'png' ? 1 : .55);
        if (a == 'png') {
          final dir = await getTemporaryDirectory();
          final fs = <XFile>[];
          for (var i = 0; i < pg.length; i++) {
            final f = File('${dir.path}/${widget.name}-${i + 1}.png');
            await f.writeAsBytes(pg[i].$1);
            fs.add(XFile(f.path));
          }
          await Share.shareXFiles(fs);
        } else {
          await Printing.sharePdf(bytes: await makePdf(pg), filename: '${widget.name}-small.pdf');
        }
      } else {
        String? pass;
        if (a == 'prot') {
          pass = await _askPassword(context, 'Set a password');
          if (pass == null || pass.isEmpty) return;
        }
        final b = await _editable(pass);
        if (a == 'print') {
          await Printing.layoutPdf(onLayout: (_) async => b);
        } else {
          await Printing.sharePdf(bytes: b, filename: '${widget.name}-vordoo.pdf');
        }
      }
    } catch (e) {
      if (mounted) say('Could not create the PDF: $e');
    }
  }

  Future<void> _act(String a) async {
    if (a == 'merge') {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
      final b = r?.files.single.bytes;
      if (b == null || !mounted) return;
      final ps = await openPdfBytes(context, b);
      if (ps != null && mounted) setState(() => pages.addAll(ps));
    } else if (a == 'scan') {
      final b = await (await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90))?.readAsBytes();
      if (b != null) setState(() => pages.add(P(img: b)));
    } else if (a == 'blank') {
      setState(() => pages.add(P()));
    } else if (a == 'mark') {
      final ix = [for (var i = 0; i < pages.length; i++) if (marks.contains(pages[i])) i];
      if (ix.isNotEmpty) isc.jumpTo(index: ix.firstWhere((i) => i > cur, orElse: () => ix.first));
    } else {
      await _export(a);
    }
  }

  void _sheet() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => StatefulBuilder(
          builder: (ctx, set) => SizedBox(
            height: MediaQuery.of(ctx).size.height * .75,
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: pages.length,
              onReorder: (a, b) {
                if (b > a) b--;
                set(() => setState(() {
                      pages.insert(b, pages.removeAt(a));
                      hits.clear();
                      hi = -1;
                    }));
              },
              itemBuilder: (_, i) {
                final p = pages[i];
                return ListTile(
                  key: ObjectKey(p),
                  leading: SizedBox(
                    width: 44,
                    child: FutureBuilder<_Pg>(
                      future: _pg(p),
                      builder: (_, s) => s.hasData && s.data!.png.isNotEmpty ? Image.memory(s.data!.png, fit: BoxFit.contain) : const Icon(Icons.description_outlined),
                    ),
                  ),
                  title: Text('Page ${i + 1}'),
                  onTap: () {
                    Navigator.pop(ctx);
                    isc.jumpTo(index: i);
                  },
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                        icon: Icon(marks.contains(p) ? Icons.star : Icons.star_border),
                        onPressed: () => set(() => setState(() => marks.contains(p) ? marks.remove(p) : marks.add(p)))),
                    IconButton(icon: const Icon(Icons.rotate_right), onPressed: () => set(() => setState(() => p.rot = (p.rot + 1) % 4))),
                    IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: pages.length < 2
                            ? null
                            : () => set(() => setState(() {
                                  pages.removeAt(i);
                                  marks.remove(p);
                                  hits.clear();
                                  hi = -1;
                                  cur = m.min(cur, pages.length - 1);
                                }))),
                    ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                  ]),
                );
              },
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final lock = tool == 'scroll' ? null : const NeverScrollableScrollPhysics();
    final cp = pages[m.min(cur, pages.length - 1)];
    final pri = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: searching
            ? TextField(
                controller: tc,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(hintText: 'Find text', border: InputBorder.none),
                onSubmitted: _find)
            : Text('${widget.name} · ${cur + 1}/${pages.length}', overflow: TextOverflow.ellipsis),
        actions: searching
            ? [
                if (hits.isNotEmpty) Center(child: Text('${hi + 1}/${hits.length}')),
                IconButton(tooltip: 'Previous match', icon: const Icon(Icons.keyboard_arrow_up), onPressed: () => _hop(-1)),
                IconButton(tooltip: 'Next match', icon: const Icon(Icons.keyboard_arrow_down), onPressed: () => _hop(1)),
                IconButton(
                    tooltip: 'Close search',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                          searching = false;
                          hits.clear();
                          hi = -1;
                        })),
              ]
            : [
                IconButton(tooltip: 'Find text', icon: const Icon(Icons.search), onPressed: () => setState(() => searching = true)),
                IconButton(
                    tooltip: 'Bookmark this page',
                    icon: Icon(marks.contains(cp) ? Icons.star : Icons.star_border),
                    onPressed: () => setState(() => marks.contains(cp) ? marks.remove(cp) : marks.add(cp))),
                IconButton(tooltip: 'Night mode', icon: Icon(night ? Icons.light_mode : Icons.dark_mode), onPressed: () => setState(() => night = !night)),
                IconButton(tooltip: 'Pages and bookmarks', icon: const Icon(Icons.grid_view), onPressed: _sheet),
                PopupMenuButton<String>(
                  onSelected: _act,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'share', child: Text('Share PDF')),
                    PopupMenuItem(value: 'prot', child: Text('Share password-protected PDF')),
                    PopupMenuItem(value: 'small', child: Text('Share compressed PDF (images)')),
                    PopupMenuItem(value: 'print', child: Text('Print')),
                    PopupMenuItem(value: 'png', child: Text('Export pages as images')),
                    PopupMenuItem(value: 'merge', child: Text('Merge another PDF')),
                    PopupMenuItem(value: 'scan', child: Text('Add scanned page')),
                    PopupMenuItem(value: 'blank', child: Text('Add blank page')),
                    PopupMenuItem(value: 'mark', child: Text('Next bookmark')),
                  ],
                ),
              ],
      ),
      body: LayoutBuilder(builder: (c, box) {
        final w = box.maxWidth * zoom;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: lock,
          child: SizedBox(
            width: w,
            height: box.maxHeight,
            child: ScrollablePositionedList.builder(
              itemScrollController: isc,
              itemPositionsListener: ipl,
              physics: lock,
              padding: const EdgeInsets.all(8),
              itemCount: pages.length,
              itemBuilder: (_, i) => _item(i, w - 16),
            ),
          ),
        );
      }),
      bottomNavigationBar: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (t, ic, tip) in _tools)
              IconButton(
                  tooltip: tip,
                  isSelected: tool == t,
                  icon: Icon(ic),
                  onPressed: () {
                    if (t == 'sign' && tool == 'sign') _pad();
                    setState(() => tool = t);
                  }),
            PopupMenuButton<String>(
              tooltip: 'Mark text',
              icon: Icon(Icons.border_color_outlined, color: tool == 'tm' ? pri : null),
              onSelected: (s) => setState(() {
                tool = 'tm';
                tmk = s;
              }),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'hl', child: Text('Highlight text')),
                PopupMenuItem(value: 'ul', child: Text('Underline text')),
                PopupMenuItem(value: 'st', child: Text('Strike out text')),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: 'Stamp',
              icon: Icon(Icons.check_circle_outline, color: tool == 'stamp' ? pri : null),
              onSelected: (s) => setState(() {
                tool = 'stamp';
                stamp = s;
              }),
              itemBuilder: (_) => const [
                PopupMenuItem(value: '✓', child: Text('✓ Check')),
                PopupMenuItem(value: '✗', child: Text('✗ Cross')),
                PopupMenuItem(value: 'date', child: Text('Date')),
              ],
            ),
            for (final c in _pal)
              GestureDetector(
                onTap: () => setState(() => color = c),
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(width: color == c ? 3 : 1, color: Theme.of(context).colorScheme.onSurface),
                  ),
                ),
              ),
            IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: () => setState(() {
                      if (hist.isNotEmpty) {
                        final h = hist.removeLast();
                        h.$1.ann.remove(h.$2);
                      }
                    })),
            IconButton(tooltip: 'Zoom out', icon: const Icon(Icons.zoom_out), onPressed: () => setState(() => zoom = (zoom - .25).clamp(1.0, 3.0).toDouble())),
            IconButton(tooltip: 'Zoom in', icon: const Icon(Icons.zoom_in), onPressed: () => setState(() => zoom = (zoom + .25).clamp(1.0, 3.0).toDouble())),
          ]),
        ),
      ),
    );
  }
}
