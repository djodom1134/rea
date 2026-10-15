# Darkroom Booth 3.00.943: cameras and capture devices

Scope: every camera and capture-device integration in the install folder
`/mnt/project-files/rea-darkroom-booth/D27LibCom`, how the app loads and drives each one, and what a native macOS rebuild would use instead.

Method: static only. I read PE version resources and import/export tables with `pefile`, extracted ASCII and UTF-16 strings, decoded data tables in `Eventlib.dll`, and looked at a few cross-references with `objdump`. No binary was executed. Helper scripts and raw dumps are in
(local analysis scratch, not committed)
(`usbtable.txt` and `nikontable.txt` are the decoded tables).

Evidence labels:
- **[O] observed**: read directly from a file, as a string, export, import, version resource or decoded table.
- **[I] inferred**: reasoning from observed facts.
- **[K] external knowledge**: known SDK or platform facts that I did not verify here.

---

## 1. Architecture: who owns camera control

- **[O]** None of `DarkroomBooth.exe`, `Xphotolib.dll` or `Eventlib.dll` imports a camera SDK statically. The only non-system imports are the app's own DLLs, MFC, LEADTOOLS, ODBC, SocketTools, and delay-loaded Media Foundation in Eventlib. Every camera SDK is loaded at runtime with `LoadLibrary` + `GetProcAddress`.
- **[O]** `Eventlib.dll` (Darkroom Software, 9.20.943) contains all camera drivers. Its RTTI and exports show a polymorphic base class `CEdgCamera` with these subclasses:
  `CCanonCamera` (CD-SDK), `CCanonProCamera` (RC-SDK), `CCanonPRSDKCamera` (PS-ReC SDK), `CCanonEDSDKCamera` (EDSDK, plus `CCanonEDSDKDownloadThread` and `CCanonSdkThread`), `CNikonD1Camera` (the Nikon MAID path), `CFujiS1/S2/S20/S3/S5Camera`, `CGoProHero4` (+ `CGoProCameraThread`), `CVideoCamera` (DirectShow webcam/DV), `CFolderCamera`, `CHotFolderCamera` (+ `CHotFolderThread`), `CExternalCamera`, `CFakeCamera` ("EDG Sample Camera", "Express Digital DC-FAKE").
- **[O]** Supporting Eventlib classes: `CCameraSettings` (`FindDevice`, `CheckNikonCameras`, `GetCameraAttemptOrderType`, `AddCamera(ECamera)`, `IsCameraEnabled`), `CLiveViewWnd`, `CLiveViewThread`, `CLiveViewFrameThread`, `CLiveViewLoadThread`, `CChooseVideoCameraDlg`, `CMMFVideoPlayer`, and the free functions `DetectCamera(HWND,…) -> CEdgCamera*` and `FreeDetectedCamera`.
- **[O]** The exported `CEdgCamera` virtual interface is the abstraction a Mac port needs to reproduce:
  `InitializeCamera`, `IsAvailable`, `Open`/`Close`, `ReleaseCamera`, `GetCameraModel`/`GetName`/`GetCameraType`/`GetCameraID`, `GetCapabilities`/`GetSCapabilities`/`GetCameraCapabilities`, `IsLiveViewCapable`, `DoStartLiveView`/`EndLiveView`, `DoEvfAf`, `EnableCapture`, `EnableMonitorThread`, `GetLastImage`, `SaveImageToDisk`, `Read`/`Seek` (stream the image), `DeleteImage`/`DeleteAllImages`, `GetNumPics`/`GetPicsRemaining`, `GetCameraProperty`/`LoadCameraProperties`/`FindLoadedProperty`/`HasPropertyChanges`, `CanSetAperture`, `GetCameraAutoRotate`, `CaptureFramesRequested`, `GetMaxLiveViewTime`, `GetLastTakePictureRequestedTick`, `IsImportFromCameraAvailable`, and `Get/SetAutoRestoreCameraProperties`.
- **[O]** `Xphotolib.dll` holds the setup UI: `CSetupCameraPage`, `CCaptureOptionsDlg`, `CLiveViewDlg`, `CLiveViewAdvancedDlg`, `CDlgUntetheredSetup`, `CXFrame::DetectCamera`, and the TWAIN class `CTwain`.
- **[O]** `DarkroomBooth.exe` holds the booth UI: `CCameraSettingsPage`, `CCameraPane`, `CLiveViewSettings`, `CShutterAdjustTimeDlg`, `CVideoSettings`, and the video-session states `CBeforeVideoState`, `CDuringVideoState`, `CAfterVideoState` and `CVideoCountdownState`.
- **[O]** Detection is driven by a USB VID/PID table:
  - Log strings: `CCameraSettings::FindDevice found vid=%#x pid=%#x desc='%s'`, `No Image Class devs found`, `[%i] vid=%04x pid=%04x %s`, and the string `SetupDi`.
  - **[I]** The app resolves the SetupAPI functions dynamically, enumerates Image-class USB devices, and matches them against the table in section 2.
  - Related settings: `CanonAttemptOrder`, `CamerasEnabledSet`, `SearchForCameras`, `CameraDetectTried`, and `WarnCameraNotPresent`.

### Camera type list in the UI
**[O]** UTF-16 resource strings in `Eventlib.dll` at 0x96f06a and following:

> Any Camera, Canon Camera, External Camera, Fake Camera, Foveon Camera, FTP/Wireless Camera, Fujifilm S1/S2/S3 Camera (Not Vista Supported), Fujifilm S5 Camera (Vista Supported), Hot Folder Camera (Default), Kodak 26X Camera, Kodak DCS Camera (3XX, 4XX, 5XX or 6XX), Kodak DCS Pro 3 Camera (7XX), Kodak DCS Pro 4 Camera (14N, ProSLR), Kodak DCS ProBack Camera, Megavision Camera, Nikon D1 Series Camera, Nikon D2 Camera, Nikon D2Hs/D2X Cameras, Nikon D3/D3s/D300/D300s/D700 Cameras, Nikon D40/D40X/D60 Cameras, Nikon D50/D70/D70s/D80/D100/D200 Camera, Olympus E1 Camera, Phase One Camera, Photo Control Camera, Photo Control DC14 Camera, Sony FP3 Camera

A second table at 0x95c822 continues the list:

> Nikon D3X, D90/D5000, D7000, D3000, D5100, D800/D800E, D4, D600/D610, D5200, D7100, D5300, Df, D4s, D810, D750, D5500/D5600, D7200, D810A, 1 V3, D5, D500, D850, D7500, Z7 … plus "DV Camera" and "Webcam".

**[I]** The Kodak, Foveon, Megavision, Photo Control, Sony FP3 and Phase One entries are legacy names inherited from the Express Digital product line. None of them has a camera class in the RTTI, and no SDK for them ships. The only traces are error strings such as "The Kodak PDC image library … could not be loaded", "error retrieving the last picture from the Sony Camera" and "Stop monitoring Phase One Camera". Treat them as dead.

---

## 2. USB detection table (decoded) [O]

`Eventlib.dll` file offsets 0x630070–0x631050 hold 254 records of 16 bytes each:
`{u16 vid; u16 pid; char* name; u16 type; u16 sub; u32 0}`.
The full decode is in `usbtable.txt` in the scratchpad folder.

| VID | Vendor | Records | Notes |
|---|---|---|---|
| 0x04A9 | Canon | 184 | Runs from PowerShot S10 / EOS D30 (2000) to EOS 90D / M6 Mark II / M200 / G7X III / G5X II (2019) |
| 0x04B0 | Nikon | 66 | D100 through Z 7 / Z 6, and 1 V3. Pairs of PIDs: odd PID = mass-storage mode (type 0x02), even PID = PTP |
| 0x04CB | Fujifilm | 3 | S5 Pro (01c3), X3 Pro (0280), generic "SLR" (ffff) |
| 0x07B4 | Olympus | 1 | generic "SLR" (ffff), which is the E-1 |

**[I]** Meaning of the Canon `sub` field. I worked this out from which models share each value and from Canon SDK history ([K]):

| sub | Models in the table | SDK / class |
|---|---|---|
| 0x11 | 58 PowerShot/IXUS, 2000–2005 | CD-SDK 7.3 (`CCanonCamera`) |
| 0x13 | EOS D30, D60, 10D, 300D | CD-SDK, early EOS |
| 0x14 | EOS-1D, 1Ds, 1Ds II, 1D II, 1D II N, 5D, 20D, 350D | RC-SDK 8.4 (`CCanonProCamera`) |
| 0x12 (type 0x30) | PowerShot S80, A620, S3 IS, G7, A640, S5 IS, G9, SX100 IS, G10, SX110 IS | PS-ReC SDK 1.1 (`CCanonPRSDKCamera`) |
| 0x15 | EOS 400D/XTi, 30D | EDSDK, probably the legacy 2.7 build |
| 0x16 | 84 models from EOS 40D/450D/1D III to EOS R/RP/90D/M50/M6 II/M200, plus PowerShot G5X II/G7X III/SX70 | EDSDK |
| type 0x02 | PTP-mode PIDs of S45, G3, S230, 20D, 350D; also EOS M2/M3/M5/M6/M10/M100 | Treated as "wrong connection mode / not tetherable". The app's message: "A camera was found but the camera's connection mode is not set correctly" |
| type 0x04 | PowerShot SD630, G11, G12, G15 | **[I]** Not supported for capture ("Tethered Capture not supported for this camera model") |

Many records have PID 0. **[I]** Those models are matched by name string, not by PID.

---

## 3. Canon

### 3a. EDSDK: the main path for modern EOS and PowerShot

| File | Version resource [O] | Role |
|---|---|---|
| `EDSDK.dll` | "EDSDK" 13.11.0.0, PE timestamp 2019‑08‑23 | Current EDSDK. Imports SetupAPI, WS2_32 (Wi‑Fi/LAN capable) and `RegisterDeviceNotification`. Expects `EdsImage.dll` and `EdsPsf.dll`; **`EdsPsf.dll` is not shipped** [O] |
| `EdsImage.dll` | CANON INC. EdsImage 13.11.0.0 | Image decode for EDSDK 13.11. Exports `EdsImgInitialize`, `EdsImgGetImage`, `EdsImgSaveImage`, … |
| `e27dk.dll` | "EDSDK" 2.7.1.1, 2009‑10‑27 | **Renamed legacy EDSDK 2.7.1.** Internal name `E27DK.dll`; imports `STI.DLL` |
| `e27Image.dll` | EdsImage 2.7.0.3 | Legacy image module. Loads `D27LibCom.dll` (DPP communicator) |
| `D27LibCom.dll`, `D27dll.dll`, `D27rsc.dll`, `e27m.dll`, `e27ucs.dll` | DPP Library Communicator 1.2.1.2; DPPDll 3.7.3.0; DPPRSC 3.7.3.0; MLib 1.2.0.7; ColorGear 2.2.6 | Legacy raw-development chain behind e27Image (DPP 3.7.3, 2009) |
| `DPPLibCom.dll`, `DPPDLL.dll`, `DPPRSC.dll`, `MLib.dll`, `Ucs32P.dll` | DPP Library Communicator 3.15.0.900; DPPDll 3.15.0.903; DPPRSC 3.15.0.0; MLib 1.3.0.6; ColorGear C 3.1.5.1 | Newer DPP 3.15 raw-development engine. Exports `Dpp*` and `GNZ*` |

**Loader logic.** Eventlib function at VA 0x603c2a10 [O]:
- It builds a path using the "CanonEDSDK Drivers" setting or folder name. Then, if its numeric argument is `<= 0xCF` (207), it loads `E27DK.dll`; otherwise it loads `EDSDK.dll`.
- The raw-image loader calls it with `0x270F` (9999), which forces EDSDK 13.11.
- **[I]** The app keeps the old 2.7 SDK so that cameras dropped from EDSDK 13.x still work, for example the 30D and 400D.
- Next to the loader are the strings `dppdll.dll`, `dpprsc.dll`, `mlib.dll` and `LoadRaw48`, plus `DarkroomBooth.exe` `CAbortClass::AllowRaw48`. **[I]** CR2 files are developed to 48-bit RGB through the DPP/EdsImage chain.

**EDSDK functions resolved by name** [O] (the `GetProcAddress` string table at Eventlib 0x62ec80):
- Session: `EdsInitializeSDK`, `EdsTerminateSDK`, `EdsGetCameraList`, `EdsGetChildCount`, `EdsGetChildAtIndex`, `EdsGetDeviceInfo`, `EdsOpenSession`, `EdsCloseSession`, `EdsRetain`, `EdsRelease`
- Events: `EdsSetPropertyEventHandler`, `EdsSetObjectEventHandler`, `EdsSetCameraStateEventHandler`, `EdsSetCameraAddedHandler`
- Commands: `EdsSendCommand`, `EdsSendStatusCommand`
- Properties: `EdsGetPropertySize`, `EdsGetPropertyData`, `EdsGetPropertyDesc`, `EdsSetPropertyData`
- Storage and transfer: `EdsGetDirectoryItemInfo`, `EdsDeleteDirectoryItem`, `EdsCreateFileStream`, `EdsDownload`, `EdsDownloadComplete`, `EdsDownloadCancel`, `EdsGetVolumeInfo`, `EdsSetCapacity`
- Images and streams: `EdsGetImageInfo`, `EdsCreateImageRef`, `EdsCreateMemoryStream`, `EdsGetImage`, `EdsGetPointer`, `EdsRead`, `EdsCreateMemoryStreamFromPointer`, `EdsGetLength`
- Live view: `EdsCreateEvfImageRef`, `EdsDownloadEvfImage`

**Features in use**, from log and UI strings [O] (meanings marked [I] where inferred):
- **Remote capture.** Shutter release is set to Auto (photo timers) or Manual. There is a "Shutter Time Adjustment" that measures the average shutter delay.
  - Log strings: "Cannot take picture due to movie crop" and `ObjCallback CaptureError errcode=%#x`.
- **Download on object events.**
  - Log strings: `EDSDK Event DirItemCreated` and `DirItemRequestTransfer`.
  - The download runs on its own thread (`CCanonEDSDKDownloadThread`).
  - Save-to options are "Save to computer only" and "Save to computer and camera card", via `EdsSetCapacity`, `CaptureToMemoryCard` and `CanonIgnoreSetCapacity`.
- **Live view (EVF).**
  - Log strings: `CCanonEDSDKCamera::DoStartLiveView`, `Evf_OutputDevice=%i`, `EDSDK EndLiveView evf off`, `DoEvfAf`.
  - Settings: `LiveViewMaxTime_EDSDK`, `LiveViewExtFlashCompensation`, "Pause liveview to capture photo".
  - Autofocus lock and unlock (`SetCameraProperty autofocus lock/unlock`), and the property "*N=Evf AF Mode".
- **Movie recording.**
  - Log strings: `EDSDK start movie record`, `EDSDK stopping record`, `PREINIT Recording locked` (UI lock via `EdsSendStatusCommand`), "Deleting last movie".
  - Options: "Transfer video recordings", "Move video files to computer" or leave them on the card, and playback frame rates from "Normal" to "60X slower" (slow motion).
  - Per-model special cases: `Canon Kiss M`, `Canon EOS M50`, `CanonVideoEx`.
- **Properties** (UI names `*N=…`):
  - Exposure: AE Mode, Shutter Speed (Tv), Aperture (Av), ISO, Exposure Compensation, Metering Mode
  - Colour and image: White Balance (Auto, Daylight, Shade, Cloudy, Tungsten, Fluorescent, Flash, Color Temperature, Custom/PC1–5), Picture Style (Standard, Portrait, Landscape, Neutral, Faithful, Monochrome, User 1–3), Color Space, Image Quality (full list: JPEG L/M/S/S1–S3 Fine/Normal, RAW, MRAW, SRAW and their combinations)
  - Flash and focus: Flash, Red-Eye, AF Mode (One-Shot, AI Servo, AI Focus, Manual)
  - Status: Battery, Card status ("NO MEDIA", "%3.2lfGB available")
  - Video: Video ISO, Video Av
  - Mapping helpers: `MapAEModeFromCamera`, `MapAvFromCamera`, `MapTvFromCamera`, `MapISOFromCamera`, `MapExposureCompensationFromCamera`, `MapMeteringModeFromCamera`
- **Settings persistence.** Camera settings are saved per camera model under `Camera Settings\$LastCam.ini`, with an auto-restore option.
  - Messages: "Some camera properties could not be restored." and "The camera does not allow this property to be set from software."
- **Keep-alive.** The `KeepAlive` string. **[I]** This maps to `kEdsCameraCommand_ExtendShutDownTimer`.
- **Error handling.**
  - Messages: "Error loading Canon EDSDK, please contact customer care.", "Insert a valid memory card into camera.", "Please use the camera's mode dial.", "Check camera mode.", "Camera is unable to record a movie now."
  - Options: `ShowCanonErrorMessage`, `LastCameraError`, `__TMP_LAST_CANONEDSDK__`.

**Supported models.** About 100 EOS and PowerShot names in the table, from 30D/400D (legacy SDK) to EOS R/RP/90D/M50/M6 II/M200/250D (EDSDK 13.11). **[K]** EDSDK 13.11 is the 2019 release that added the 90D, M6 II and G5X II/G7X III.

### 3b. Canon PowerShot drivers (`Canon PowerShot Drivers\`), legacy

| File | Version [O] | SDK |
|---|---|---|
| `CDSDK.dll` (+ `cdRAPCLS`, `cdPTPCLS`, `cdPTPCLT`, `cdDvlp`, `cdDcd`, `cdParse`, `IWrap`, `psCamDat`, `cdProc.exe`, `cdProcmn.exe`, `EWatch.exe`) | Canon Digital Camera SDK 7.3.0.6, 2005 | **CD-SDK 7.3**. Exports `CDAFLock`, `CDEnterReleaseControl`, `CDEnumAvValue*`, `CDActViewfinderAutoFunctions`, RAW develop … |
| `prSDK.dll`, `prLIB.dll` | PS-REC SDK 1.1.0.20 / 1.1.0.12, Nov 2005 | **PowerShot Remote Capture SDK (PS-ReC) 1.1**. Exports `PR_StartSDK`, `PR_GetDeviceList`, `PR_ConnectCamera`, `PR_InitiateReleaseControl`, `PR_RC_Release`, `PR_RC_StartViewFinder`/`TermViewFinder`, `PR_RC_DoAeAfAwb`, `PR_RC_FocusLock`, `PR_Get/SetDevicePropValue`, `PR_RC_GetReleasedData`, `PR_GetFunctions` |

- **[O]** Eventlib binds through function tables: `CDGetFunctions` and `CDGetDeviceCount` from `CDSDK.dll`/`cdsdk.dll`, and `PR_GetFunctions` from `PRSDK.dll` in the subfolder "Canon PowerShot Drivers".
- **[O]** The PS-ReC path supports live view: `PrViewFinderCallbackFunction`, `CanonPRSDKLiveViewFetchProc`, `CanonPRSDK_ViewFinder`, `$PRSDK00.jpg`, `MonitorPRSDKCameraProc`.
- **[O]** Properties shown in the UI: Zoom Position, AF Mode, Focus Point, AF Search Range, Strobe Setting, Image Size, File Format (incl. CRW), Exposure Mode (scene modes), Flash Compensation.
- **[O]** Error strings: "Error loading Canon CDSDK.dll", "Error getting Canon SDK functions.", "Error Starting Canon SDK, error: %x".

### 3c. CanonPro drivers (`CanonPro Drivers\`), legacy EOS

| File | Version [O] | SDK |
|---|---|---|
| `RCSDK.dll`, `RCRAPCLS.dll`, `psdkdll.dll`, `pscSetup`, `pscCllct`, `pscAdimg`, `Pscl2STI.dll`, `CmSelDlg.dll`, `RcCamDat.dll`, `rcDvlp`, `rcDcd`, `rcParse`, `RC2DVLP`, `deImgT10/2X/31/32/40/41/50/60/70` | RCSDK 8.4.0.28, psdkdll 8.5.0.52, 2004–2005 | **Canon RC-SDK 8.x / PS-SDK**. Exports `RCCapture`, `RCAFLock`, `RCDevelop*`, `RCCreateRAWObject`, … |

- **[O]** Bound via `RCStartSDK`, `RCGetFunctions` and `RCFinishSDK` from `RCSDK.dll` in "CanonPro Drivers\".
- **[O]** Background RAW thumbnail loading (`CCanonProBackgroundLoader`), with the settings `CanonRawQuality` and `CanonRawThumbQuality`.
- **[O]** Error strings: "Error loading CanonPro RCSDK.dll", "Error starting CanonPro SDK."
- **[I]** This path serves sub-code 0x14 models: EOS-1D/1Ds/II/II N, 5D, 20D and 350D.
- **[I]** `deImgT*` are per-generation RAW developers for those bodies.

### 3d. Other Canon-related files
- **[O]** Model-specific behaviour keyed on model strings: `eos-7d`/`eos 7d`, `EOS KISS REBEL 300D`, `EOS-1DS`, `REBEL T5i`/`EOS 700D`/`Kiss X7i` (sets `DelayBeforeVideoDownload`), and the profile int `CanonLegacy` (default −99, meaning auto by model).
- **[O]** Canon's printer SDK files (`cpusbxpm`, `904*`, `S1245*`) are printer integrations and out of scope here.

---

## 4. Nikon

### 4a. Nikon SDK (MAID3) modules: the main path
- **[O]** Eventlib resolves `MAIDEntryPoint` from each module. Every `.md3` exports `MAIDEntryPoint` and `_NkDevCtrlEntry@8`.
  - Log strings: `Nikon LoadModule(%s) returns %#x MaidEntryPoint=%#x`, `Nikon: Open Source returns %i`, `Source Initialized=%d NumCameras=%u`, `Nikon CameraModel: %s`.
- **[O]** The modules are PTP-over-USB. `NkdPTP.dll` ("Nikon PTP Device Driver (32bit)" 1.3.1.3001, 2018) and `Nkd000.dll` (1.0.2.3000) export `NkDriverEntry` and use COM. `Nkd000.dll` contains `IWiaEventCallback` [O]: **[I]** it uses WIA for device arrival and transport. `NkdStor.dll` (Storage Device Driver) uses `DeviceIoControl`.

**Model → module table** [O], decoded from Eventlib 0x637278 (records of `{ECamera type, ptpPID, storagePID, name, flags, module}`):

| Module (file version) | Models |
|---|---|
| `D100_Mod.md3` 2.1.0 | D100 |
| `D2h_Mod.md3` 1.0.1 | D2H |
| `D200_Mod.md3` 2.1.0 | D200 |
| `D2_Mod.md3` 2.1.0 | D2X, D2Hs, D2Xs |
| `D40_Mod.md3` 1.3.0 | D40, D40X, D60 |
| `D50_Mod.md3` 2.1.0 | D50 |
| `D70_Mod.md3` / `D70s_Mod.md3` | D70, D70s |
| `D80_Mod.md3` 1.1.0 | D80 |
| `Type0001.md3` 1.10.3 | D3, D3S, D300, D300S, D700 |
| `Type0002.md3` 1.6.3 | D3X |
| `Type0003.md3` | D90, D5000 |
| `Type0004.md3` | D7000 |
| `Type0005.md3` | D5100 |
| `Type0006.md3` | D800, D800E |
| `Type0007.md3` | D4 |
| `Type0008.md3` | D600, D610 |
| `Type0009.md3` | D5200 |
| `Type0010.md3` | D7100 |
| `Type0011.md3` | D5300 |
| `Type0012.md3` | Df |
| `Type0013.md3` | D4s |
| `Type0014.md3` | D810, D810A |
| `Type0015.md3` | D750 |
| `Type0016.md3` | D5500, D5600 |
| `Type0017.md3` | D7200 |
| `Type0018.md3` | D5 |
| `Type0019.md3` | 1 V3 |
| `Type0020.md3` | D500 |
| `Type0021.md3` | D7500 |
| `Type0022.md3` | D850 |
| `Type0023.md3` 1.0.0 (2018‑08) | Z 7 |
| `Type0024.md3` (**not shipped** [O]) | Z 6. Detection exists but the module is missing, so the Z 6 will fail |
| none | D3000, D3100, D3200, D3300: listed with no module, i.e. not tetherable [O] |

The `Type00xx.md3` modules are dated 2018‑06. The flags column holds values 0x40, 0x80, 0x180, 0x178 and 0x200. **[I]** These are probably capability bits (live view, video, Z-mount).

**Features** [O]:
- **Live view.**
  - Log strings: `NikonLiveView: CAPABLE of GetLiveViewStatus, GetLiveViewProhibit, GetLiveViewImage`, `DoStartLiveView Set LiveViewStatus`, `GetLiveViewImage returns %i framesize=%u`.
  - Error: "Error: Camera must be in manual focus with live view ON".
- **Video:** `Nikon_VideoAv`, `Nikon_VideoISO`, `Nikon_VideoPlayback`, Movie Quality (1920x1080 24/25/30p …), Microphone Sensitivity, Card Slot.
- **Properties:** Shutter Speed, Aperture, Flash Sync, Compression Level, White Balance Mode, Focus Area Mode (Face Priority, Wide/Normal Area, Subject Tracking), and Lens.
- **Readiness checks:** "NO (aperture ring not minimum)", "NO (mirror up)", "NO (Lens locked)", "NO (high temperature)", "NO (no media)", "NO (low battery)", and so on.
- **Errors and warnings:**
  - "A Nikon camera was detected but the camera is set to STORAGE mode. Please set the camera to PC MODE and retry."
  - "Unable to open connection to camera. … restart Windows to reset the camera device driver."
  - "Error loading/initializing/opening Nikon Module. Error: %d"
  - "The camera wants to shut down in %d seconds …"

### 4b. Nikon D1 series over FireWire (obsolete)
- **[O]** The D1/D1H/D1X path uses three files:
  - `D1_Mod.md3` (Nikon D1 Module 3.1.2, contains "Nikon D1", "Nikon D1s")
  - `D1_Drv.dll` (Nikon D1 series Driver 2.0, 2001, export `NkDriverEntry`, device `\\.\%s` "NikonDx")
  - `NkD1394p.dll` ("Nikon 1394 plain protocol interface driver", 2000; exports `Send1394Command`, `Get1394Status`, `BusConfig1394`; opens `\\.\WDM1394`)
- **[O]** Eventlib strings: `D1_mod.md3`, `NikonD1TempImage`, `NIKON D1/D1H/D1X`, `OpenNikonD1CameraImage`.
- **[I]** This needs IEEE 1394, which Apple Silicon Macs do not have. **Drop it.**

### 4c. NEF decoding
- **[O]** Eventlib refers to `NkImgSDK.dll`, `NkBrowseLib%s.dll`, `Nkfl_Entry`, `OpenNEFSession`, and the path `Nikon\Library\`.
- **[O]** None of these is shipped. **[I]** NEF decoding depends on Nikon software already being installed.

---

## 5. Other still cameras (code present, SDK not shipped)

| Camera | Evidence [O] | Status |
|---|---|---|
| Fujifilm S1 Pro / S2 Pro / S20 Pro / S3 Pro | Classes `CFujiS1/S2/S20/S3Camera`. Loads `Camera\Fuji S1\su60api.dll`, `su400api.dll`, `su410api.dll`, `su500api.dll`, `exif.dll`. Functions `SU60_Shoot`, `SU60_SetShutterSpeed`, `SU60_SetAperture`, `SU60_SetSensitivity`, `SU60_SetWhiteBalanceMode`, `SU60_ReadImage`, … UI label "(Not Vista Supported)" | None of these DLLs ships. Obsolete |
| Fujifilm S5 Pro | `CFujiS5Camera`, `Camera\FujiS5\S5PROAPI.DLL`: `S5PRO_Shoot`, `S5PRO_ReadImage`, `S5PRO_SetUSBMode`, … | DLL not shipped. Obsolete |
| Olympus E-1 | `OpenOlympusE1CameraImage`, "Error loading EdgOlympusCamera.dll", "Olympus E1 Camera Driver.exe" | Not shipped. Obsolete |
| Message "The camera manufacturer does not support tethering this camera in 64-bit Windows" | Next to the "Olympus" and "Fujifilm" strings | **[I]** Fuji and Olympus are disabled on x64 |

---

## 6. GoPro (Wi-Fi HTTP)

**[O]** Class `CGoProHero4` and `CGoProCameraThread`, type name "GoPro4 Camera". Everything below is observed in Eventlib.

- **Control.** The camera IP is `10.5.5.9`, with these HTTP endpoints:
  - `http://%s/gp/gpControl/status`
  - `/gp/gpControl` (capabilities JSON: `modes`, `settings`, `display_name`, `options`)
  - `/gp/gpControl/command/shutter?p=%i`
  - `/gp/gpControl/command/%s?%s=%i`
  - `/gp/gpControl/setting/%u/%i`
  - `/gp/gpMediaList`
  - `/videos/dcim/%s` (download)
  - `storage/delete/last`
  - `system/locate`
  - `&sub_mode=`
- **Camera info read:** `info\model_name`, `info\firmware_version`, `info\serial_number`, `info\ap_mac`.
- **Saved settings:** `GoPro_LastMac`, `GoPro_LastModel`. **[I]** The MAC is probably kept for Wake-on-LAN.
- **Live view.**
  - Stream control: `/gp/gpControl/execute?p1=gpStream&c1=restart` and `…&c1=stop`.
  - Decoding: the app spawns **`ffmpeg.exe`** with `-fflags nobuffer -f:v mpegts -probesize 8192 -i udp://…`, looking in the app folder or `C:\ffmpeg\ffmpeg.exe`.
  - `ffmpeg.exe` **is not shipped** [O].
- **Video:** `GoPro_VideoTransfer`, `GoPro_VideoBitRate`, `GoPro_VideoPlayback`, plus "Darkroom Photo/Video/Slow-Motion Defaults" preset groups.
- **[K]** This is the legacy Hero4–Hero7 gpControl API. Hero 9 and later use the **Open GoPro** API (`/gopro/camera/...`, over Wi-Fi or USB NCM).

---

## 7. Webcams, DV and video capture (DirectShow)

- **[O]** Class `CVideoCamera`, type names "Webcam" and "DV Cam" / "DV Camera".
- **[O]** DirectShow filter-graph strings: `Sample Grabber`, `Smart Tee`, `Null Filter`, `Preview`, `Capture`, `Still`, `FriendlyName`, `Audio`.
- **[O]** Error strings: "Error cannot enumerate video devices. Please check DirectX version.", "Error video camera is not DV camera".
- **[O]** COM via `CoCreateInstance`, `MkParseDisplayName` and `CreateBindCtx`. **[I]** Devices are selected by moniker display name.
- **[O]** UI and settings:
  - Property pages: "Camera Properties", "Video Frame Size", "Video Compression", "Audio Properties", "Recording Device"
  - Settings: `VideoStillSize`, `VideoFrameSize`, `DefaultVideoCam`, `WebCam_VideoPlayback`
  - Recording to `$lastvid.avi`
  - Dialogs: `ShowChooseVideoCameraDialog`, "Choose Webcam…", "Web Camera Selection"
- **[O]** Booth behaviour:
  - "if a supported digital SLR camera is detected, the SLR camera will be used first"
  - "Use alternate webcam to detect QR Code" (`Controls\QRCodeAlternateCamera`)
  - Text in a dialog notes that DSLRs often cannot autofocus in live view, so a webcam can be used for QR scanning instead
- **[O]** **Snap Camera** integration:
  - Launches `Snap Inc\Snap Camera\Snap Camera.exe --minimized-mode`
  - Reads `Snap\Snap Camera\settings.json`
  - Toggles lenses by messaging `QTrayIconMessageWindowClass` ("Toggle Snap Camera Lens effect on and off")
  - **[K]** Snap Camera was discontinued in January 2023.
- **[O]** Media Foundation (`MFCreateSourceReaderFromURL`, `MFCreateSinkWriterFromURL`, `MFCreateMediaSession`) is delay-loaded for `CMMFVideoPlayer`. **[I]** It handles playback, transcoding and burst-frame extraction, not capture.

---

## 8. Non-tethered sources

- **[O]** **Hot Folder Camera** (default; `CHotFolderCamera`, also "H1"/"H2 Hot Folder Camera").
  - Settings: `Camera\HotFolder`, `HotFolderLatency`, `UseOrigTimestamp`, `UseOrigFilename`.
  - **[I]** This is the generic fallback for any camera, e.g. vendor tethering software, card readers or Eye-Fi.
- **[O]** **Folder Camera** (`CFolderCamera`): `UseFolderCamera`, `FolderCameraWait`.
- **[O]** **FTP/Wireless Camera** (`CEdgFtpConnect`), described as "FTP Camera - from any FTP camera". It is a "dedicated" camera that conflicts with tethered ones.
- **[O]** **External Camera** and **Fake/Sample Camera** (`TestCamera\`, `Enable Fake Camera`) are used for demo or trial mode.
- **[O]** **TWAIN** (`CTwain` in Xphotolib: `LoadSourceManager`, `OpenDefaultSource`, `BeginAcquire`, `DibReceived`; message "TWAIN initialization failed").
  - No `TWAIN_32.DLL` or `DSM_Entry` string exists anywhere [O].
  - The exported `CTwain::LoadSourceManager` resolves to a trivial state-check stub.
  - **[I]** TWAIN acquisition is vestigial or disabled in this build.

---

## 9. Live view pipeline and booth features (cross-device) [O]

- **Window and threads:** `CLiveViewWnd` with `CLiveViewThread`, `CLiveViewFrameThread` (polling) and `CLiveViewLoadThread` (`UseLiveviewLoadThread`).
- **Frame-rate logging:** `Avg LiveView Polling FrameRate`, `LiveViewFrameRate`, `LiveViewFast`, `LiveViewInterpolate`.
- **Display options:** mirror, rotation (`CameraOrientation`, `SetDefaultOrientation`), layered window (`LiveViewLayered`), grid ("EVF Grid"), overlay text, and a live-view placeholder in layouts (`HasLiveViewPlaceHolder`).
- **Detection on the live feed:** QR code detection via `libzbar-0.dll` (`EnableQRCodeDetection`, `CLiveViewFrameThread detected QRCode=%s`) and face detection (`EnableFaceDetection`, `GetNumFacesDetected`; **[I]** OpenCV in `EdgExtCV.dll`).
- **Capture timing:** `TimeSettings\LiveviewPause`, "Pause liveview to capture photo" vs "Continue liveview without pause", and the shutter-delay estimator ("Average shutter delay: %u milliseconds", `ShutterAdjustTime`, `CameraShutterMonitor`).
- **Sessions:** burst sessions (video captured, frames extracted), video sessions ("Resetting camera after video session", "Video recording is not supported for this camera.").
- **Trigger input:** Phidgets InterfaceKit (`phidget21x86.dll`; `CPhidgetInterfaceKit_*`, `CPhidgetManager_*`) for physical buttons and I/O. Phidgets has a macOS library.

---

## 10. macOS replacement map

| Windows integration | Status | macOS path |
|---|---|---|
| **Canon EDSDK 13.11** (EOS 40D … R/RP/90D/M50/M6 II/M200, PowerShot G5X II/G7X III/SX70) | Current | **Canon EDSDK for macOS** [K]: free with Canon developer registration (Canon Developer Community / CDP). Recent 13.x releases ship a universal (arm64/x86_64) framework, with the same API: `EdsDownloadEvfImage` for live view, `kEdsPropID_Record` for movies, the same property IDs. **Mac EDSDK support for pre-2012 bodies has been trimmed, so check the model list of the release you use.** Fallback or complement: **libgphoto2** (`ptp2` driver: Canon EOS remote capture, `capture_preview` live view, config of ISO/aperture/shutter/WB, movie start/stop on many bodies). **ImageCaptureCore** `ICCameraDevice.requestTakePicture()` gives basic tethered capture and download on PTP cameras, but has no live view or exposure control, so on its own it is not enough for a booth |
| Legacy EDSDK 2.7.1 (`e27dk.dll`, for 30D/400D) | Obsolete | No supported Mac SDK [K]. libgphoto2 is the only path [I]. Otherwise drop |
| Canon CD-SDK 7.3 (PowerShot 2000–2005, EOS D30/D60/10D/300D) | Obsolete | Drop. The Mac CD-SDK was PPC/32-bit only [K]. Some models are partly reachable via libgphoto2 [I] |
| Canon PS-ReC 1.1 (PowerShot S80/A620/G7/G9/G10/SX100/SX110 …) | Obsolete | Drop, or use libgphoto2's Canon PowerShot PTP remote capture where it works [K/I] |
| Canon RC-SDK 8.x (1D II/1Ds II/5D/20D/350D) | Obsolete | Drop, or libgphoto2 [I] |
| DPP/EdsImage raw development (`DPPDLL` 3.15, `D27dll` 3.7.3) | — | Core Image `CIRAWFilter` decodes CR2/CR3/NEF natively. Canon's image path is EDSDK `EdsGetImage` |
| **Nikon MAID3 modules** (D100 … D850, Z 7; Z 6 module missing) | Current (2018 modules) | **Nikon SDK for macOS** [K]: the same MAID3/C3 API and per-model `Type00xx.md3` bundles, free with registration at the Nikon Imaging SDK site. Newer modules cover Z-series bodies. Very old modules (D1, D100, D2H, D70) are not available for current macOS [I]. Alternative: **libgphoto2** (`ptp2`), which has good Nikon support for D-series/Z-series capture, live view and property control [K] |
| Nikon D1 over IEEE 1394 (`NkD1394p`, `D1_Drv`) | Obsolete | Drop. Apple Silicon has no FireWire |
| Fujifilm S1/S2/S3/S5/S20 SDKs, Olympus E-1 | Obsolete (and not shipped) | Drop. Modern Fujifilm X/GFX has an official Fujifilm X Acquire / Tether SDK, macOS availability unverified [K]. libgphoto2 also covers some Fujifilm and Olympus models |
| Sony, Panasonic, other mirrorless (not supported by this app) | Not present [O] | Optional new support: libgphoto2, Sony Camera Remote SDK (macOS) [K] |
| **GoPro** (Hero4 gpControl over Wi-Fi + ffmpeg UDP preview) | Legacy API | Plain `URLSession`. Add **Open GoPro** HTTP API for Hero 9+ (Wi-Fi or USB). Decode the MPEG-TS preview with bundled FFmpeg/libavcodec or VideoToolbox. Many recent GoPros also act as UVC webcams (AVFoundation) |
| **Webcam / DV / HDMI capture card** (DirectShow) | — | **AVFoundation**: `AVCaptureDevice.DiscoverySession` (built-in, external UVC, `.continuityCamera`), `AVCaptureVideoDataOutput` for frames and QR/face, `AVCapturePhotoOutput`/`AVCaptureMovieFileOutput`. HDMI capture cards (Elgato, Magewell, UVC dongles) appear as UVC devices. DV/FireWire is obsolete |
| Snap Camera | Discontinued product | Drop. Virtual cameras (e.g. OBS) appear in AVFoundation via CoreMediaIO camera extensions |
| QR / face detection (zbar, OpenCV) | — | Vision framework (`VNDetectBarcodesRequest`, `VNDetectFaceRectanglesRequest`) |
| Hot folder / folder camera | — | `DispatchSource`/FSEvents folder watching |
| FTP/Wireless camera | — | Watch a folder fed by any FTP server, or embed a small FTP server. Cameras push via FTP |
| TWAIN | Vestigial | ImageCaptureCore `ICScannerDevice`, if scanning is needed at all |
| Phidgets trigger | — | Phidget22 macOS library |
| Device detection by VID/PID | — | IOKit `IOServiceMatching(kIOUSBHostDeviceClassName)` notifications or ImageCaptureCore `ICDeviceBrowser`. Reuse the VID/PID → SDK tables in section 2 and section 4 |

**Recommended Mac architecture** [I]:
- A `CameraDriver` protocol mirroring the `CEdgCamera` interface in section 1.
- Backends, in priority order:
  1. Canon EDSDK (macOS)
  2. Nikon SDK (macOS)
  3. libgphoto2, for everything else and for models the vendor SDKs dropped
  4. AVFoundation, for webcams, capture cards and UVC GoPros
  5. GoPro HTTP
  6. Hot folder / FTP
- A model table keyed by USB VID/PID selects the backend, the same way Eventlib's tables do now.

---

## 11. Unknowns and limits

- **Canon `sub` codes.** The meanings in section 2 are inferred from grouping. The code that dispatches on them was not traced.
- **Nikon flags.** The meaning of the flags column (0x40 … 0x200) is unknown.
- **DPP 3.15 caller.** Who loads `DPPLibCom.dll` (DPP 3.15) is unresolved. `EdsImage.dll` 13.11 has no string referring to it. **[I]** Eventlib loads it directly for `LoadRaw48`.
- **EDSDK version argument.** The exact rule that makes Eventlib pass a version `<= 207` to the EDSDK loader (and so pick legacy 2.7) was not traced.
- **Model support claims.** Supported-model lists for each SDK version come from the app's own tables, not from the SDK binaries. The SDK DLLs carry almost no model strings.
- **Runtime.** Nothing was verified at runtime: no hardware, no execution.
