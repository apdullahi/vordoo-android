# Vordoo
PDF reader, annotator and editor (Flutter). Push this folder to GitHub, open Actions, run "Build Vordoo",
then download vordoo-apk (Android) or vordoo-ios-unsigned (needs signing/sideloading to install).
On a computer: `flutter create . --project-name vordoo --platforms android,ios && flutter run`.

Features: continuous reader, zoom, night mode, page jump, bookmarks, text search (real text layer), password-protected PDFs;
pen, highlighter, text-snapped highlight/underline/strikeout, line, arrow, rectangle, oval, text, saved signature,
check/cross/date stamps, eraser, redaction (burned into the page), undo; page manager (reorder, rotate, delete, add blank, merge);
image/camera scan to PDF; share PDF with real text and standard annotations, password-protect, compress, print, export PNG;
open PDFs from other apps (Android). Cloud files (Drive, Dropbox, OneDrive) open/save via the system picker and share sheet.

Uses Syncfusion's PDF library (syncfusion_flutter_pdf): check its license terms (Community License) for your use.
