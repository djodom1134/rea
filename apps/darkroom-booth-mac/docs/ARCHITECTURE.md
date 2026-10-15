# Darkroom Booth for macOS: architecture and port plan

This is a native macOS rebuild of Darkroom Booth 3.00.943 for Windows. The
behaviour comes from static analysis of the Windows install, done with the REA
workflow in this repository. The findings are in
[reverse-engineering/](reverse-engineering/), where each claim is tagged as
observed or inferred.

## Why native Swift

The Windows app is a 32-bit MFC shell over a large C++ engine (`Eventlib.dll`,
10,799 exports). Its hardware access is made of vendor SDKs loaded at runtime,
DirectShow, and raw USB libraries for dye-sub printers. None of that runs on a
Mac, and every replacement is a macOS framework or a C library:

- AVFoundation for cameras
- ImageCaptureCore and libgphoto2 for tethering, plus the Canon and Nikon SDKs for macOS
- CUPS with Gutenprint for printers
- Core Image and ImageIO for imaging
- Vision for QR codes and faces
- IOKit and termios for USB and serial I/O

Swift and SwiftUI reach all of these directly and give a kiosk-quality
full-screen UI. Electron or Catalyst would only add a layer between the app
and the hardware.

## Package layout

| Target | Role | Windows counterpart |
|---|---|---|
| `BoothCore` | Pure session flow (`SessionMachine`), settings, `%Var%` substitution, print sizes, layouts, SQLite session log. Foundation only, fully unit tested | Booth state machine in `DarkroomBooth.exe`, `CScriptHelper`, `SessionData` table |
| `BoothHardware` | Device contracts (`CameraDevice`, `PhotoPrinterService`, `TriggerInput`) and USB device catalogs recovered from `Eventlib.dll` and the printer DLLs | `CEdgCamera`, printer lists, VID/PID tables |
| `BoothCameras` | Camera backends | `CEdgCamera` subclasses |
| `BoothPrinting` | CUPS client: IPP status and marker levels, `lp` submission | `cpusbxpm`, `cspstat`, `904*`, `S1245*`, `BRAVA21*` direct-USB drivers |
| `BoothImaging` | Layout rendering, colour effects, chroma key, strip sheets, GIF | Effect classes, `CChromaKeyInfo`, LEADTOOLS, gifsicle |
| `BoothIO` | Trigger inputs: keyboard map, RS-232 modem-status buttons (Phidgets next) | Serial setup, `phidget21` |
| `DarkroomBooth` | SwiftUI app: operator window and full-screen guest booth | Booth Options and Booth Mode |

Dependencies point inward. `BoothCore` knows nothing about hardware. The app
target hosts `SessionMachine`, which is a pure reducer: events go in, effects
come out (timers, capture, compose, print, log). The controller runs the
effects and sends their results back as events. Stale timers are ignored by
token, so a cancel or retake can never be overtaken by an old countdown.

## Hardware support plan

Status key:
- ✅ Implemented in this PR.
- 🔜 Next PRs.
- ⚠️ Possible but limited.
- ❌ Dropped, with the reason given.

### Cameras

| Windows path | Models | macOS route | Status |
|---|---|---|---|
| DirectShow webcam / DV | USB webcams, capture cards | AVFoundation (also UVC, HDMI capture cards, Continuity Camera) | ✅ |
| Hot folder camera (Windows default) | Anything that writes files: Wi-Fi/FTP transfer, tether tools | Folder polling with stable-size check | ✅ |
| Canon EDSDK 13.11 (+ legacy 2.7) | EOS up to R/RP/90D/M50/M6 II/M200 | Canon EDSDK for macOS (bring your own copy from the Canon developer program, loaded at runtime), with libgphoto2 as fallback | 🔜 |
| Nikon SDK (MAID3) `Type0001..0023.md3`, `D*_Mod.md3` | D3 through Z 7 | Nikon SDK for macOS (bring your own), with libgphoto2 as fallback. The Windows install lacks `Type0024` (Z 6) | 🔜 |
| Canon CD-SDK / PS-ReC / RC-SDK (2004–2005) | PowerShot, EOS 1D II/5D/20D/350D | libgphoto2 covers most of these over PTP | ⚠️ |
| GoPro HTTP (Hero4 era) | GoPro | Open GoPro HTTP API (Hero 9+) or HDMI capture through AVFoundation | 🔜 |
| Nikon D1 FireWire (`NkD1394p`) | D1 series | ❌ No FireWire on current Macs | ❌ |
| Fujifilm S1–S5, Olympus E-1, Kodak, Phase One, Megavision | (dead code in Windows) | libgphoto2 if ever needed | ❌ |
| TWAIN, Snap Camera | | ❌ TWAIN is vestigial; Snap Camera was discontinued in 2023 | ❌ |

The 252-entry camera VID/PID table from `Eventlib.dll` ships as
`camera-usb-models.tsv`, so detection can pick a backend per model, the same
way the Windows app does.

### Printers

The Windows app talks to dye-sub printers over raw USB through vendor DLLs.
On macOS they go through CUPS. Use Gutenprint's dye-sub backends where they
exist, or the vendor's macOS driver. The app reads state, reasons and
`marker-levels` (ribbon or media remaining) over IPP from the local CUPS
server.

| Windows library | Printers | macOS route | Status |
|---|---|---|---|
| `cspstat.dll` (DNP CspStat SDK) | DNP DS40, DS80, DS-RX1, DS620, DS820; Citizen CX/CY/CW | Gutenprint `dnpds40` backend or the DNP macOS driver | ✅ via CUPS |
| `cpusbxpm.dll` + `MUsbIf.dll` | Mitsubishi CP-D70/D707, K60, D80, D90, 9550, 9800, 3020 | Gutenprint Mitsubishi backends. The shipped `CP*_COL.lut` and `CP*.csv` files match Gutenprint's `CPD70*`/`CPD80*` data formats | ✅ via CUPS |
| `904*.dll`, `S1245*.dll` | Shinko/Sinfonia CHC-S9045, CHC-S1245 | Gutenprint `shinkos1245`. S9045 support in Gutenprint is experimental | ✅ / ⚠️ |
| `Printers/Ciaat/BRAVA21*` | Ciaat Brava 21 (Sinfonia S6145 derivative) | Gutenprint `shinkos6145` + `libS6145ImageReProcess` | ✅ via CUPS |
| Windows driver + USB detection | Sony UP-DR150, UP-DR200, UP-CX1 | Gutenprint Sony backends | ✅ via CUPS |
| `cpusbxpm` (W5000) | Mitsubishi CP-W5000DW | Vendor driver only | ⚠️ |
| Any Windows printer | Inkjet or laser printers | CUPS, with `fit-to-page` | ✅ |

2x6 strips print two-up on a 4x6 sheet, rounding copies up to whole sheets as
the Windows app does. With Gutenprint the job requests `w288h432-div2`, so
the printer cuts the sheet. Printer USB IDs are in `printer-usb-models.tsv`.

### Other devices

| Device | Windows | macOS | Status |
|---|---|---|---|
| Keyboard / touch / mouse start | Space/Enter/click, Ctrl+B/C/S colour, Ctrl+R reprint, Esc + PIN | SwiftUI key handling and tap | ✅ |
| RS-232 dry-contact buttons | DTR→CD/CTS/DSR/RI, `WaitCommEvent` | termios `TIOCMGET` polling on `/dev/cu.*` | ✅ |
| Phidgets InterfaceKit (buttons, lights, coin/bill pulses) | phidget21 | Phidget22 macOS library, loaded at runtime. Keeps the `inputs.json` action vocabulary | 🔜 |
| QR touchless start (zbar) | live view or second webcam | Vision `VNDetectBarcodesRequest` | 🔜 |
| Face-detect start (OpenCV) | | Vision face detection | 🔜 |
| Voice start (SAPI) | | Speech framework | 🔜 |
| Second monitor / slideshow | IE-hosted HTML | Second `NSScreen` window | 🔜 |
| Sentinel dongle, Nalpeiron licensing | | Not ported | ❌ |

## Software features: what's in and what's next

Done in this PR:
- Session flow: attract, get ready, countdown, capture, review/retake, copies prompt, print, thank-you.
- Credits gate, colour effects, operator PIN, kiosk full screen with sleep prevention.
- Layout rendering (strip, grid, single) with `%Var%` text.
- Chroma key, GIF export, and a session log that keeps the Windows `SessionData` column names.

Roadmap, in order:
1. Canon EDSDK and libgphoto2 backends with live view.
2. Phidgets inputs and outputs, with the `inputs.json` import.
3. Delivery: SMTP email, MMS gateways (`Carriers.txt`), Twilio, a QR download link.
4. A template editor and screen templates with per-stage visibility. Decoding `.xbdr` needs sample template files.
5. Video, boomerang and burst sessions (AVFoundation, AVAssetWriter).
6. Surveys and quizzes (XML format recovered), and the BoothControl LAN web server.
7. Slideshow, wrap-up reports and stats.

## Unknowns

These still need sample files or runtime traces from a Windows install:
- The `.xbdr` byte layout.
- The `.edf`/`.edp` catalog files.
- Where event settings are physically stored.
- The `Incident`/`PrintChoice` enum codes.
- The BoothStart QR payload.

Gutenprint model names in `printer-usb-models.tsv` have not been checked
against an installed Gutenprint.
