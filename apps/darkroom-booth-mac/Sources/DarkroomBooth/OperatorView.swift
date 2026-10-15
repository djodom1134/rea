import AppKit
import BoothCore
import BoothHardware
import SwiftUI

/// Operator setup: event, camera, printer, layout and session options.
/// The Windows app's equivalent is the event page plus the Booth Options sheet.
struct OperatorView: View {
    @EnvironmentObject private var controller: BoothController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Event") {
                TextField("Event name", text: $controller.configuration.eventName)
                LabeledContent("Folder") {
                    HStack {
                        Text(controller.configuration.eventDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseEventFolder() }
                    }
                }
            }

            Section("Camera") {
                Picker("Camera", selection: $controller.configuration.cameraID) {
                    Text("None").tag(String?.none)
                    ForEach(controller.cameras) { camera in
                        Text(camera.name).tag(String?.some(camera.id))
                    }
                    // Keep a saved camera selectable while it is unplugged or before devices load.
                    if let saved = controller.configuration.cameraID, !controller.cameras.contains(where: { $0.id == saved }) {
                        Text("Saved camera (not connected)").tag(String?.some(saved))
                    }
                }
                ForEach(controller.tetheringNotes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add hot folder…") { addHotFolder() }
                    Button("Refresh") { Task { await controller.refreshDevices() } }
                }
                Toggle("Live view", isOn: $controller.configuration.settings.liveViewEnabled)
                Toggle("Mirror live view", isOn: $controller.configuration.settings.mirrorLiveView)
            }

            Section("Printer") {
                Picker("Printer", selection: $controller.configuration.printerName) {
                    Text("None").tag(String?.none)
                    ForEach(controller.printers) { printer in
                        Text(printer.makeAndModel.map { "\(printer.name) (\($0))" } ?? printer.name)
                            .tag(String?.some(printer.id))
                    }
                    if let saved = controller.configuration.printerName, !controller.printers.contains(where: { $0.id == saved }) {
                        Text("\(saved) (not available)").tag(String?.some(saved))
                    }
                }
                if let status = controller.printerStatus {
                    LabeledContent("Status", value: describe(status))
                    ForEach(status.markerLevels.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        LabeledContent(entry.key, value: "\(entry.value)%")
                    }
                }
                Toggle("Print", isOn: $controller.configuration.settings.printEnabled)
                Stepper("Copies: \(controller.configuration.settings.printCopies)",
                        value: $controller.configuration.settings.printCopies, in: 1...10)
                Toggle("Ask guests how many copies", isOn: $controller.configuration.settings.copiesPrompt)
            }

            Section("Layout and session") {
                Picker("Print layout", selection: $controller.configuration.layoutID) {
                    ForEach(PrintLayout.builtIn) { layout in
                        Text(layout.name).tag(layout.id)
                    }
                }
                Picker("Countdown", selection: $controller.configuration.settings.countdownMode) {
                    Text("No countdown").tag(CountdownMode.none)
                    Text("Before first photo only").tag(CountdownMode.firstPhotoOnly)
                    Text("Before each photo").tag(CountdownMode.eachPhoto)
                }
                Stepper("First countdown: \(controller.configuration.settings.timing.firstPhotoCountdown) s",
                        value: $controller.configuration.settings.timing.firstPhotoCountdown, in: 1...10)
                Stepper("Later countdowns: \(controller.configuration.settings.timing.countdown) s",
                        value: $controller.configuration.settings.timing.countdown, in: 1...10)
                Toggle("Review before printing", isOn: $controller.configuration.settings.reviewEnabled)
                Stepper("Retakes allowed: \(controller.configuration.settings.maxRetakes)",
                        value: $controller.configuration.settings.maxRetakes, in: 0...5)
                Picker("Default colour", selection: $controller.configuration.settings.defaultColorEffect) {
                    ForEach(ColorEffect.allCases, id: \.self) { effect in
                        Text(effect.rawValue.capitalized).tag(effect)
                    }
                }
                TextField("Start text", text: $controller.configuration.settings.text.startText)
                TextField("Thank-you text", text: $controller.configuration.settings.text.endText)
            }

            Section {
                if let message = controller.message {
                    Text(message).foregroundStyle(.red)
                }
                Button("Start Booth Mode") {
                    Task {
                        await controller.startBooth()
                        if controller.isBoothRunning { openWindow(id: "booth") }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.configuration.cameraID == nil)
            }
        }
        .formStyle(.grouped)
        .task { await controller.refreshDevices() }
        .onChange(of: controller.configuration.printerName) {
            Task { await controller.refreshPrinterStatus() }
        }
    }

    private func describe(_ status: PrinterStatus) -> String {
        let state: String
        switch status.state {
        case .idle: state = "Ready"
        case .printing: state = "Printing"
        case .stopped(let reason): state = "Stopped: \(reason)"
        case .unknown(let value): state = "Unknown (\(value))"
        }
        return status.reasons.isEmpty ? state : "\(state) — \(status.reasons.joined(separator: ", "))"
    }

    private func chooseEventFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            controller.configuration.eventDirectoryPath = url.path
        }
    }

    private func addHotFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as hot folder"
        if panel.runModal() == .OK, let url = panel.url {
            if !controller.configuration.hotFolderPaths.contains(url.path) {
                controller.configuration.hotFolderPaths.append(url.path)
            }
            controller.configuration.cameraID = url.path
            Task { await controller.refreshDevices() }
        }
    }
}
