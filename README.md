# Vordoo — Android PDF app (early build)

Vordoo is a Flutter Android PDF reader/annotation prototype. This repository is structured for GitHub Actions to build a debug APK so it can be installed and tested on an Android phone.

## Build on GitHub from your phone

1. Upload the **contents** of this folder to the root of your GitHub repository. Do not upload the ZIP as a single file.
2. Preserve the folder structure. In particular, `lib/main.dart` must be inside the `lib` folder, and `.github/workflows/build.yml` must remain in that exact path.
3. Commit the upload to `main` (or `master`).
4. Open the repository's **Actions** tab and open the latest **Build Vordoo APK** run.
5. When it succeeds, download the `vordoo-debug-apk` artifact, extract it, then install `app-debug.apk` on your Android phone. Android may ask you to allow installation from your browser/files app.

The workflow checks the key files first and reports a clear message if they are missing. It generates the Android platform folder on GitHub's runner, downloads dependencies, builds a debug APK, and uploads the APK as an artifact.

## Current functionality

- Open a PDF from the Android file picker
- Render and scroll through PDF pages
- Zoom controls and night/inverted viewing mode
- Freehand pen and highlight annotations
- Add text annotations
- Undo the most recent annotation
- Create a blank PDF
- Convert a selected image to a PDF
- Export annotated pages to a shareable PDF

## Important limitations

This is an early prototype, **not yet a complete Xodo replacement**. Annotation export currently rasterizes pages, so exported PDFs may lose selectable text and other original PDF properties. It does not yet provide full OCR, Word conversion, merge/split, page rearrangement, persistent document library, robust PDF form filling, or production-grade signature support. The project has not been compiled or device-tested in this environment; use the GitHub Actions result to verify the build and report any remaining error logs.

## Project structure

```text
.
├── .github/
│   └── workflows/
│       └── build.yml
├── lib/
│   └── main.dart
├── pubspec.yaml
└── README.md
```
