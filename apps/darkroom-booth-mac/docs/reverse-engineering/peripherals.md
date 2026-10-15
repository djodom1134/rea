# Darkroom Booth 3.00.943: peripherals, external services and third-party libraries

Scope: hardware other than cameras and printers, plus external services and bundled libraries.
Source: the install folder `D27LibCom/`. The binaries were never executed. All findings come from static
analysis: PE imports and exports (pefile), ASCII and UTF-16 strings (`strings -a`, `strings -el`) and version resources.

Evidence labels:
- **[O] Observed**: a literal import, export, string or resource in the named file.
- **[I] Inferred**: reasoning from observed evidence, not verified at runtime.

Most of the logic lives in shared libraries. `DarkroomBooth.exe` is the booth front end. `Eventlib.dll` (10.7 MB) holds the
device, network and media engine. `Xphotolib.dll` holds the frame, setup UI and web server. `EdgUtil.dll` holds utilities
(monitors, gestures, SQLite `CDbLite`, JSON).

---

## 1. Summary table

| # | Component | What it is | Used for | macOS replacement |
|---|---|---|---|---|
| 1 | `phidget21x86.dll` | Phidgets **Phidget21 v2.1.8** (built 2015-03-26) | USB digital I/O: start and command buttons, bill or token acceptor input (credits), lights and relays via outputs | **Phidget22** macOS library (`libphidget22`, Swift or C API: `DigitalInput`, `DigitalOutput`, `Manager`). Alternatives: IOKit HID or Arduino HID |
| 2 | RS-232 "Serial Port Trigger" (`DarkroomBooth.exe`) | Win32 COM port with modem-status lines | Dry-contact buttons wired to DE-9 pins (CD, CTS, DSR, RI), with DTR as the source | IOKit serial (`ORSSerialPort` or POSIX `termios` + `ioctl(TIOCMGET)` / `TIOCMIWAIT`-style polling). USB-serial adapters (FTDI/PL2303) show up as `/dev/cu.*` |
| 3 | Barcode scanner (`Eventlib.dll` `CScannerThread`) | Serial or USB keyboard-wedge scanner | Order and receipt barcode lookup (lab and kiosk workflows) | ORSSerialPort for serial scanners. For USB wedge scanners, an `NSEvent` local monitor or IOKit `IOHIDManager` (to tell scanner input apart from the keyboard) |
| 4 | Keyboard, mouse and touchscreen | Hotkeys, mouse-button mapping, hit-area exit, Win7 gestures, low-level keyboard hook | Start, cancel and reprint sessions; operator escape; blocking the Windows key | `NSEvent` monitors, `CGEventTap` (needs Accessibility permission) to swallow Cmd-Tab and similar, `NSApplication.presentationOptions` kiosk flags, `NSGestureRecognizer` |
| 5 | Speech recognition (`DarkroomBooth.exe`) | Microsoft SAPI (COM) | Voice start ("Begin;Start;Go") and voice "take" ("Cheese") | `SFSpeechRecognizer` (on-device) or `SpeechAnalyzer` on newer macOS. AVAudioEngine for the microphone |
| 6 | QR and barcode **decode**: `libzbar-0.dll` (ZBar 0.2.0) + `libiconv-2.dll` 1.14 | Image barcode reader | Live-view QR detection: touchless start, auto email/SMS address capture | Vision `VNDetectBarcodesRequest` (QR, EAN, Code128 and more) on `AVCaptureVideoDataOutput` frames |
| 7 | QR **encode**: `EdgQR.dll` (Darkroom-built, 3 ordinal exports) + embedded jquery-qrcode JS | QR generator | QR codes on prints and screens ("Booth Start" sign, support, share links) | `CIFilter.qrCodeGenerator()` (CoreImage) |
| 8 | `IDAutomationLinear6.dll` v1.6.0.5 (IDAutomation Linear BarCode ActiveX) | 1-D barcode renderer | Barcode objects in layout templates (Code39, Code128, UPC/EAN, Postnet and others) | `CIFilter.code128BarcodeGenerator()`, `pdf417BarcodeGenerator()`, `aztecCodeGenerator()`. Use ZXing-cpp for EAN, UPC, Code39 and Postnet |
| 9 | SocketTools 8 (`csmtpav8`, `csmapav8`, `csmsgav8`, `cshtsrv8`) by Catalyst Development | SMTP, IMAP, MIME and HTTP-server libraries | Email photos, read inboxes (AutoInput), the **BoothControl web server** on port 80 | SMTP: SwiftSMTP, MailCore2 or a provider HTTP API (SendGrid, SES). IMAP: MailCore2. MIME: hand-built or MailCore2. HTTP server: SwiftNIO, Vapor/Hummingbird or Network.framework `NWListener` |
| 10 | `MobileCarriers/Carriers.txt` + logos | Email-to-MMS gateways | "Text photo to phone" by emailing `<number>@gateway` | Same data file plus SMTP. Twilio is preferred because the carrier gateways are largely dead (see 13) |
| 11 | Twilio REST | SMS, MMS and voice | Send photos as MMS, read inbound texts, voice auto-reply | `URLSession` against `api.twilio.com/2010-04-01` |
| 12 | Social and cloud APIs | Facebook Graph v5.0, legacy Instagram API, Dropbox v2, EventGallery ("Hula Gallery"), remove.bg, an AWS API Gateway temp upload | Posting, importing (hashtag printing), MMS media hosting, background removal | `URLSession` + `ASWebAuthenticationSession` for OAuth |
| 13 | WinINet FTP, SMB shares (MPR), dial-up | Networking | FTP upload and download, mapped network drives, dial-up/RAS connect | `URLSession` (no FTP: use a library such as `FilesProvider` or curl), `NetFS` / `mount_smbfs`. Dial-up is not needed |
| 14 | Licensing: `drbooth2.dll` (Nalpeiron "Shafer" NSL 3.6.41 with libcurl and LibreSSL 3.0.2), `filechck.dll` (Nalpeiron Support DLL 7.0) and the Nalpeiron Licensing Service. A legacy **Rainbow/SafeNet Sentinel SuperPro** USB dongle is also supported | Copy protection | Activation, a 6-month online refresh, VM and RDP blocks; the dongle is needed for VM/RDP use | Not required for the rebuild. Use your own licensing (StoreKit, Paddle, Keygen and so on) |
| 15 | Sound: DirectSound (`DSOUND` ord 11), Media Foundation, WinMM mixer and MCI | Audio playback, fades and system volume | Countdown WAVs, music, per-event sound effects, ready beep | `AVAudioEngine` / `AVAudioPlayerNode` (fades by volume ramps), `AVPlayer`. System volume through CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` |
| 16 | Video playback: Media Foundation (`MFCreateMediaSession`, renderer) | Attract and instruction videos | Weighted, random or cyclic video actions | `AVPlayerLayer` / `AVQueuePlayer` |
| 17 | Multi-monitor (`EdgUtil.dll` monitor helpers) | Second display | Attract or slideshow on a second monitor ("Where\2ndMon") | `NSScreen.screens` with a borderless `NSWindow` per screen |
| 18 | Local web server + BoothControl (`Xphotolib.dll`) | HTTP server on port 80 serving HTML/JS | Remote control from phone or tablet, kiosk and share pages, web "inputs" | Embedded HTTP server (SwiftNIO or Hummingbird). Advertise with Bonjour (`NWListener` service) |
| 19 | Snap Camera control (`Eventlib.dll`) | Snap Inc. desktop virtual-camera app | Lens select, cycle, toggle and off actions | Snap Camera was discontinued in 2023. Drop it or replace with CoreImage/Metal filters (or Snap Camera Kit) |
| 20 | `gifsicle.exe` 1.88 (LCDF) | GIF optimiser | Lossy compression of animated GIFs | ImageIO `CGImageDestination` (kUTTypeGIF) to create GIFs. Ship a gifsicle CLI build (Homebrew-style binary) for lossy optimisation, or prefer MP4 |
| 21 | `turbojpeg.dll` | libjpeg-turbo TurboJPEG API | Fast JPEG decode (`tjDecompress*`) | ImageIO / `CGImageSource` (hardware-accelerated) |
| 22 | LEADTOOLS 11.5 (`ltkrn/ltfil/ltimg/ltdis11n`, `lf{bmp,cmp,fax,png,psd,tga,tif}11n`) | Imaging SDK | Loading and saving BMP, PNG, PSD, TGA, TIFF, CMP and FAX | ImageIO covers BMP, PNG, TIFF, PSD (read) and TGA (read). LEAD CMP and FAX are legacy (drop them) |
| 23 | `flpgrf.ocx` + `.lic` (ProWorks Flipper Graph 1.301) | ActiveX charting | Stats and report graphs (`CFlpGrf` wrapper in Eventlib) [I] | Swift Charts |
| 24 | ODBC32, SQLite (`CDbLite`), qbXML | Databases | Session stats DB (SQLite), Access/ODBC catalogs, QuickBooks invoicing | SQLite (GRDB). QuickBooks: QuickBooks Online REST API if needed |
| 25 | `BoothMode.exe` | 69 KB launcher stub | Runs `DarkroomBooth.exe -Booth` (start directly in booth mode) | A launch argument or a LaunchAgent with `--booth` |
| 26 | `SlideshowGraphics/SlideshowBrowser.exe` + `autorun.inf` | MFC IE-hosted viewer ("ExpressDigital Slideshow") | Autorun slideshow on burned CD/DVD or USB deliverables | Plain HTML5 slideshow (no executable) |
| 27 | Disc publishers (Eventlib) | IMAPI2 burner, Epson Bravo, Rimage, Noritsu publisher | Burning event or customer discs (a legacy lab feature) | `DiscRecording.framework` (deprecated). Recommend USB or cloud delivery instead |
| 28 | Power and kiosk | `ExitWindowsEx` + `SeShutdownPrivilege`, `SetThreadExecutionState`, `ShowCursor`, `SystemParametersInfo` | Remote restart or shutdown, preventing sleep, hiding the cursor | `IOPMAssertionCreateWithName` (prevent sleep), `NSCursor.hide`, an AppleScript/`osascript` "System Events" shutdown, or a privileged helper |

Not found anywhere: DMX/Art-Net/Enttec, GPIO/Arduino, ccTalk/MDB/Pyramid coin or bill protocols, card-payment
terminals (Square, Nayax, Stripe), HASP/Wibu/Rockey dongles.
- **[O]** A grep for `dmx|artnet|enttec|gpio|arduino|cctalk|mdb|pyramid|nayax|square|stripe.com|paypal|hasp|wibu|rockey` across the
  main binaries found only unrelated CSS and JS matches.
- **[O]** Credit-card strings exist only for **Labtricity lab ordering** (the `CCreditCardDlg`, "Labtricity Account Credit Card"
  strings in `Xphotolib.dll`), not for guest payments at the booth.

---

## 2. Phidgets USB I/O (buttons, lights, bill acceptor)

**Library [O]:** `phidget21x86.dll` contains the string `Phidget21 - Version 2.1.8 - Built Mar 26 2015`. It has no version resource. Its device table
includes InterfaceKit 0/0/4, 0/0/8, 0/16/16, 0/5/7, 0/8/8, 2/2/2, 2/8/8, 4/8/8 and 8/8/8, plus many other classes.

**Loading [O]:** the DLL is loaded dynamically by `Eventlib.dll`. It is not in the import table.
- Strings: `phidget21x86.dll`, `Unable to load phidget21x86.dll export. Err=%u`, the search paths `\Program Files\Phidgets`,
  `Phidget21.dll`, `x86\`, ` (x86)`, `Not found: `, and `Phidget21.dll loaded but unable to get version. Error=%u`.

**APIs resolved by name (GetProcAddress strings in `Eventlib.dll`) [O]:**
- Manager: `CPhidgetManager_create/open/close/delete`, `set_OnAttach_Handler`, `set_OnDetach_Handler`,
  `set_OnError_Handler`, `getAttachedDevices`, `freeAttachedDevicesArray`.
- Generic: `CPhidget_open`, `CPhidget_openLabel`, `close`, `delete`, `waitForAttachment`, `getDeviceName/Type/Class/ID/Version/Status`,
  `getSerialNumber`, `getDeviceLabel`, `setDeviceLabel`, `getLibraryVersion`, `getErrorDescription`,
  `getServerID/Address/Status`, `set_OnAttach/OnDetach/OnError/OnServerConnect/OnServerDisconnect_Handler`.
- **InterfaceKit only:** `CPhidgetInterfaceKit_create`, `getInputCount`, `getInputState`, `set_OnInputChange_Handler`,
  `getOutputCount`, `getOutputState`, `setOutputState`, `set_OnOutputChange_Handler`, `getSensorCount`, `getSensorValue`,
  `getSensorRawValue`, `set_OnSensorChange_Handler`, `get/setSensorChangeTrigger`, `get/setRatiometric`, `get/setDataRate(Min/Max)`.
- No other Phidget class (RFID, servo, LED64 and so on) is referenced by the app.

**Wrapper [O]:** the `CHIDeviceManager` exports in `Eventlib.dll`:
- Device discovery: `EnumerateDevices`, `EnumerateDeviceLabels`, `GetDeviceInfo`, `GetDeviceState` (inputs and outputs as DWORD arrays),
  `GetDeviceFriendlyName`.
- Event and action plumbing: `RegisterDeviceChangeHandler`, `ProcessActions(CEdgJsonObject*)`, `ProcessActionString`, `SetOnInputCommands`
  (imported by `DarkroomBooth.exe`).
- Web inputs and misc: `EnumerateWebServerInputs`, `HandleWebServerInput`, `ResetCycles`, `GetLibraryVersion`.
- Hot-plug: `CDeviceChangeManager::RegisterDeviceNotifications` / `OnDeviceChange` (`RegisterDeviceNotificationA` import).
- Device list CSV header [O]: `Model,Name,Serial Number,Sensors,Inputs,Outputs,Attached`. Labels are stored under the
  registry value `Devices\Phidgets\Name`.
- UTF-16 note [O]: "The Phidget device driver for Windows does not allow changing a Phidget embedded label. You can attach the device to
  a Mac OS computer and use Phidget's control panel there…". The vendor itself relied on macOS Phidget tooling.

**Configuration model [O]:**
- Stored in `DeviceControl\inputs.json` (`Xphotolib.dll` / `DarkroomBooth.exe`: `DeviceControl`, `inputs.json`, `inputs`,
  `DeviceSettings`, `DeviceSettingsEnabled`).
- Per-input action lists are keyed `%s\Input %i` with `on\actions` and `off\actions`. JSON keys include `Attached`, `Serial`, `Label`, `Model`,
  `OUT%i`, `Device`, `DisplayString` and `Actions`.
- Input types in the UI: "Phidget Device Input", "BoothControl Custom Input" (web), "Device Input".
- Help text [O]: "Digital inputs may be used to trigger booth events." and "If multiple Phidget boards are in use, specify which device to use."

**Action vocabulary** (keywords in `Eventlib.dll`; help text paraphrased) [O]:

| Keyword | Meaning |
|---|---|
| `OUTX` / `Out%s` with `ON`, `OFF`, `TOGGLE`, `BLINK` / `FAST BLINK` / `SLOW BLINK`, `BLINK TOGGLE` | Digital output control. Blink rates are 1, 2 and 5 Hz ("Blinks digital output once per second", "2 times a second", "5 times a second"). Blink toggle: "If digital output is off, starts blinking at medium rate, otherwise turns it off". An output can be set for a timed duration and then reverts ("If a timed duration is specified for an output switch…") |
| `OUTALL` | "Resets all digital outputs to off." |
| `PAUSE` / `WAIT` | "Pause before executing remaining commands." |
| `ADDCREDIT`, `UPDATECREDIT`, `CLEARCREDITS` | "Adds one start credit." and "Resets start credits to zero." |
| `BOOTHCOMMAND`, `APPCMD` | "Executes a booth mode command" (see the list below) |
| `SOUND`, `STOPSOUND` | Sound effect with `/Vol=%u`, `/FadeIn`, `/FadeOut`, `/Loop` |
| `VIDEO` | Plays a video. Options CYCLE, RANDOM or CUSTOM with `WEIGHTS=`, loop-until-click and overlay text |
| `SCRIPT`, `RUNSCRIPT`, `EXECUTE` | HTML page script, external script (filter `AutoHotKey Scripts (*.ahk)`), executable |
| `NOTIFY`, `TESTMODE`, `ATTACH`, `DETACH`, `DEVICE`, `IF%u_%u_%u` | Notifications, test mode, attach and detach events, device selector, conditional |

Booth command names (`Eventlib.dll`) [O]:
- Session control: `startsession`, `videosession`, `startvideo`, `burstsession`, `cancelsession`, `reprintlast`, `printcopies`.
- Print and graphic choice: `chooseprimaryprint`, `choosealternateprint`, `choosegraphic`, `nextgraphic`, `prevgraphic`.
- Effects and credits: `applyfilter`, `addcredit`, `clearcredits`, plus the colour toggles color, grayscale, antique and sepia.
- Snap Camera: `snaplens`, `snaplenscycle`, `snaplenstoggle`, `snaplensoff`.

**Bill changer and token credits [O]:**
- `DarkroomBooth.exe` (Booth Controls dialog) contains "Bill Changer / Token Support", "Require minimum credits to start session" and
  "Require credits to print extra copies".
- It also contains "To use credits for startup, you must also configure an input device to count credits coming from a bill-changer, token, or
  similar device connected to this computer using a Phidget input."
- Settings keys: `Credits\RequireStartup`, `Credits\StartupMin`, `Credits\RequireCopy`, `Credits\CopyMin`,
  `CreditsRequired`, `ReprintCreditsRequired`.
- [I] The acceptor's pulse or relay output is wired to a Phidget digital input, and each input edge runs `ADDCREDIT`. No serial
  coin-mech protocol (ccTalk, MDB) exists. Lights, marquees and relays are driven by digital outputs through the action lists.
- **Analog sensors [I]:** sensor APIs are resolved, so sensor thresholds may be usable as triggers. No sensor-specific UI string was found.

**macOS plan:**
- Use **Phidget22** (macOS supported, and it still supports InterfaceKit 1011/1012/1014/1017/1018 as channels):
  `PhidgetManager` handles attach and detach. Each input is a `DigitalInput` (stateChange event). Each output is a
  `DigitalOutput` (`setState`, plus a Timer for blink and duration).
- Open devices by serial number and label (`Phidget_setDeviceSerialNumber`, `Phidget_setDeviceLabel`).
- Keep the `inputs.json` schema and the action vocabulary so existing configurations can be imported.

---

## 3. RS-232 serial trigger

Evidence [O] (`DarkroomBooth.exe`):
- Imports: `CreateFileA`, `GetCommState/SetCommState`, `Get/SetCommTimeouts`, `SetCommMask`, `WaitCommEvent`, `PurgeComm`,
  `ClearCommError`.
- Strings: `COM1:` … `COM8`, default `COM1:,9600,8,N,1`, `Error opening %s`, `%s open`.
- Dialog "Serial Port Setup" (UTF-16): Port, Baudrate, Databits, Parity, Stop bits.
  - "Pin-outs are for a standard RS-232 serial port with a DE-9 connector."
  - "Connecting Pin 4 with the Pin shown will trigger the signal." The pins shown are 1, 8, 6 and 9 (labels include "RING").
  - "Port Monitor (Press serial buttons to test)" and "Defined Action:".
- Settings keys: `Controls\SerialPortParams`, `Controls\SerialCommandCD`, `Controls\SerialCommandCTS`,
  `Controls\SerialCommandDSR`, `Controls\SerialCommandRING`.

Interpretation [I]:
- DTR (pin 4) is asserted as a source voltage. A push button bridges it to DCD (pin 1), CTS (pin 8), DSR (pin 6) or RI (pin 9).
- `WaitCommEvent(EV_RLSD|EV_CTS|EV_DSR|EV_RING)` fires, and each line maps to a configurable booth command.
- No serial data is read for this feature. It provides four cheap dry-contact buttons.

macOS:
- Open `/dev/cu.usbserial-*`, set DTR (`ioctl TIOCMBIS TIOCM_DTR`), and poll or wait for `TIOCMGET` changes on `TIOCM_CD/CTS/DSR/RI`.
- ORSSerialPort exposes `CTS`, `DSR` and `DCD`. RI needs the raw ioctl.
- Line support varies by USB-serial chip. FTDI is the most complete.

---

## 4. Barcode scanners (input)

Evidence [O]:
- `Eventlib.dll` exports `CScannerThread::ReadPort`, `ReadBuffer`, `GetReadQueueCount`, `ProcessUsbScannerKey`, `GetInput`,
  `GetLastInput`, `GetNumInputs`. `Eventlib.dll` imports the Comm APIs, `SetWindowsHookExA` and `SendInput`.
- `Xphotolib.dll` has the setting `BarcodeScannerMode`. UTF-16 options in `Eventlib.dll`:
  `Auto Detect|Serial Barcode Scanner|USB Barcode Scanner|Both Serial and USB Scanner|None`.
- Related strings: "Barcode Scanner", "Order barcode:", "Receipt Barcode", `BarcodeSearchFlags`.

[I] Serial scanners are read from a COM port. USB keyboard-wedge scanners are separated from typing by a keyboard hook (timing or prefix based).
The scanner is used mainly for order and receipt lookup in the shared lab and kiosk code, and is optional for booths.

macOS: ORSSerialPort for serial scanners. For USB scanners, use `IOHIDManager` matching the scanner's VID/PID so it
does not mix with keyboard input. Alternatively, put the scanner in USB-HID-POS mode.

---

## 5. Keyboard, mouse, touchscreen, kiosk

Evidence [O] (`DarkroomBooth.exe` dialog and strings):
- Shortcuts: "Allow color toggles: Ctrl+B=Black&&White Ctrl+C=Color Ctrl+S=Sepia Alt+Key to start session Ctrl+Shift+Key toggles",
  "Ctrl+R reprints last print Alt+R asks for copies" and "Ctrl+T enables/disables test mode with no output".
- Mouse mapping: "Left-button:", "Middle-button:", "Right-button:" and "Hit-area to exit:" (`Controls\MouseLeftClick`,
  `...RightClick`, `...MiddleClick`, `Controls\MouseHitArea`).
- Tabs: "Keyboard", "Mouse / Touchscreen", "Other". Settings `StartKeyAction` and "Windows Key Action". Start prompts: "Press spacebar to start",
  "Press a key to start", "Click to start", "Press button to start". Debug string `OnHotkeyEscape allow=%i active=%i`.
- Imports: `SetWindowsHookExA/UnhookWindowsHookEx/CallNextHookEx`, `GetAsyncKeyState`, `ShowCursor`, `ExitWindowsEx`,
  `SetThreadExecutionState`, `AdjustTokenPrivileges` (`SeShutdownPrivilege`).
- `EdgUtil.dll` exports `EdgSupportsGestures`, `EdgSetGestureConfig` and `EdgGetGestureInfo` (Windows 7 `WM_GESTURE` touch).
- The embedded HTML pages contain touch and swipe JS for kiosk and slideshow pages. A touchscreen is treated as a mouse.

[I] The low-level keyboard hook blocks or remaps the Windows key and system shortcuts in booth mode.

macOS:
- `NSApplication.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination]`.
- Add a `CGEventTap` (Accessibility permission) if extra keys must be swallowed.
- Use `NSEvent.addLocalMonitorForEvents` for hotkeys, mouse-button mapping and hit areas, and `NSCursor.hide()`.
- Prevent sleep with `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)`.

---

## 6. Voice and face triggers (inputs only)

Evidence [O] (`DarkroomBooth.exe`):
- "Voice: session can be started by voice activation", "Speech Setup", "Speech Commands",
  "Speech Log (speak naturally to test the recognizer)", `Unable to start speech recognition engine`,
  `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech\AudioInput`.
- Settings `Controls\VoiceStartCommands` (default `Begin;Start;Go`), `Controls\VoiceTakeCommands` (default `Cheese`) and
  `Controls\VoiceParams`. "Microphone Sensitivity" appears in `Eventlib.dll`.
- [I] SAPI is used via `CoCreateInstance`. The engine is Windows Speech.

Face detection ("session starts if faces are detected", "print copies for each person") uses `EdgExtCV.dll`
(OpenCV, http://opencv.org in `Xphotolib.dll`). That belongs to the features and camera scope. On macOS, use Vision `VNDetectFaceRectanglesRequest`.

---

## 7. QR and barcodes

### Decode: ZBar
- [O] `libzbar-0.dll` is version 0.2.0 ("ZBar Bar Code Reader") and imports `libiconv-2.dll` (`libiconv_open`, `libiconv`, `libiconv_close`).
  libiconv exists only because ZBar needs it.
- [O] `Eventlib.dll` loads it dynamically. Resolved names: `zbar_processor_create/init/destroy/set_config`, `zbar_parse_config`,
  `zbar_process_image`, `zbar_image_create/set_format/set_size/set_data/first_symbol/destroy`,
  `zbar_symbol_next/get_type/get_data/get_data_length`.
- [O] Usage strings:
  - Detection: `CLiveViewWnd::EnableQRCodeDetection(cam=%#x,bSet=%i)`, `CLiveViewFrameThread detected QRCode=%s`,
    `CQRBackgroundThread::GetLastQRCode`, `QRBackgroundThread QRCode='%s'`.
  - Camera selection: `SetCameraProperty(h=%#x,LiveViewQRCodeDetection,d=%i)`, `Controls\QRCodeUseAlternateCamera`,
    `Controls\QRCodeAlternateCamera`, `BoothPage bQRCodeStarts=%i AltCam=%s`.
  - UI: "Allow touchless start if QR Code is detected" and "QR Code Setup...".
  - Payload parsing: `mailto:`, `smsto:`, `autoemail`, `autosms`, `autophone`, `gmail.com`, `yahoo.com`, `outlook.com` and similar.
- [I] A guest shows a QR code (for example a phone screen or a printed `BoothStart` QR) to the main or an alternate webcam.
  The QR either starts the session hands-free or supplies the guest's email or phone number for sharing.
- macOS: Vision `VNDetectBarcodesRequest` (symbologies `.qr` and others) on `AVCaptureVideoDataOutput` sample buffers. No ZBar or iconv is needed.

### Encode
- [O] `EdgQR.dll` is Darkroom-built (PDB `s:\Edg\Ver9.1\dst\release\symbols\EdgQR.pdb`). Its only imports are KERNEL32 and MSVCR80, so the
  encoder is self-contained. It exports ordinals 20, 21 and 22 only. `Eventlib.dll` and `Xphotolib.dll` load `edgQR.dll` with `@ORD:20/21/22`.
  `Xphotolib.dll` credits `http://fukuchi.org/works/qrencode/`, so it is [I] libqrencode-based.
- [O] Uses:
  - Support QR "MATMSG:TO:support@darkroomsoftware.com;SUB:LICENSE ERROR".
  - "Booth Start" sign: `https://www.darkroomsoftware.com/utl/qrBuild.htm?d=` with `http://BoothStart.com`, "Booth+Start+link", "Print Sign...".
  - QR codes in layout templates (`QR Code` type in the barcode object).
  - An embedded "Darkroom QR Code Helper" HTML page with jquery-qrcode.
- macOS: `CIFilter.qrCodeGenerator()` with `correctionLevel`.

### 1-D, 2-D and magnetic stripe template objects
- [O] `Eventlib.dll` has `CEdgBarcodeObject` (`GetLinearWMF`, `GetDatamatrixWMF`, `GetBarcodeFormat`). It loads `\idautomationlinear6.dll`,
  `\idautomationdmatrix6.dll`, `\idautomationpdf417_6.dll` and `\idautomationmaxicode5.dll`. Only the linear DLL is shipped.
- [O] Formats: Code 39, Interleaved 2 of 5, Code 11, Codabar, UPC-A, Industrial 2 of 5, Matrix 2 of 5, Code 93, EAN-13, EAN-8, UPC-E,
  Code-128, Planet, Postnet, UCC128, OneCode, plus QR Code, PDF417, Data Matrix and Maxicode.
- [O] Template serialisation markers: `BEGIN_BARCODE`, `FORMAT:`, `TEXT:`, `SHOWTEXT:`, `ORIENTATION:`, `BACKGROUNDCOLOR:`, `END_BARCODE`.
- [O] `CEdgMagneticStripeObject` holds mag-stripe data for ID-card printers ("This Darkroom product does not support writing the barcode
  magnetic stripe"). That is printer scope.
- macOS: CoreImage generators handle Code128, PDF417, Aztec and QR. Use **ZXing-cpp** (writer) for EAN/UPC/Code39/ITF/Codabar/DataMatrix.
  Render the result as vector or `CGImage`.

---

## 8. Email, SMS and MMS

### SocketTools 8.0.8050 (Catalyst Development)
Delay-imported by `Eventlib.dll` [O]. Ordinals were resolved against each DLL's export table:
- `csmtpav8.dll`: `SmtpInitializeA`, `SmtpConnectA`, `SmtpAuthenticateA`, `SmtpSendMessageA`, `SmtpDisconnect`,
  `SmtpGetLastError`, `SmtpGetErrorStringA`, `SmtpGetResultStringA`, `SmtpUninitialize`.
- `csmsgav8.dll` (MIME): `MimeInitializeA`, `MimeComposeMessageA`, `MimeAttachFileA`, `MimeAttachDataA`,
  `MimeSet/GetMessageHeaderExA`, `MimeGetMessagePartCount`, `MimeExportMessageExA`, `MimeDeleteMessage`.
- `csmapav8.dll` (IMAP): `ImapConnectA`, `ImapLoginA`, `ImapCreateSecurityCredentialsA`, `ImapSelectMailboxA`, `ImapSearchMailboxA`,
  `ImapGetMessage`, `ImapOpenMessageEx`, `ImapRead`, `ImapGetMessageParts`, `ImapGetHeaderValueA`, `ImapGetMessageSenderA`,
  `ImapGetMessageUid`, `ImapDeleteMessage` and others.
- [O] A 30-character upper-case token sits next to the strings `csmsgav8.dll`, `csmtpav8.dll` and `csmapav8.dll` in `Eventlib.dll` (offset 0x61005c).
  [I] It is the SocketTools runtime license key. It is deliberately not reproduced here.
- [O] An email-provider table (XML in `Eventlib.dll`) covers AOL, iCloud, Gmail (smtp 587 / imap 993, TLS), Hotmail/MSN (smtp.live.com), Yahoo (465 SSL),
  Yahoo Business, Comcast, Cox, TWC, SendGrid (`smtp.sendgrid.net`) and SMTP2Go (`smtpcorp.com:2525`). Only username and password auth appears.
  No XOAUTH2 was found for SMTP. The "oauth" strings belong to Facebook and Dropbox.
- [O] Usage: `CPhotoTaskEmail`, `CEdgEmailAccount` (incoming port, account type, POP and IMAP ports) and `DownloadEmails(CEdgEmailAccount&, CAutoInputSearchInfo&)`.
  IMAP is used for **AutoInput**: importing photos that guests email in, so they can be printed.
- macOS: Gmail and Microsoft 365 now require OAuth2 or app passwords.
  - Recommended: a provider HTTPS API (SendGrid, Mailgun, Amazon SES, Postmark) via `URLSession`.
  - Raw SMTP or IMAP: MailCore2 (Obj-C, supports XOAUTH2) or SwiftNIO-based SMTP.

### Email-to-SMS/MMS gateways
- [O] `MobileCarriers/Carriers.txt` lists:
  - AT&T `@mms.att.net`, Sprint `@pm.sprint.com`, T-Mobile `@tmomail.net`, Verizon `@vzwpix.com`
  - Boost `@myboostmobile.com`, Cricket `@mms.cricketwireless.net`, MetroPCS `@mymetropcs.com`
  - US Cellular `@mms.uscc.net` (its logo field reads `USCellular` with no `.jpg`, an upstream data bug)
  - Straight Talk `@mypixmessages.com`, Virgin `@vmpix.com`
- [O] The file is referenced as `MobileCarriers\Carriers.txt` and `"/res/MobileCarriers/` (web UI). Warning text: "some phone carriers limit the size of MMS messages…".
- [I] Several of these gateways have been shut down (Sprint, Virgin, and AT&T's in 2025). Treat this as legacy and prefer Twilio.

### Twilio
- [O] `Eventlib.dll` endpoints: `https://api.twilio.com/2010-04-01/Accounts/` + `/Messages.json` (with `&To=`, `&From=`, `&Body=`,
  `&MediaUrl=`), `/Messages.json?DateSent>=…&PageSize=%u` (inbound polling), `/Media.json`, `/IncomingPhoneNumbers.json[?PhoneNumber=]`,
  and `VoiceUrl=` with `http://twimlets.com/echo?Twiml=` and `<Response><Say voice="` (voice auto-answer).
- [O] Auth: AccountSID and AuthToken ("Copy the AccountSID and AuthToken…"), plus a Connect-app authorize URL
  `https://www.twilio.com/authorize/CN…/signin` and `http://www.darkroomsoftware.com/twilio_redirect`.
- [O] Media for MMS is staged through **Dropbox** ("Dropbox is used for intermediate storage when sending images through Twilio").
  A Darkroom AWS endpoint is also used: `https://4q3c0yszlg.execute-api.us-east-2.amazonaws.com/prod/tempupload?file=` with `&app=%s&ver=%u.%05u&id=%s`.
- macOS: `URLSession` Basic-auth POSTs. Host media yourself (S3 presigned URL) or with Twilio's own media handling.
  US A2P 10DLC registration now applies.

---

## 9. Social, cloud and other online services (all in `Eventlib.dll` unless noted) [O]

| Service | Endpoints and evidence | Purpose |
|---|---|---|
| Facebook Graph **v5.0** | `https://www.facebook.com/v5.0/dialog/oauth?client_id=%s&redirect_uri=%s&response_type=token&display=popup&scope=user_photos,user_events,user_posts,manage_pages,publish_pages`, `graph.facebook.com/v5.0/me`, `/me/accounts`, `/me/events`, `/me/permissions`, `/albums?access_token=`, `?fields=source,width,height,images.limit(3)`. Redirect `https://www.darkroomsoftware.com/connect/login_success.html`. Settings `Output\UserFacebook\Params`, `ConfirmFacebookPost`, `TimeSettings\FacebookPostDelay` (exe) | Post to Page or Event albums; import photos |
| Instagram | `https://api.instagram.com/oauth/authorize/...scope=public_content`, `api.instagram.com/v1/users/self` (legacy API, shut down 2020), `graph.facebook.com/5.0/ig_hashtag_search?user_id=`, `darkroomsoftware.com/igredirect` | Hashtag import (AutoInput) |
| Twitter, Instagram, Snapchat "post" | `darkroomsoftware.com/3rd/{twitter,instagram,snapchat}.html` and the text "Save the image to the local device and click here to post to …". Settings `Output\{Twitter,Instagram,Snapchat}Post\Params` | No API. The guest gets a link in email or SMS |
| Dropbox API v2 | `oauth2/authorize?response_type=token`, `files/upload`, `list_folder(/continue)`, `download`, `move`, `delete(_batch)`, `get_temporary_link`, `sharing/create_shared_link`, `users/get_current_account`, `auth/token/revoke`. Headers `Authorization: Bearer %s`, `Dropbox-API-Arg: %s` | Upload output, AutoInput source, MMS media hosting |
| EventGallery ("Hula Gallery") | `https://api.eventgallery.com/api/v1/picture/upload?collection-name=`, `/api/v1/token/status`, `app.eventgallery.com/operator/settings/integration`. Settings `Output\HulaGallery\*` | Online gallery upload |
| remove.bg | `https://api.remove.bg/v1.0/removebg` (multipart `image_file`, `size=full`, `format`), `/v1.0/account` | Cloud background removal |
| AutoInput sources | Types `Dropbox`, `Folder`, `Twitter`, `Twilio`, `Outspoken`, `Instagram`, `Facebook` plus email (Gmail, Outlook, Yahoo). SQLite table `AutoInputs(AutoInputType, Name, AccountName, Source, Tags, Sender, Recipient, …)` | Import guest-submitted or hashtag photos for printing |
| Darkroom update service | `cdn.darkroomsoftware.com` (`UpdateServer`), `update.xml`, `upgrade.xml`, product folder `drbooth`, `http://www.darkroomsoftware.com/drb/drbupdatev3.htm?new=1/2` (`CAutoUpdaterThread`) | Auto-update |
| Darkroom web | `qrBuild.htm?d=` (QR sign builder), `http://www.boothmanual.com`, `www.darkroomtemplates.com` | Help and templates |
| Darkroom online reports | `https://%s/dr3/login.aspx?au=%s&reports=1&d=1` (`Xphotolib.dll`) | Web reports |
| Legacy lab (Express Digital, Labtricity, PhotoReflect) | `expressdigital.com/bin/elab.dll`, `publisher.labtricity.com`, `publisher.photoreflect.com` | Lab ordering, inherited from shared libraries |
| QuickBooks | qbXML 2.0 `InvoiceAddRq` templates | Invoices |

Network plumbing [O]:
- WinINet: `InternetOpenA`, `InternetConnectA`, `Ftp*` (`CEdgFtpConnect`), `InternetDial` / `InternetHangUp` / `InternetGetConnectedState`.
- WS2_32 sockets.
- MPR: `WNetAddConnection2A` (`CNetShare`, mapped drives).
- `iphlpapi` `GetAdaptersInfo` for the "Booth Control IP Address List".
- macOS: `URLSession`, `NWPathMonitor` for connectivity, and `NetFS` for SMB.
  - FTP is not supported by URLSession. Use libcurl, or drop FTP in favour of SFTP or S3.

---

## 10. Built-in web server (BoothControl, remote control, "web inputs")

- [O] `Xphotolib.dll` imports `CSHTSRV8.DLL` (SocketTools HTTP Server): `HttpServerInitializeA`, `HttpServerStartA`, `HttpReceiveRequestA`,
  `HttpSendResponseA`, `HttpSendErrorResponseA`, `HttpSetClientHeaderA`, `HttpSetClientIdleTime`, `HttpServerStop`, `HttpServerUninitialize`.
- [O] Messages: "The default internet port 80 is in use by another program.", "Port in use", and the "Booth Control IP Address List (Use one
  of these addresses to connect to the booth computer.)" dialog.
- [O] Exports: `StartWebServer`, `StopWebServer`, `HandleWebServerCommand`, `GetWebServerPendingCommands`, `UpdateWebServerInputs`,
  `NotifyWebServerLiveUpdate`.
- [O] Pages: `/menu`, `/controls`, `/controls/custom`, `/kiosk`, `/links`, `/links/private`, `/manage_album`, `/sharemode`, `/slideshow`, `/stats`,
  `/survey/results[/n]`, `album.htm?fi=&f=`, `remove.cmd?fi=&f=`. `cmd="…"` buttons include `Start Video`, `color default`, `sepia default`, `Slideshow1..3`,
  `Default Primary` and `photocontrol`.
- [O] Control commands: "Restart Computer" and "Shutdown Computer" (`doCtrlCmd`, `cmdVerify="Y"`). "The booth has been locked by a Booth Control request".
- [O] The page is a phone-friendly PWA-ish UI (apple-touch-icon, `manifest.json`).
- [O] "BoothControl Custom Input" entries (`HandleWebServerInput`) map web buttons to the same action lists as Phidget inputs.
- macOS: an embedded HTTP server (Hummingbird or SwiftNIO). Since 10.14, macOS lets unprivileged apps bind ports below 1024, so port 80 works.
  Still default to a configurable port, advertise it with Bonjour, and add the local-network usage description.
  Reuse the same HTML and JS assets.

---

## 11. Audio and video output

- [O] `Eventlib.dll` has `DRAudioManager` with `PlayAudio`, `LoadAudio`, `FadeAudioIn`, `FadeAudioOut`, `FadeOutStop`, `MuteAudio`, `PauseAudio`, `IsBackgroundPlaying`,
  `GetSoundLength`, `EnableSounds` and `FindSoundIdFromEvent(ThreadEvents)`. Imports: `DSOUND.dll` ordinal 11 [I: `DirectSoundCreate8`], plus
  delay-imported Media Foundation (`MFCreateSourceReaderFromURL/ByteStream`, `MFCreateMediaSession`, `MFCreateVideoRendererActivate`,
  `MFCreateAudioRendererActivate`, `MFCreateSinkWriterFromURL`).
- [O] Formats: `WAV Files |*.wav`, `Sound Files |*.wav;*.wma;*.mp3`. Countdown folder "should contain countdown files such as: '1.wav', '2.wav', '3.wav'".
  Folder `X:\Sounds`. Switches `/Vol=%u /FadeIn /FadeOut /Loop`. "Music Volume", "Fade Music In/Out", "Loop Music".
- [O] Event hooks (UTF-16): Attract Mode, Photo Session, Video Session, During Session, Completed Quiz, Correct or Wrong Answer, and others.
- [O] `Xphotolib.dll` imports WinMM `mixerOpen`, `mixerGetLineInfoA`, `mixerGetLineControlsA`, `mixerSetControlDetails` (system volume and mute) and
  `mciSendCommandA` (legacy playback). `ReadyBeepOn` maps to `MessageBeep`.
- [O] `CVideoPlayer::PlayVideo(SVideoParams)` handles video files `*.avi;*.mov;*.mp4;*.wmv`.
- macOS:
  - `AVAudioEngine` with multiple `AVAudioPlayerNode`s for SFX, music and countdown, fading with `AVAudioMixerNode.outputVolume` ramps.
  - `AVQueuePlayer` / `AVPlayerLayer` for video.
  - WMA and WMV are not natively supported. Convert them, or use VLCKit if needed.

---

## 12. Displays

- [O] `EdgUtil.dll` exports `ChooseMonitor`, `GetNumMonitors`, `IdentifyMonitors`, `GetMonitorRectFromIndex`, `GetMonitorNumFromIdentifier`,
  `FindVacantMonitorRect` and `GetRectOfAllMonitors` (`EnumDisplayMonitors`/`MonitorFromWindow` imports).
- [O] `Xphotolib.dll` has `CXPage::ShowSecondaryMonitor(SMonInfo&)`.
- [O] Settings in `DarkroomBooth.exe`: `Where\2ndMon`, `Where\UseMonitor`, `Where\Attract\Enabled`, `\slideshow.htm`, `Slideshow\*`.
  Template fit modes: "Fit - Reduce template to fit within screen" and "Crop - Stretch template to fill screen".
- macOS: `NSScreen.screens` with `CGDisplayCreateUUIDFromDisplayID` for stable identity. Use a full-screen borderless window per screen
  and observe `NSApplication.didChangeScreenParametersNotification`.

---

## 13. Licensing and copy protection (do not port; replace)

- [O] `drbooth2.dll` (version info: "Darkroom Softwre", product "drb"):
  - Exports ordinals only (137).
  - Embeds libcurl (`# This file was generated by libcurl!`) and LibreSSL 3.0.2 (build path
    `…\Nalpeiron\Shafer\branches\Release_3.6.41\public\libressl…`).
  - Nalpeiron NSL sources: `..\..\FileCheck\nsl.c`, `nslFeatures.c`, `nslRPC.c`, `nalpsoap\nslsoap.c`.
  - Messages: "Failed license retrieval", "License code validation failed" and similar.
  - Imports WLDAP32 and getaddrinfo (curl). It is the **Nalpeiron licensing client**, renamed.
- [O] `filechck.dll` is "Nalpeiron Ltd., Nalpeiron Support DLL 7.0.0.0". It contains "Nalpeiron Licensing Service",
  `www.internetactivation.com/ECOSYSTEM/ActivationServer/trialregister/TrialChecker.aspx` and WMI `SELECT Model FROM Win32_ComputerSystem`
  (VM detection). It creates and starts the service (`CreateServiceA`/`StartServiceA`).
- [O] `Eventlib.dll`: `NalpeironServiceInstaller.exe`, `http://updatemyservice.com/NalpeironServiceUpdate2013.zip`, `NalpLibOpen error=%i…`,
  `drbooth.log` and `*.lic`.
- [O] `Xphotolib.dll`: "At least once every 6 months, you will need to refresh your license…", "cannot be used within virtual machines…
  information on purchasing a USB dongle", "cannot be used within remote desktop".
- [O] Legacy **Rainbow/SafeNet Sentinel SuperPro** dongle: `RNBOsproFindFirstUnit`, `RNBO_STANDALONE`, `RNBO_SPN_*`,
  `Common Files\SafeNet Sentinel\Sentinel System Driver\`, `InstallSentinelMsi`, plus "The Rainbow drivers needed to verify your hardware key…"
  and "A hardware dongle is required for running within virtual environments." No HASP, Wibu or Rockey.
- macOS: none of this applies. Use your own entitlement system.

---

## 14. Imaging helper libraries

- **LEADTOOLS 11.5.0.017** [O]:
  - `ltkrn11n.dll` ("LEADTOOLS(r) DLL for Win32") is imported by ordinal from `Eventlib.dll` (17 ordinals), along with `LTFIL11n` (13), `LTIMG11n` (1) and `LTDIS11n` (1).
  - The filter DLLs are BMP, CMP (LEAD compressed), FAX, PNG, PSD, TGA and TIFF.
  - [I] They load and save formats GDI+ cannot handle (PSD, TGA). Replace with ImageIO, which reads PSD and TGA.
- **libjpeg-turbo** [O]: `turbojpeg.dll` is loaded dynamically as `TurboJpeg.dll`. Decompression only: `tjInitDecompress`, `tjDecompressHeader`,
  `tjDecompress`, `tjDestroy` (`tjInitCompress` is also referenced). Replace with ImageIO.
- **gifsicle 1.88** [O]: run as a child process by `Eventlib.dll` with ` -Q%s -O3 --lossy=60%s -o %s %s` and ` --colors 256`. Help text recommends MP4 over GIF.
  - Replace with `CGImageDestination` (GIF, `kCGImagePropertyGIFDelayTime`, loop count).
  - For lossy optimisation, bundle a gifsicle binary (GPL-2, ship it as a separate executable), or use `gifski` (AGPL or commercial).
- **ProWorks Flipper Graph 1.301** (`flpgrf.ocx` + `flpgrf.lic`, "Copyright (c) 1997 ProWorks") [O]: `Eventlib.dll` has a `CFlpGrf` wrapper.
  [I] It draws report and stats charts. Replace with Swift Charts.
- **EdgExtCV.dll** (OpenCV) is features and camera scope.

---

## 15. Launchers and auxiliary executables

- `BoothMode.exe` [O]: imports only `CreateProcessA`, `GetModuleFileNameA`, `GetCommandLineA` and `MessageBoxA`/`wsprintfA`.
  Strings: `DarkroomBooth.exe`, ` -Booth `, `Unable to start DarkroomBooth.exe (Error=%u)`.
  It is **not** a lockdown tool: it starts the app straight into booth mode. `DarkroomBooth.exe` checks `-booth`.
  Kiosk behaviour lives in the main app (section 5).
- `SlideshowGraphics/SlideshowBrowser.exe` [O]: MFC42 plus an IE `CWebBrowser2` host. "ExpressDigital Slideshow" v1.0 opens `Slideshow.html` / `Index.html`.
  `autorun.inf` sets `OPEN=SlideshowBrowser.exe`. It also has `iepngfix.htc` and button graphics.
  [I] It is copied onto burned discs or USB sticks as a self-running slideshow (`CSlideshowGenerator`, `CBurnDisc`).
  Replace it with a plain HTML5 folder.
- `DarkroomBooth.exe.local` [O]: an empty file, a DLL-redirection marker (Windows-only, ignore).

---

## 16. Suggested macOS hardware abstraction (for the rebuild)

1. `TriggerSource` protocol (emits `TriggerEvent(id, edge)`). Implementations:
   - `PhidgetInputSource` (Phidget22)
   - `SerialModemLineSource` (DCD, CTS, DSR, RI)
   - `KeyboardSource`, `MouseSource`
   - `WebInputSource` (embedded HTTP)
   - `VoiceSource` (SFSpeechRecognizer)
   - `QRSource` (Vision)
   - `FaceSource` (Vision)
2. `ActionRunner` that executes the existing JSON action vocabulary: OUT/blink/duration, PAUSE, ADDCREDIT, BOOTHCOMMAND,
   SOUND, VIDEO, SCRIPT (map `.ahk` to AppleScript or shell).
3. `OutputSink` for Phidget22 `DigitalOutput`, with a blink scheduler and timed revert.
4. `CreditLedger` (startup and copy minimums) fed by any trigger mapped to ADDCREDIT.
5. `ShareService` adapters: SMTP or HTTP mail, Twilio, Dropbox, Facebook, EventGallery, remove.bg. Store credentials in the Keychain.

## 17. Limitations of this analysis

- Static only. Runtime behaviour, exact JSON schemas for `inputs.json`, and the default action bindings were not observed.
- Phidget sensor (analog) usage and the exact Windows-key hook behaviour are inferred from imports and option strings.
- DSOUND ordinal 11 is assumed to be `DirectSoundCreate8`, from the standard dsound export table (not verified against a DLL here).
- Ordinal-only imports from LEADTOOLS and the Nalpeiron `drbooth2.dll` were not resolved to names. Those DLLs export by ordinal only.
