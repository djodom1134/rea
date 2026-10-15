# Darkroom Booth for macOS

A native Swift/SwiftUI rebuild of the Windows photo-booth app Darkroom Booth
3.00.943. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and
the hardware support plan. See [docs/reverse-engineering/](docs/reverse-engineering/)
for what the Windows app does, recovered from its binaries.

## Requirements

- macOS 14 or later
- Swift 6 toolchain: Xcode 16+ or the Command Line Tools (tests use swift-testing)
- For dye-sub printers: [Gutenprint](https://gutenprint.sourceforge.io/) 5.3.4 or later, or the printer vendor's macOS driver, with the printer added in System Settings → Printers & Scanners

## Build and run

```bash
cd apps/darkroom-booth-mac
swift test                 # swift-testing; should also run with only the Command Line Tools
swift run DarkroomBooth    # operator window; "Start Booth Mode" opens the full-screen booth
```

The first launch asks for camera access. `swift run` embeds `Info.plist` so
the permission prompt can appear. To get a double-clickable app bundle, run
`scripts/make-app.sh`.

## Using it

1. Pick a camera.
   - Webcams, capture cards and iPhone Continuity Camera are listed automatically.
   - For DSLRs, tether with any tool that saves into a folder, then use **Add hot folder…**. Canon and Nikon direct control is next on the roadmap.
2. Pick a printer from the CUPS queues. Status and ribbon or media levels show when the driver reports them.
3. Pick a print layout, then set the countdown, review, retake and copies options.
4. Click **Start Booth Mode**.
   - Guests tap the screen, or press Space/Enter, to start.
   - Ctrl+B, Ctrl+C and Ctrl+S switch between black-and-white, colour and sepia.
   - Ctrl+R reprints the last output.
   - Esc exits. If an operator PIN is set, Esc asks for it first.

Sessions are saved under `~/Pictures/Darkroom Booth/<event>/Sessions/`, with
the originals, `output.jpg` and `print.jpg` for each session. A `Sessions.db`
log uses the Windows app's `SessionData` columns.
