import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart';
import 'package:printing/printing.dart' show Printing;

void main() => runApp(const VordooApp());

class VordooApp extends StatelessWidget {
  const VordooApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Vordoo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF5B3DF5), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF8D78FF), brightness: Brightness.dark, useMaterial3: true),
        home: const Home(),
      );
}

typedef PageImg = (Uint8List, double, double);

/// Builds a PDF from page images (an empty image makes a blank page).
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

class Home extends StatelessWidget {
  const Home({super.key});

  Future<void> _open(BuildContext c, Uint8List b, String n) async {
    if (c.mounted) {
      await Navigator.push(c, MaterialPageRoute(builder: (_) => Reader(bytes: b, name: n)));
    }
  }

  Future<void> _pick(BuildContext c, FileType t, {bool image = false}) async {
    final r = await FilePicker.platform.pickFiles(
      type: t,
      allowedExtensions: t == FileType.custom ? ['pdf'] : null,
      withData: true,
    );
    final f = r?.files.single;
    if (f?.bytes == null) return;
    var b = f!.bytes!;
    if (image) {
      final im = (await (await ui.instantiateImageCodec(b)).getNextFrame()).image;
      b = await makePdf([(b, im.width.toDouble(), im.height.toDouble())]);
    }
    if (c.mounted) await _open(c, b, f.name.replaceAll(RegExp(r'\.[^.]+$'), ''));
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Vordoo', style: Theme.of(c).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text('Read, mark up and sign PDFs.'),
                const SizedBox(height: 28),
                FilledButton.icon(
                    onPressed: () => _pick(c, FileType.custom),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open PDF')),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: () async => _open(c, await makePdf([(Uint8List(0), 595.0, 842.0)]), 'Untitled'),
                    icon: const Icon(Icons.note_add_outlined),
                    label: const Text('New blank PDF')),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                    onPressed: () => _pick(c, FileType.image, image: true),
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Image to PDF')),
              ]),
            ),
          ),
        ),
      );
}

/// One annotation. kind: 0 pen, 1 highlight, 2 text. Points are 0..1 of the page.
class Ann {
  Ann(this.kind, this.color, this.pts, [this.text]);
  final int kind;
  final Color color;
  final List<Offset> pts;
  final String? text;
}

void paintAnn(Canvas c, Size s, List<Ann> list) {
  for (final a in list) {
    final p0 = a.pts.first;
    if (a.kind == 2) {
      final tp = TextPainter(
        text: TextSpan(text: a.text, style: TextStyle(color: a.color, fontSize: s.width * 0.03)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: s.width * 0.9);
      tp.paint(c, Offset(p0.dx * s.width, p0.dy * s.height));
      continue;
    }
    final hl = a.kind == 1;
    final paint = Paint()
      ..color = hl ? a.color.withAlpha(90) : a.color
      ..style = PaintingStyle.stroke
      ..strokeCap = hl ? StrokeCap.butt : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.width * (hl ? 0.025 : 0.004);
    final path = Path()..moveTo(p0.dx * s.width, p0.dy * s.height);
    for (final q in a.pts.skip(1)) {
      path.lineTo(q.dx * s.width, q.dy * s.height);
    }
    if (a.pts.length == 1) path.lineTo(p0.dx * s.width + 0.1, p0.dy * s.height);
    c.drawPath(path, paint);
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

class _Pg {
  _Pg(this.png, this.size);
  final Uint8List png;
  final Size size;
}

const _inv = ColorFilter.matrix(<double>[-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]);

class Reader extends StatefulWidget {
  const Reader({super.key, required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;
  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader> {
  PdfDocument? doc;
  final _f = <int, Future<_Pg>>{};
  final ann = <int, List<Ann>>{};
  final hist = <int>[];
  String tool = 'scroll';
  Color color = Colors.yellow;
  double zoom = 1;
  bool night = false;

  @override
  void initState() {
    super.initState();
    PdfDocument.openData(widget.bytes).then((d) {
      if (mounted) setState(() => doc = d);
    });
  }

  @override
  void dispose() {
    doc?.close();
    super.dispose();
  }

  Future<_Pg> _load(int i) async {
    final p = await doc!.getPage(i);
    final r = await p.render(width: p.width * 2, height: p.height * 2, format: PdfPageImageFormat.png, backgroundColor: '#FFFFFF');
    final s = Size(p.width, p.height);
    await p.close();
    return _Pg(r!.bytes, s);
  }

  Future<void> _text(int i, Offset at) async {
    final ctl = TextEditingController();
    final t = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        content: TextField(controller: ctl, autofocus: true, maxLines: null, decoration: const InputDecoration(hintText: 'Type text')),
        actions: [TextButton(onPressed: () => Navigator.pop(d, ctl.text), child: const Text('Add'))],
      ),
    );
    if (t == null || t.trim().isEmpty) return;
    setState(() {
      ann.putIfAbsent(i, () => []).add(Ann(2, color == Colors.yellow ? Colors.black : color, [at], t.trim()));
      hist.add(i);
    });
  }

  /// Flattens annotations into the pages and opens the share sheet.
  Future<void> _save(PdfDocument d) async {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Preparing your PDF…')));
    final out = <PageImg>[];
    for (var i = 1; i <= d.pagesCount; i++) {
      final p = await (_f[i] ??= _load(i));
      final im = (await (await ui.instantiateImageCodec(p.png)).getNextFrame()).image;
      final rec = ui.PictureRecorder();
      final cv = Canvas(rec);
      cv.drawImage(im, Offset.zero, Paint());
      paintAnn(cv, Size(im.width.toDouble(), im.height.toDouble()), ann[i] ?? []);
      final png = await (await rec.endRecording().toImage(im.width, im.height)).toByteData(format: ui.ImageByteFormat.png);
      out.add((png!.buffer.asUint8List(), p.size.width, p.size.height));
    }
    await Printing.sharePdf(bytes: await makePdf(out), filename: '${widget.name}-vordoo.pdf');
  }

  Widget _tool(String t, IconData i, String tip) =>
      IconButton(tooltip: tip, isSelected: tool == t, icon: Icon(i), onPressed: () => setState(() => tool = t));

  Widget _item(int i, double w) => FutureBuilder<_Pg>(
        future: _f[i] ??= _load(i),
        builder: (c, s) {
          if (!s.hasData) return SizedBox(height: w * 1.3, child: const Center(child: CircularProgressIndicator()));
          final p = s.data!;
          final h = w * p.size.height / p.size.width;
          final list = ann.putIfAbsent(i, () => []);
          Offset nrm(Offset o) => Offset(o.dx / w, o.dy / h);
          final draw = tool == 'pen' || tool == 'hl';
          Widget img = Image.memory(p.png, width: w, height: h, fit: BoxFit.fill, gaplessPlayback: true);
          if (night) img = ColorFiltered(colorFilter: _inv, child: img);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              width: w,
              height: h,
              child: Stack(children: [
                img,
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: tool == 'scroll',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: draw
                          ? (d) => setState(() {
                                list.add(Ann(tool == 'pen' ? 0 : 1, color, [nrm(d.localPosition)]));
                                hist.add(i);
                              })
                          : null,
                      onPanUpdate: draw ? (d) => setState(() => list.last.pts.add(nrm(d.localPosition))) : null,
                      onTapUp: tool == 'text' ? (d) => _text(i, nrm(d.localPosition)) : null,
                      child: CustomPaint(painter: _Painter(list)),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final lock = tool == 'scroll' ? null : const NeverScrollableScrollPhysics();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
              tooltip: 'Night mode',
              icon: Icon(night ? Icons.light_mode : Icons.dark_mode),
              onPressed: () => setState(() => night = !night)),
          IconButton(tooltip: 'Save or share', icon: const Icon(Icons.ios_share), onPressed: d == null ? null : () => _save(d)),
        ],
      ),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (c, box) {
              final w = box.maxWidth * zoom;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: lock,
                child: SizedBox(
                  width: w,
                  height: box.maxHeight,
                  child: ListView.builder(
                    physics: lock,
                    padding: const EdgeInsets.all(8),
                    itemCount: d.pagesCount,
                    itemBuilder: (_, i) => _item(i + 1, w - 16),
                  ),
                ),
              );
            }),
      bottomNavigationBar: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _tool('scroll', Icons.pan_tool_alt_outlined, 'Scroll'),
            _tool('pen', Icons.edit_outlined, 'Pen'),
            _tool('hl', Icons.highlight_outlined, 'Highlight'),
            _tool('text', Icons.text_fields, 'Text'),
            for (final c in [Colors.yellow, Colors.redAccent, Colors.green, Colors.blue, Colors.black])
              GestureDetector(
                onTap: () => setState(() => color = c),
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(width: color == c ? 3 : 1, color: Theme.of(context).colorScheme.onSurface),
                  ),
                ),
              ),
            IconButton(
                tooltip: 'Undo',
                icon: const Icon(Icons.undo),
                onPressed: () => setState(() {
                      if (hist.isNotEmpty) ann[hist.removeLast()]?.removeLast();
                    })),
            IconButton(
                tooltip: 'Zoom out',
                icon: const Icon(Icons.zoom_out),
                onPressed: () => setState(() => zoom = (zoom - .25).clamp(1.0, 3.0).toDouble())),
            IconButton(
                tooltip: 'Zoom in',
                icon: const Icon(Icons.zoom_in),
                onPressed: () => setState(() => zoom = (zoom + .25).clamp(1.0, 3.0).toDouble())),
          ]),
        ),
      ),
    );
  }
}
