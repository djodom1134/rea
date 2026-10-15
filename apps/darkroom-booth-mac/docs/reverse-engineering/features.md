# Darkroom Booth 3.00.943: features, workflow and data model

Scope: the features users see, the booth workflow, the data model and the web services it calls. Hardware drivers (cameras, printers, peripherals) are covered by other reports.
Method: static analysis only. Sources were PE version info, import/export tables, resources (dialogs, string tables, menus, HTML/XML/WEB resources) and ASCII/UTF-16 strings. No Windows binary was executed.
Install folder: `/mnt/project-files/rea-darkroom-booth/D27LibCom`.

Legend: **[O]** observed directly in the binary (string, resource, export). **[I]** inferred from observed evidence, not proven.
File abbreviations: `EXE`=DarkroomBooth.exe, `EVL`=Eventlib.dll, `XPL`=Xphotolib.dll, `UTL`=EdgUtil.dll.

---

## 1. Component map

| File | Identity (version info) | Role in the product |
|---|---|---|
| DarkroomBooth.exe | Darkroom Software, "Darkroom Booth" 3.00.943, built Dec 10 2020; PDB `s:\Edg\Ver9.1\dst\Release\Symbols\DarkroomBooth.pdb` [O] | Thin MFC 8 (VC2005) shell. Contains booth-mode state machine, booth settings pages (35 dialogs), embedded HTML menus. Imports EventLib/EdgUtil/XPhotoLib/EventName [O] |
| Xphotolib.dll | "XPhotoLib" 9.20.943 [O] | Application framework of the larger "Darkroom Core/Pro" suite: setup tree, photo library, workshop/template editor, orders, slideshows, BoothControl web pages, licensing UI. 4173 exports (classes `CXPhotoApp`, `CSetupTreePage`, `CWorkshopPage`, `CLibraryPage`, `CSlideShowPage`, `CBorderWorkshopPage`, `CMP3Player`, `CTwain`…) [O] |
| Eventlib.dll | "EventLib" 9.20.943, 10.7 MB, 10799 exports [O] | Core engine: catalogs/events, layout/template model (`CEdgLayout`, `CEdgTextObject`, `CEdgImageObject`, `CEdgDoodleObject`, `CEdgSignatureObject`, `CEdgBarcodeObject`…), effects, chroma key, print queue, surveys (`CSurvey`, `CSurveyQuestion`, `CManageSurveysDialog`), slideshow generator, photo tasks (email, Dropbox, Facebook, digital media), live view, cameras, Phidgets, `CScriptHelper`, `CAutoUpdaterThread`, `DRAudioManager`, `CVideoPlayer` [O] |
| EdgUtil.dll | "EdgUtil" 9.20.943 [O] | Utilities: `CDbLite` (SQLite wrapper, 90 methods), `CEdgJsonObject`/`CEdgJsonString`, `CEdgXmlParser`, `CEdgReg`, `CZipFile`, `CBurnEngine` (disc burning), `CWebSocket`, `CXServer` (HTTP server helper), quantizers for GIF (`CWuQuantize`, `COctQuantize`) [O] |
| EdgExtCV.dll | "Edgextcv" 9.20.943; 3 ordinal exports; embeds OpenCV LBP cascade plus Haar frontal-face (Lienhart) and eye (Hameed) cascades as XML resources 100–102 [O] | Face detection (session auto-start, extra copies per face) [O for cascades; feature link I] |
| EventName.dll | 20 exports `ENGetCatalogName`, `ENGetNextImageName`, `ENGetImageNameFormat`, `ENGetSessionNumber`, `ENSetGlobalFileManagementType(EFileMgmt)`… [O] | Naming rules for event catalogs and image files |
| EdgQR.dll | 3 ordinal exports; build path `s:\Edg\Ver9.1\…\EdgQR.pdb` [O] | QR **encoder** (XPL credits fukuchi.org libqrencode and d-project.com) [I] |
| libzbar-0.dll | zbar 0.2.0 barcode reader [O] | QR **decoder** for touchless start. EVL imports `zbar_*` dynamically [O] |
| ExpressAccount.ocx | ActiveX: ExpressAccount, ExpressOrders, ExpressPrint controls [O manifest in EVL] | Order/print UI legacy (lab ordering) |
| ExpressBorder.ocx / ExpressPicture.ocx | ActiveX border (template) editor and picture control [O] | Template editor canvas and picture view |
| FolioCtrl.ocx / FolioViewer.ocx | ActiveX controls: FolioTree, FolioThumbs, FolioPreview, FolioCombo, FolioList, FolioData, FolioFolders, FolioView [O] | Event/catalog tree and thumbnail browser ("Create an Event", "Archive an Event", "Publish an Event" dialogs) |
| ExpressReports.dll | Exports `ERGenerateSummaryReportHtml`, `ERGenerateJobReportHtml`, … [O] | Sales/lab reports (Darkroom Pro). Not booth-specific |
| flpgrf.ocx (+flpgrf.lic) | ProWorks "Flipper Graph Control" 1.301 (1999) [O] | Charts. `CFlpGrf` class appears in EVL near slideshow/survey code. Used for survey result graphs (`\SurveyGraphs\`, `survey%02u.bmp`) [I] |
| drbooth2.dll | Internal name `javaShafer.dll`, ProductVersion 3.6, 137 ordinal-only exports; paths `…\Nalpeiron\Shafer\branches\Release_3.6.41\…libressl-3.0.2` [O] | **Nalpeiron** licensing client (renamed). Statically includes LibreSSL and libcurl (`curl.haxx.se` cookie string) [O] |
| filechck.dll | "Nalpeiron Support DLL" (NLS) [O] | Licensing service support |
| cshtsrv8/csmtpav8/csmapav8/csmsgav8.dll | Catalyst SocketTools 8.0: HTTP server, SMTP, IMAP, MIME message [O] | Local BoothControl web server; outgoing email; IMAP inbox harvesting for Auto Input |
| gifsicle.exe | 1.88 [O] | Animated GIF optimisation [I] |
| turbojpeg.dll, LEADTOOLS lt*11n.dll | JPEG/imaging codecs [O] | Image I/O |
| IDAutomationLinear6.dll | Barcode ActiveX [O] | Barcode objects in templates |
| phidget21x86.dll | Phidgets 2.1 [O] | Digital I/O for buttons, lights, bill/token acceptors |
| D27LibCom.dll / D27dll.dll / D27rsc.dll / DPPLibCom.dll / DPPDLL.dll / DPPRSC.dll | Canon "DPP Library Communicator" 1.2.1.2 and 3.15.0.900; Canon DPPDLL 3.7.3 (2009). The D27* files are renamed copies of the older DPP set [O] | Canon RAW (CR2) development via Digital Photo Professional libs [I]. No booth logic |
| BoothMode.exe | 69 KB launcher, no version info [O] | Runs `DarkroomBooth.exe -Booth` ("Unable to start DarkroomBooth.exe (Error=%u)") so the app opens straight into kiosk mode [O] |
| SlideshowGraphics/SlideshowBrowser.exe | "ExpressDigital Slideshow" 1.0.0.1 (2008), MFC42, `autorun.inf OPEN=SlideshowBrowser.exe` [O] | Autorun slideshow viewer placed on burned CDs/USB ("Digital Delivery → add a slideshow to the digital media") [I] |
| MobileCarriers/ | `Carriers.txt` + logos [O] | Email-to-MMS gateways for "Photo to Phone" without Twilio (§6) |
| Express.avi, Type00NN.md3, CP*.csv/lut, *.dat | Animation and printer/camera data | Out of scope (drivers) |

Lineage: Darkroom Booth is a **booth-mode front end on the Darkroom Software / Express Digital "Darkroom Core/Pro" event-photography platform (v9.20)**. The shared DLLs still hold the full lab/POS/order/PhotoReflect/Labtricity/QuickBooks/StudioPlus feature set: `XML_231..238` qbXML templates, `ExpressReports`, Labtricity dialogs, "Publish Event to PhotoReflect.com" [O]. A macOS rebuild can drop these.

---

## 2. Booth session flow (state machine)

Evidence: booth stage names in the EXE/EVL string pools, timing keys, debug strings `ChangeState | %s`, `OnTimer m_eState=%u`, `InitState (BoothState_AfterVideo)`, plus the Prompts/Timing/Controls dialogs [O].

```
Attract (slideshow / attract text / high-score screen)
  └─ start trigger: touch/click, space/Enter, Alt+key, mouse buttons, voice ("Begin;Start;Go"),
     face detected, QR code scanned, serial-port pin, Phidget input, BoothControl web cmd,
     on-screen button command; optional credits check (bill acceptor)
→ [optional] print-template choice at start (Print Alternate)          "Prompt user at start of session to choose print template"
→ [optional] Survey / Quiz (required or skippable, min score gate)      Start/Skip/Completed Survey|Quiz, Start Question, Question Time Warning, Correct/Wrong Answer
→ Get Ready text (GetReadyDelay)                                          Text\ReadyText "Get Ready!"
→ for photo 1..N:  Before Photo n → Countdown (5..1 / N, sounds) → Take Photo (shutter sound, liveview pause)
                    → After Photo n (NextPhotoDelay / LiveviewPause) ; retry on failure (MaxRetakes)
→ After Last Photo → End Instructions (EndTextDelay)
→ [optional] Review Photo / Retake / Booth Edit (doodle pens, stickers, photo note, signature, photo select)
→ [optional] GIF/boomerang/video preview ("Would you like to re-do your gif?")
→ [optional] Video session: Before Video → Video Countdown → recording (MaxVideoLength) → After Video
             "Would you like to do an extra video session?"
→ E-delivery prompt → email entry / phone entry (touch keypad) / Facebook confirm
→ Copies prompt (CopiesPromptDelay) → output (print, email, MMS, save, social) → Thank-you → Attract
```

Observed stage labels, which are also the "Booth Object Visibility" choices in screen templates [O, EVL/XPL]: `Attract Mode, During Startup, Before Photo 1..4/N, After Photo 1..4/N, After Last Photo, End Instructions, Before Video, During Video, After Video, Photo Session, Video Session, During Session, Enter/Exit Boothmode, Start Session, Countdown 1..5/N, Start/Skip/Completed Survey, Start/Skip/Completed Quiz, Start Question, Question Time Warning, Correct Answer, Wrong Answer, Placed First, Placed Top 3`. Stage lists are persisted as `boothstages.json`, `surveystages.json`, `quizstages.json` [O EXE].

Session types [O EXE]: `Start Photo Session`, `Start Video Session`, `Burst Session`. Booth can be set for `Videos Only` ("0 (Video Only)" photos-per-session option).

Timing keys (`TimeSettings\…`) [O EXE]: `AttractDelay, GetReadyDelay, NextPhotoDelay, LiveviewPause, LastPhotoDelay, EndTextDelay, FirstPhotoCountdown, BeforeVideoDelay, VideoCountdown, MaxVideoLength, AfterVideoDelay, EmailPromptDelay, EmailEntryDelay, CopiesPromptDelay, FacebookPostDelay, PreviewOutputDelay, ReviewPhoto\Delay`. Countdown modes: "No countdown / Countdown before first photo only / Countdown before each photo". Video start modes: "Start recording automatically after delay / Require manual click to start recording" [O].

Live view options (dialog "Liveview") [O]: use live view if the camera supports it; when to show ("After a session is started / Always on before and during session"); on capture ("Continue liveview without pause / Pause liveview to capture photo"); mirror yes/no; camera orientation (Horizontal, Vertical, Flipped variants); external flash compensation; choose video camera. "Shutter Time Adjustment" estimates camera lag from session data ("Average shutter delay: %u milliseconds") [O].

On-screen text fields (`Text\…`) with defaults [O EXE/EVL]: StartText, ReadyText ("Get Ready!"), EndText ("Thank you.  Please pick up your photos outside the booth."), VideoStartText, VideoEndText, VideoPromptText, EmailPromptText ("Would you like the photo sent to you?"), EmailEntryText, PhoneEntryText, CopiesPromptText ("How many copies would you like?"), Attract text, Maintenance text ("Booth Maintenance required. Please alert the booth operator."), signature text ("Sign your photo by drawing your signature"), ReviewPhoto text ("Here's your photo!"), PhotoNote text ("Add a note to your photo.").

---

## 3. Feature inventory

### 3.1 Events and the photo library
- **Events = catalogs** with sub-catalogs `Photos` and `Prints` [O EXE: "Booth events must have subcatalogs for Photos and Prints.", `Photos,Prints`, `photos.dat`, `prints.dat`]. The index file is `\Events\…\events.idx` [O]. The default name is `Booth Event %Y-%m-%d` [O].
- Event menu [O EXE MENU 4092 / HTML EVENTMENU_HTM]: Create New Event, Duplicate Event, Edit Event Info, Lock Event (password `BoothPassword`, "Enter password to unlock event."), Remove Event, Publish/UnPublish, Show/Hide Events.
- Event Properties dialog [O EXE DLG 219]: Name, Description, Notes, Date, Default Email domain for the guest keyboard (e.g. "@corporationname.com"). Template variables `%Event%, %Event-Date%, %EventDesc%, %EventNote%`.
- Photo browser menus: sort and view by rating (1–5 stars F1–F5), time, filename, film number; archive/unarchive to CD; "Manage Files By Day/Week/Month" (`EFileMgmt`) [O EXE MENU 563/564/573/584/586].
- Prints view: Reprint, Remove Print, Show Print Queue (F11) [O MENU 33950].
- **Output Queue** and **Event Info** pages in the HTML nav menu (`NAVMENU_HTM`): Start Booth Mode, Event Settings, Global Settings, Output Queue, Device Control [O].

### 3.2 Event settings ("Booth Options" property sheet) [O EXE MENU 242, DLG 596–619]
Pages: **Main/Photos, Screens, Output, Prompts, Text, Timing, Controls, Camera, Liveview, Video, Slideshow, Device Control, Wrap Up**, plus Music and Sounds, Print Alternate, Special Winner.
- *Photos/Output*: photos per session, camera orientation, output template (None/Auto/Custom). Output targets (checkboxes): Print Photo, Print Alternate, Special Winner, Photo Email 1, Photo Email 2, Photo to Phone, Save Output 1/2, Copy Originals 1/2, Post to Dropbox, Facebook (page) Post, Facebook User Post, Post to Twitter/Instagram/Snapchat, Post to Event Gallery, "Use Remove.bg ($)" [O DLG 596].
- Persisted keys (path style) [O EXE]: `NumPhotos, CameraOrientation, TemplateType, TemplateFile, PrintId, PrintCopies, CopiesPrompt, FirstReadyScreen, GlobalEffect, EnableAllSounds, EDeliveryPrompt, Output\{CopyOriginal,CopyOriginal2,File1,File2}\{Folder,Template,FilenameFormat,Watermark,Size,FileType|FormatType,FileQuality,AnimationSettings}, Output\Email{1,2}\{Account,Subject,Message,HtmlMessage,Size,Recipient,CC,Watermark,Template,AnimationSettings}, Output\{FacebookParams,DropboxParams,PhoneParams}, Output\{UserFacebook,TwitterPost,InstagramPost,SnapchatPost}\{Enabled,Params,ByEmail}, Output\HulaGallery\{Enabled,Params}, Output\Removebg\Enabled, Controls\…, Survey\{Filename,Enabled,ColorScheme,Required,FromTemplate}, Wrapup\…, Signature\{Text,Enabled}, PhotoSelect\Enabled, ReviewPhoto\{Enabled,Text,Delay,Doodle\Enabled,Doodle\PenSettings,PostProcess\Enabled}, PhotoNote\{Enabled,Text}, PreviewGif\{Enabled,Text}, SpecialWinner\{Enabled,Settings}, Credits\{RequireStartup,StartupMin,RequireCopy,CopyMin}, Video\…, Burst\…, Slideshow\…, BoothPin, UseBoothPin, SettingsVersion`.
- Event settings can be **saved into and loaded from a screen template** ("All of the settings for this event will be saved into the current Screen Template. This makes it easier to share templates and re-use settings.") [O EXE].
- Storage: path-style keys mapped onto nested JSON, as in the default slideshow JSON `{ "Group1": { "Strips": { "Enabled": true } },"Where" : {…} }` built with `CEdgJsonObject` [O for slideshow JSON]. Which container holds the event booth settings (catalog serialization `CEdgProperties`/`CEventData::Serialize` vs a JSON file) is **[I] unresolved**.

### 3.3 Templates, layouts and the template editor
- **Two template roles**: *Screen templates* (`BoothScreens`; on-screen UI per stage) and *print/output templates* (`BoothTemplates`) [O EXE]. Screen template properties: descriptive name, filename, template size (match display resolution, custom W×H), crop setting "Fit - Reduce template to fit within screen / Crop - Stretch template to fill screen", background/text colour and opacity, "Extend to multiple displays" [O DLG 205].
- **File format `.xbdr`** (Express Border) and legacy `.crd`/`.cdr` ("Template Files|*.crd;*.xbdr|", "…extension .xbdr or .cdr") [O EVL]. Container tokens: `XBDR` magic, `BEGIN_HEADER`, `VERSION:`, `CARDTYPE:`, `DESCRIPTION:`, `BINARY`, `*DATA*`, `ROUNDCORNERS:`, `ROTATEBACK180:`; XML object fragments `<XBDR>`, `<ImageObject>`, `<TextObject>` with `<Text>`, `<FontName>`, `<FontSize>`, `<TextColor>`, `<TextOpacity>`, `<Width>`, `<Height>`, `<Flags>FIT | CENTER</Flags>`, `<Editable>` [O EVL/EXE]. Templates embed fonts (`XbdrWarnFonts`: "font(s) have restricted licenses and could not be embedded"), sound files (`ExtractSoundFiles`) and min app version (`XbdrMinApp`). DRM for purchased templates: `XbdrDrm`, `GetEulaFile`, `GetLicenseeName/Company`, `GetXbdrDisableEdit`, `GetXbdrGuid` [O CEdgLayout exports]. Byte-level layout not decoded **[I: hybrid text header + binary/XML body]**.
- Example templates referenced: `Red Curtains III.xbdr`; sample photos `SamplePhotos` [O].
- **Template object types** (Add menu) [O MENU 4094]: Photo, Photos, Text, Artwork, Shape, Effect, **Liveview** placeholder, Line, Barcode, Signature, Input, Output. Further object classes [O EVL]: `CEdgArchedTextObject`, `CEdgCalendarObject`, `CEdgDoodleObject`, `CEdgMagneticStripeObject`, `CEdgPlaceHolderObject`, `CEdgProofObject`, `CEdgEffectObject`, `CEdgLayer`. Video objects (`EnumerateVideoObjects`) and **graphic lists** (cycling backgrounds/props: `GetGraphicListImage`, "Prev/Next Graphic", `GraphicListPositions`) [O].
- Editor features: align/distribute, z-order, rotate (90/180/angle), snap to grid, auto alignment, size (fill page/width/height, fit), duplicate/cut/copy/paste [O MENU 842–847, 33013]. **Visibility conditions** per object using expressions like `'%name%'='John' AND %id%<20` [O EVL DLG 1353], plus per-booth-stage visibility [O DLG 1422].
- Shapes (28) and masks (`*OVAL *CIRC *VIGN *RRECT *STAR *HEART *STAMP *SCRIBBLE *FRAMEXL`… plus gradients `*GRADL…`) [O EVL XML_1389].
- **Template variables** (`%Var%`, the "Insert Vars" menus) [O EVL XML_1389]. Date/Time (Date, ShortDate, LongDate, DayOfWeek, Time, Time24…), File/Path, Catalog/Event (EventName, EventDate, EventCity…), Customer, Order, Photo metadata (`Photo.ISO Rating`, `Photo.Model`…), `PhotoNote`. Screen vars: `Text, Countdown, Start Text, Ready Text, End Text, Video Start Text, Video End Text, Video Timer, Video Remaining`. Lookup vars: `*Photo`, `*Graphic=Background|Logo`. Additional booth vars: `%PageNum%`, `%EventName%`, `*Photo%i`, `*LIVEVIEW`, `*FirstImage` [O EXE]. `CScriptHelper` (`GetTemplateDefinition`, `HasHtml`, `HasJavaScript`, `Finalize`) and `EdgReplaceVars(…, CEdgVarInfo&)` perform the substitution; scripts use `REPLACEVAR("…")` [O EVL].
- Print sizes menu [O MENU 210]: 2x6, 4x6, 5x7, 6x8, 2x7, 2x8, 3.5x5, 4x4, 4x5, 4x8, 4x10, 4x12, 4x16, 4x18, 5x5, 5x8, 5x10…; "Round" variants (`Round2x6`, `Round4x10`…). "Half sheets will be rounded up to an even number of copies" (2x6 strips on 4x6) [O].
- Template marketplace: "View and purchase templates from darkroomtemplates.com", purchased-template download (`CPhotoTaskBorderDownload`) [O].

### 3.4 Image effects, filters and green screen
- Colour modes, togglable at runtime: Color, Black&White/Grayscale, Sepia, Retro, Antique (hotkeys Ctrl+B/C/S, `DefaultColorEffect`, `KeepLastEffect`) [O EXE, XPL controls page].
- Effect classes [O EVL]: BlackAndWhite, COIBlackAndWhite, Sepia (`CCepiaToneEffect`), Antique, DuoTone, DuoToneVeil, Monochrome, Posterize, Blur, Darken, Hue, Saturation, Gamma, InvertRGB/NegateRGB, Overlay, **Watermark**; retouch tools (blemish, clone, heal, red-eye `CRedEyeRemoval`, dodge/burn…); auto levels, sharpness, tilt.
- **Custom filters**: `.json` files in a `Filters` folder, booth command `applyfilter` ("Apply a custom color filter to the image.", "Levels") [O EVL].
- **Chroma key / green screen**: `CChromaKeyInfo(2,3)`, `CChromaKeyCacheInfo`, `CChromaMaskDropoutTool/KeepTool`, `HitTest_ChromaMask`, mask type "Chroma-key (Green-screen or Blue-screen background)", tokens `DROPOUTCOLOR:`, `DROPOUTALPHA:`, `OUTLINEDROPOUT`, `ChromaHueStdDev`, "Set Chroma Key Options… K" [O EVL/XPL]. Dropout is configured per template image cell, and backgrounds come from graphic lists [I].
- **Remove.bg** cloud background removal as an alternative to green screen. Each photo is POSTed to `https://api.remove.bg/v1.0/removebg` (`image_file`, `format`), and the account is checked at `/v1.0/account`. Results are used only if the template cell has chroma dropout [O EXE/EVL].
- **Snap Camera lenses** (Snapchat's desktop virtual webcam) [O EVL]. Booth commands `snaplens`, `snaplenscycle`, `snaplenstoggle`, `snaplensoff` read `Snap\Snap Camera\settings.json`.

### 3.5 Animated GIF, boomerang, burst and video
- **Burst session** ("video is captured but only a subset of frames are extracted and used") [O DLG 238]. Settings: capture rate, playback delay, max W/H, recording time, Boomerang, output `.mp4 (default)` or `.gif`, template, soundtrack, loop audio, preview after recording. Keys `Burst\{Loop,Boomerang,Convert,GifDelay,FrameRate,MaxWidth,MaxHeight,MaxRecordTime,Template,Soundtrack}` [O EXE].
- **Animation of photo sessions** (GIF/MP4 from stills) [O EVL DLG 1445]: delay between frames. Template modes: "Default: use one photo and one template per frame", "Repeat: use all templates for each photo", "Distribute: divide templates evenly among photos". Enable Boomerang. `Anim:Enabled`, `Anim:Boomerang`, `Anim:Preview` [O EXE].
- **Video session** [O DLG 238]: video size, template overlay ("i5 or faster processor is recommended"), audio (none/keep original/external soundtrack/template soundtrack), **video scripts** (speed ramps: `Normal Slow Normal`, `Normal RevSlow Normal`, `Normal Slow Normal 3rds`, `Slow Reverse Slow`, "-- no script --"), intro/outro video or template with time limits, preview after recording, "Allow videos to be sent by email, text, and social-media". Files `%sVid_%04u.mov`, `_alt.mp4`, `_T.mp4`. "Video files are not saved in Trial Mode" [O EXE].
- Encoding uses **ffmpeg.exe** via the command line (` -hide_banner -loglevel quiet -nostats`, `-pix_fmt yuv420p`, `-b:v %ik`, `scale=%i:-1`, `setpts=%5.3f*PTS`, fallback path `C:\ffmpeg\ffmpeg.exe`) [O EVL]. ffmpeg.exe is **not** in the install folder, so it is downloaded or installed separately [I]. `gifsicle.exe` is shipped [O].
- Attract/standby video playback ("Video Playback" dialog: multiple files, loop, letterbox, fullscreen, skippable, playback monitor) [O EVL DLG 1442].

### 3.6 Review, retake and guest editing
- Review Photo with delay, Retake Photo/Video (`RETAKING PHOTO: %i`, `MaxRetakes`), **Photo Select** (choose the favourite photo when the session has ≥2 photos and a 1-photo template), **Photo Doodle** (5 pen colours, "Pen Settings"), sticker mode (`STICKERMODE_PNG`, `PENMODE_PNG` icons, "Enable Booth Edit"), **Photo Signature** (`CEdgSignatureObject`), **Photo Note** (`%PhotoNote%`), GIF preview with re-do [O EXE DLG 597, strings].

### 3.7 Surveys, quizzes and data capture
- Survey/Quiz editor ("Survey Wizard", "Manage Surveys", "Survey Settings", "Quiz Options") [O EVL DLG 1426–1446]. Question types [O]: **Yes / No, True / False, Multiple Choice, Checkboxes**, free text (max length, numeric-only), range (From/To label), date (M/D/Y, M/Y, Y, min/max year), graphic list choices (`GFXLIST`), per-question time limit, answer required.
- Survey file = **XML** (`Survey Files |*.xml|`) [O]: `<SURVEY ShowStart="N" ShowEnd="N" ShowTimeout="N" DarkScheme="0" SurveyRequired="1">` or `<QUIZ …>`, `<QUESTION Type="%s" Guid="%s" …>`, `<TEXT>`, `<HELP>`, `<CHOICE>`, `<ANSWER>`, `<TXTFIELD>`, `<GFXLIST>`, `<TIME>` (default template in EVL XML_1448). The survey can also be auto-generated from the print template's text fields ("Automatically generate survey from print template.") [O].
- Quiz [O]: right answers out of 1–10, minimum score/rank to start the session, tie-break rule (first vs latest), guest initials, **leaderboard/high score in attract mode** (" Score: %i/%i   Rank: #%i out of %i", `Leaderboard...`), print a "champion" photo template.
- Results go to SQLite `Survey.db` (§5). Wrap-up exports CSV and PDF graphs (`%s_%s.pdf`, "Individual Responses", "Response Percents"). Results are also served live at `/survey/results[/1|2|4]` [O].
- Guest contact capture: email (domain validation and quick-domain buttons @gmail.com, @yahoo.com…; "International phone numbers are not allowed.") and phone. Stored in `SessionData.Email/Phone` and `Email.csv` (`#Email,Date,Time,NumPhotos,Photo1,…,Phone`) [O EXE].

### 3.8 Printing (application-level)
- Copies: fixed or prompted (2–10 / Unlimited max, min/max copies). **Face-detection extra copies** ("print copies for each person", `MaxExtraFaceCopies`). Reprint last (Ctrl+R; Alt+R asks for copies), kiosk reprints, print partial session, print blank photos, test mode Ctrl+T (no output) [O EXE].
- **Print Alternate**: a second template/size, chosen by the guest at start or end of the session or printed every session. BoothControl can set the default to Primary/Alternate 1/Alternate 2 [O DLG 3093, controls page].
- **Special Winner** (prize draw): manual (via BoothControl "Force Special Winner") or random "1 in N", max wins per hour/day, special template, sound effect, text, "Print both default and special" [O DLG 3094].
- Printer readiness checks for each needed print size before Booth Mode starts [O EXE].

### 3.9 Sharing and delivery
| Channel | Mechanism | Evidence |
|---|---|---|
| Email (2 profiles) | SMTP via SocketTools. Provider presets in EVL XML_1385 (Gmail, iCloud, Yahoo, Outlook/Hotmail, Comcast, Cox, **Smtp2Go** port 2525, Verizon…). Recommended relays SendGrid and SMTP2GO. HTML message templates | [O] |
| Photo to Phone (MMS) | (a) **email-to-MMS gateway** using `MobileCarriers\Carriers.txt` (e.g. `T-Mobile, @tmomail.net`, `Verizon Wireless, @vzwpix.com`; guest picks carrier: "You must select a service provider…"); (b) **Twilio** REST `https://api.twilio.com/2010-04-01/Accounts/{SID}/Messages.json` with `MediaUrl`, which needs public image hosting via **Dropbox** shared links or **Darkroom temp storage** `https://4q3c0yszlg.execute-api.us-east-2.amazonaws.com/prod/tempupload?file=` (`ForceDropboxStorage`, `AllowInternationalPhoneNumbers`) | [O] |
| Facebook page post | Graph API v5.0 OAuth (`dialog/oauth … scope=user_photos,user_events,user_posts,manage_pages,publish_pages`), redirect `https://www.darkroomsoftware.com/connect/login_success.html`, album/page choice | [O EVL] |
| Facebook User Post | Guest logs in on the booth to post to their own timeline, or receives a link by email/phone (`UserFacebook\ByEmail`). "login information is not retained" | [O EXE STR 626] |
| Twitter / Instagram / Snapchat | **No direct API posting.** The image is sent by email/phone with an instruction link (`darkroomsoftware.com/3rd/{twitter,instagram,snapchat}.html`, bit.ly) | [O] |
| Dropbox | OAuth2 implicit (`dropbox.com/oauth2/authorize`, redirect `darkroomsoftware.com/utl/dropbox_redirect.htm`). API v2 `files/upload`, `sharing/create_shared_link`, `files/get_temporary_link`, `list_folder`… Optional email with link | [O EVL] |
| Event Gallery (internal name "HulaGallery") | `https://api.eventgallery.com/api/v1/picture/upload?collection-name=…&collection-date=…&token=…`, token check `/api/v1/token/status`, API key pasted from app.eventgallery.com | [O EVL] |
| Save Output 1/2, Copy Originals 1/2 | Local folders with filename format, size, type, quality, watermark, template, animation | [O] |
| Digital media / disc | Burn CD/DVD/BD or copy to folder (`CBurnEngine`, `CPhotoTaskBurnDisk`, "Digital Delivery": volume label, preview/medium/full/custom size, watermark, slideshow plus music on disc, extra files) | [O] |
| QR code | `https://www.darkroomsoftware.com/utl/qrBuild.htm?d=` builds a printable sign. Local `/utl/qrBuild.htm` for BoothControl links | [O] |

### 3.10 Touchless start (QR) and other triggers
- **BoothStart.com**: guests visit `http://www.boothstart.com` on their phone, enter email/phone and get a QR code. The booth scans it with live view or an alternate webcam (zbar) and starts a session with contact details prefilled ("Allow touchless start if QR Code is detected", "Print Sign…") [O EXE DLG 243]. The QR payload format is not observed [I].
- Triggers [O DLG 601]: keyboard (space/Enter; Alt+key; ESC exits), mouse left/middle/right actions, hit-area corner to exit (`click Top-Left Corner to exit`…), hide cursor, **face detection** auto-start (OpenCV), **voice** (SAPI, "Start Session"/"Take Picture" phrases, defaults "Begin;Start;Go" and "Cheese"; Windows 7+), **serial port** CD/CTS/DSR/RING pins (`COM1:,9600,8,N,1`), Windows-key action, Phidget digital inputs, BoothControl web commands.
- **Credits / coin-op**: "Require minimum credits to start session", "Require credits to print extra copies". Credits come from a bill changer/token device on a Phidget input (`addcredit`, `clearcredits`, `UPDATECREDIT`) [O].

### 3.11 Booth commands (on-screen buttons, inputs, remote) [O EVL]
`startsession, startvideo/videosession, burstsession, cancelsession, reprintlast, printcopies, choosealternateprint, chooseprimaryprint, choosegraphic, prevgraphic, nextgraphic, applyfilter, snaplens*, addcredit, clearcredits`, colour toggles (`antique, sepia, retro, grayscale`), "Start photo session after applying command", "Enable extra video session". Device Control actions: `Sound, Stop Sound, Video, Booth Command, Script` (AutoHotKey `.ahk` / `.exe` via "Run Executable"), `Pause`, Phidget output `Toggle/Blink Slow/Blink Fast` with durations (for lights/relays) [O EVL DLG 1437/1441]. Device inputs map to these actions (`inputs.json`, `DeviceSettings`) [O EXE].

### 3.12 BoothControl (LAN web server) and kiosk
- Built-in HTTP server (SocketTools HTTP Server library, default port 80; "Enable Booth Control", IP address list) [O XPL DLG 3295]. Pages are in XPL `WEBPRIVATE`/`WEBRES` resources and are PWA-ready (manifest.json, icons).
- Public: `/slideshow`, `/kiosk` (guest album: browse, email, MMS, reprint; "Allow Reprint / Allow Email / Allow Send-to-Phone (MMS)"), `/survey/results`, `/sharemode` (photo-sharing gallery) [O WEBPRIVATE_LINKS.HTM].
- Private: `/menu`, `/controls` (Start, Take Photo, Cancel, Retake, Force Special Winner, Color/Sepia/B&W/Antique, default print template, Reprint Last, Prev/Next Graphic, Start Video/Record/Stop, Booth Lock/Unlock, Maintenance Lock/Unlock, Custom Lock/Unlock, Exit Booth Mode, Restart/Shutdown Computer), `/controls/custom`, `/photocontrol` (live view on the phone via `/live/image.jpg` + `/live/image.json`), `/manage_album`, `/stats`, `/links/private`. Commands are sent as GET `/control/cmd/…` (`jsUtils.js`) [O].
- Locks show out-of-service screens (`OOS_TEMP.PNG`, `OOS_TIME.PNG`, `MAINTENANCE_PNG`, `slideshow\oos.png`) [O EXE].
- Stats reports by email/MMS to a user list (start of day, during wrap-up, on printer/booth errors) [O XPL DLG 3296/3297, `PHONESTATS.TXT`].

### 3.13 Slideshow / attract mode
- Generated HTML5 slideshow (EVL `SLIDESHOW_HTML/JS`, `ALBUM_HTM/JS`, `SLIDESHOWMENU_HTM`, `TRANSAMPLER_HTM`). It is written to `\slideshow\slideshow.htm` with `filelist.js` and `~slideshow.json` and shown in an embedded IE WebBrowser (IE11 emulation via `FEATURE_BROWSER_EMULATION`; "The current version of Internet Explorer is not supported") [O EXE].
- Options [O EXE STR 581–607]: Off/Basic/Custom, attract mode between sessions, secondary monitor, background music, show output and/or originals, mix in survey/quiz results, social-media images and folders 1/2 (insert every N frames), recent-N only, max W/H, time per slide, transitions (Dissolve, Slide L/R/U/D, Flip L/R/U/D; Fast/Medium/Slow), multi-slide grids (1×2 … 3×3), **3 channels** and composite layouts (e.g. `Channels: Large 1,2,3`), background colour/image (tile/stretch/fit), drop shadow, gap, text size, navigation controls, "Generate slideshow to disk only". Settings are JSON (`Slideshow Settings |*.json`).

### 3.14 Auto Input (social/hashtag printing)
- An `AutoInputs` table harvests external images into the event and runs outputs such as print, with tag and timestamp filters [O EVL]. Providers: **Folder, Dropbox, Twitter, Twilio (inbound MMS: `/Messages.json?DateSent>=`, `/Media.json`), Instagram (`ig_hashtag_search`), Facebook (events/pages/albums), "Outspoken", email inboxes via IMAP (Gmail, Yahoo, Outlook, Apple)** [O]. Twilio auto-replies to SMS and voice calls via `twimlets.com/echo?Twiml=` ("Thanks for calling.  Please send your photo to this number.") [O].

### 3.15 Wrap-up and reporting
- Wrap Up page [O EXE DLG 619]: Copy Original Images, Copy Output Images, Generate Survey Results, **Generate Photo Book PDF** (`%PageNum%`, `%EventName%`, `CEdgPdf`), Generate Event Stats, Generate Email/Phone List (.csv/.txt), global save path or CD/DVD burn.
- Event Stats (from `SessionData`) [O EXE]: sessions by type, avg session time, idle time, photos taken/retaken, videos started/watched/retaken, total/avg record time, bursts, colour choice, print choices (primary/alternate), prints made/remaining, kiosk/other reprints, electronic deliveries, special winners, surveys completed. Sent as HTML email or MMS ("Booth Stats %Y-%m-%d %H:%M").

### 3.16 Kiosk mode, operator protection and system
- Booth Mode is full-screen kiosk. Exit via ESC/hotspot with optional **Operator PIN** (`BoothPin`, "Enter PIN code to exit:", "Require Operator PIN Code to exit Booth Mode") [O]. `BoothMode.exe` launches straight into booth mode [O].
- Prevents sleep (`SetThreadExecutionState`), can restart/shutdown Windows (`SeShutdownPrivilege`, `ExitWindowsEx`), `AutoShutdown` option, "Bad Exits" detection [O EXE].
- Second monitor preview (`EnablePreviewMonitor`), multi-display screen templates, SurfacePro3/4 presets [O].
- Audio: background music, text-stage audio, countdown sound folder (`1.wav, 2.wav, 3.wav…`), shutter, before-photo 1–4 audio, video start/end audio (`DRAudioManager`, `CMP3Player`). Sounds can be embedded in screen templates [O EXE STR 534, 540].
- Auto-update check `http://www.darkroomsoftware.com/drb/drbupdatev3.htm` (`CAutoUpdaterThread`) [O]. Help: boothmanual.com [O].

### 3.17 Licensing, activation and dongles
- **Nalpeiron (NLS)** online licensing [O]: license code format `123456-123456-123456`; 4-step activation wizard collecting name/email/phone/company/address; license password; trial mode ("digital watermarks will be added", "Darkroom Booth Unlicensed Demo", `TRIAL MODE`); upgrade codes need the previous-version code; maintenance end date checked against build date ("expired maintenance end date… renew the maintenance plan"); deactivate/return license (`/DEACTIVATE`, `/FORCEDEACTIVATE` switches); clock-tamper warning; refuses to run under **Remote Desktop and virtual machines** ("purchase a USB dongle… if you must run on a Mac computer"); Nalpeiron service install/update (`NalpeironServiceInstaller.exe`, `updatemyservice.com/NalpeironServiceUpdate2013.zip`); phone-based temporary activation (Machine Key → Activation Key, (800) 517-4522). License tiers seen: "licensed for Darkroom Booth version 1.x / 2.x" [O XPL/EVL].
- **Hardware dongle**: Rainbow/SafeNet **Sentinel SuperPro** ("Please check that the Rainbow Sentinel drivers are installed", `Common Files\SafeNet Sentinel\…`, "Dongle Serial Number", feature gating "Your dongle does not grant access to the Preview/Capture feature", "The dongle was upgraded successfully") [O].
- OEM restriction: "This OEM version does not support borders with green screen, high-key, or low-key effects." [O EVL STR 14007].

---

## 4. File formats and on-disk artefacts

| Artefact | Format | Evidence |
|---|---|---|
| `*.xbdr` (also `.crd/.cdr`) | Template/border, header + objects + embedded assets | §3.3 [O tokens; I structure] |
| Survey/quiz `*.xml` | `<SURVEY>/<QUIZ>/<QUESTION>` XML | §3.7 [O] |
| `Survey.db`, session DB | SQLite (`CDbLite`; `sqlite3.dll` names, `:memory:`) | §5 [O] |
| `boothstages.json`, `surveystages.json`, `quizstages.json`, `inputs.json`, `~slideshow.json`, `Packages\SendStats.json`, Filters `*.json` | JSON (`CEdgJsonObject`) | [O names; I contents] |
| `events.idx`, `photos.dat`, `prints.dat`, `ColorData.cat`, `Film.lst`, `*.edp`, `*.ord`, `pkg_0000.edf` (`OutputEdf` column) | Proprietary catalog/order/output descriptors (MFC serialization likely) | [O names; I format] |
| `Camera Settings\$LastCam.ini` (`[Settings]`) | INI per camera model | [O] |
| `Email.csv` / `Email.txt` | CSV of guest contacts | [O] |
| `MobileCarriers\Carriers.txt` | CSV `Name, @gateway, logo` | [O] |
| `\slideshow\` (`slideshow.htm`, `filelist.js`), `\photos\`, `\videos\`, `\survey\`, `\SurveyGraphs\`, `BoothControl\`, `\Darkroom Software\MMS` | Working folders | [O] |
| `BoothScreenShot.jpg`, `img%05i.jpg`, `img_%04i.jpg`, `%sVid_%04u.mov`, `%s%s.gif` (`%Y%m%d%H%M%S`) | Session media naming | [O] |
| Registry `HKCU\Software\Darkroom Software\Options` (`Language`, `AutoShutdown`, `LastEvent`, `LastEventFilename`, `EnablePreviewMonitor`, `UserDefaults`, `Disable*`…) and `$InstDat.txt`, `LocalID\` | Global app settings | [O; hive I] |

---

## 5. Database schemas (SQLite, verbatim) [O]

```sql
-- per-event booth session log (EXE)
CREATE TABLE IF NOT EXISTS SessionData (Incident NOT NULL DEFAULT 0, StartTime NOT NULL DEFAULT 0, Duration, Idle,
  ColorChoice, EmailStatus, TextMessageStatus, SurveyStatus, SpecialWinner, SessionResult, FacebookPost,
  FacebookUserPostStatus, PrintChoice, PhotosTaken, PhotoRetakes, ExtraVideos, VideoRetakes, VideosWatched,
  VideosWatchedToCompletion, VideoLengthRecorded, StageReached, PrimaryPrintId, PrimaryPrintCopies, AltPrintId,
  AltPrintCopies, ReprintCopies, KioskReprints, Email TEXT, Phone TEXT, OutputEdf TEXT, SessionPhotos, BurstRetakes);
CREATE INDEX IF NOT EXISTS SessionTime ON SessionData (StartTime);
CREATE TABLE IF NOT EXISTS dbProps (Tag TEXT, Value TEXT);
-- migrations: ALTER TABLE SessionData ADD COLUMN BurstRetakes / SpecialWinner

-- surveys (EVL, Survey.db)
CREATE TABLE IF NOT EXISTS SurveyResults (TimeStamp DATETIME DEFAULT CURRENT_TIMESTAMP, OutputFile TEXT, File1 TEXT,
  Email TEXT, PhoneNumber TEXT, Score UNSIGNED TINYINT, Initials TEXT);
  -- plus dynamic columns: Q<n> TEXT per question, "Q<n>_<choice>" INTEGER per checkbox choice
CREATE TABLE IF NOT EXISTS SurveyQuestions (QuestionID, QuestionNum INTEGER PRIMARY KEY ASC AUTOINCREMENT);

-- social/auto-input harvesting (EVL)
CREATE TABLE IF NOT EXISTS AutoInputs (AutoInputType INTEGER, Name TEXT, AccountName TEXT, Source TEXT, Tags TEXT,
  Sender TEXT, Recipient TEXT, SortOrder INTEGER, SearchDays INTEGER, ArchiveFolder TEXT, ArchiveKeepDays INTEGER,
  ArchiveKeepSize INTEGER, Flags INTEGER, Orientation INTEGER, NamedAttrib TEXT, Package BLOB, UpdateTime);
CREATE TABLE IF NOT EXISTS Downloads (id TEXT, UpdateTime);   -- de-dup of harvested items
```
`Incident` encodes session type (photo/video/burst/idle); stats query `WHERE Incident IN (%i,%i)` [O]. Enum values are not recovered [I]. Hard-coded print-size IDs in stats queries: `PrimaryPrintId IS 460`, `IN (1150,1151)`, `IN (1152,1149)` (likely 4x6 vs 2x6 strip groupings) [O ids; I meaning].
The suite also has ODBC/SQL Server style lab tables (`LabProduct`, `LabService`, `tblInvoices`…), which are not booth-relevant [O].

---

## 6. External web services and endpoints [O unless noted]

| Service | Endpoints / notes |
|---|---|
| Darkroom Software | `darkroomsoftware.com/drb/drbupdatev3.htm` (updates), `/utl/qrBuild.htm?d=` (QR sign), `/utl/dropbox_redirect.htm`, `/connect/login_success.html` (FB OAuth), `/twilio_redirect`, `/igredirect`, `/3rd/{twitter,instagram,snapchat}.html`, `/products`; darkroomtemplates.com; boothmanual.com; **boothstart.com** |
| Darkroom temp storage | `https://4q3c0yszlg.execute-api.us-east-2.amazonaws.com/prod/tempupload?file=…&app=%s&ver=%u.%05u&id=%s` (AWS API Gateway, MMS media hosting) |
| Nalpeiron licensing | via drbooth2.dll/filechck.dll. Service updater `updatemyservice.com` |
| Twilio | `api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json`, `/IncomingPhoneNumbers.json`, `/Media.json`; `twimlets.com/echo` |
| Dropbox | `api.dropboxapi.com/2/*`, OAuth2 implicit; legacy `api.dropbox.com/1/disable_account_token` |
| Facebook / Instagram | `graph.facebook.com/v5.0/me`, `/me/accounts`, `/me/events`, `/me/permissions`, `5.0/ig_hashtag_search`; `api.instagram.com/v1/users/self` (legacy); OAuth dialog v5.0 |
| Event Gallery | `api.eventgallery.com/api/v1/picture/upload`, `/api/v1/token/status`; app.eventgallery.com |
| remove.bg | `api.remove.bg/v1.0/removebg`, `/v1.0/account` |
| SMTP/IMAP | user-configured; presets (Gmail, Yahoo, iCloud, Outlook, Smtp2Go, SendGrid) |
| Legacy suite (not booth) | PhotoReflect.com publishing, Labtricity/ExpressDigital elab, `%s/dr3/login.aspx` reports, QuickBooks qbXML |

---

## 7. Notes for the macOS rebuild

- Core model to replicate: **Event** (name/date/desc/notes/default email domain, lock password) → settings tree (keys above) → **Session** rows (`SessionData`) → media (originals, outputs, GIF/MP4) → deliveries. Templates are layered layouts with stage-visibility, graphic lists, live-view placeholder, chroma cells, `%vars%`, embedded fonts and sounds.
- Legacy pieces you probably should not port, and what to use instead: IE-hosted HTML UI (use WKWebView), SocketTools (use URLSession and a small HTTP server such as SwiftNIO), LEADTOOLS (use ImageIO/Core Image), SAPI (use the Speech framework), OpenCV face detection (use Vision), zbar (use the Vision barcode detector), ffmpeg/gifsicle (use AVFoundation and ImageIO for GIFs), Nalpeiron/Sentinel (your own licensing).
- Integrations that no longer work or never posted directly: Facebook Graph v5.0 `manage_pages/publish_pages` scopes are deprecated, the Instagram v1 API is shut down, Snap Camera was discontinued in 2023, and Twitter/Instagram/Snapchat sharing was only ever "send link to the guest's phone".
- `.xbdr` byte layout, the `.edf/.edp/.dat` serialization, the boothstages/inputs JSON schemas and the `Incident`/`PrintChoice`/`ColorChoice` enum values still need dynamic or sample-file analysis. No sample templates or event data are in the install folder.
