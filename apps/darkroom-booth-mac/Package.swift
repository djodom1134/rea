// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DarkroomBoothMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DarkroomBooth", targets: ["DarkroomBooth"]),
        .library(name: "BoothCore", targets: ["BoothCore"]),
    ],
    targets: [
        // Platform-neutral booth semantics: settings, session state machine,
        // template variables, print sizes, session log. Foundation only.
        .target(name: "BoothCore"),
        // Hardware contracts and the device catalog recovered from Eventlib.dll.
        .target(
            name: "BoothHardware",
            dependencies: ["BoothCore"],
            resources: [
                .copy("Resources/camera-usb-models.tsv"),
                .copy("Resources/printer-usb-models.tsv"),
            ]
        ),
        // Camera backends: AVFoundation (webcam/UVC/HDMI capture), hot folder,
        // libgphoto2 (Canon/Nikon/Sony tethering, loaded at runtime).
        .target(name: "BoothCameras", dependencies: ["BoothCore", "BoothHardware"]),
        // Printing through CUPS (dye-sub drivers: Gutenprint or vendor drivers).
        .target(name: "BoothPrinting", dependencies: ["BoothCore", "BoothHardware"]),
        // Core Image composition, colour effects, chroma key, GIF export.
        .target(name: "BoothImaging", dependencies: ["BoothCore"]),
        // Trigger inputs: keyboard, RS-232 modem-status buttons, Phidgets.
        .target(name: "BoothIO", dependencies: ["BoothCore", "BoothHardware"]),
        .executableTarget(
            name: "DarkroomBooth",
            dependencies: ["BoothCore", "BoothHardware", "BoothCameras", "BoothPrinting", "BoothImaging", "BoothIO"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist (camera usage strings) so `swift run` can use the camera.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/DarkroomBooth/Info.plist"]),
            ]
        ),
        .testTarget(name: "BoothCoreTests", dependencies: ["BoothCore"]),
        .testTarget(name: "BoothHardwareTests", dependencies: ["BoothHardware"]),
        .testTarget(name: "BoothPrintingTests", dependencies: ["BoothPrinting", "BoothHardware"]),
        .testTarget(name: "BoothImagingTests", dependencies: ["BoothImaging", "BoothCore"]),
    ]
)
