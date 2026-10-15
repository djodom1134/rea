import AppKit
import BoothCore
import BoothIO
import SwiftUI

/// The guest-facing full-screen booth.
struct BoothView: View {
    @EnvironmentObject private var controller: BoothController
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pinEntry = ""
    @State private var askingForPin = false
    @FocusState private var focused: Bool

    private var settings: BoothSettings { controller.configuration.settings }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            liveView
            overlay
            if let message = controller.message {
                VStack {
                    Spacer()
                    Text(message).font(.title3).padding().background(.red.opacity(0.8), in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { controller.send(.touch) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            if press.key == .escape {
                exitRequested()
                return .handled
            }
            let key = String(press.characters)
            if let command = KeyBindings.command(for: key, control: press.modifiers.contains(.control)) {
                controller.send(.command(command))
                return .handled
            }
            return .ignored
        }
        .background(WindowAccessor { window in
            window.collectionBehavior.insert(.fullScreenPrimary)
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        })
        .onAppear { focused = true }
        .onDisappear {
            NSApp.presentationOptions = []
            Task { await controller.stopBooth() }
        }
        .sheet(isPresented: $askingForPin) { pinSheet }
    }

    @ViewBuilder private var liveView: some View {
        if let frame = displayedImage {
            Image(decorative: frame, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .ignoresSafeArea()
        }
    }

    private var displayedImage: CGImage? {
        switch controller.stage {
        case .review, .copiesPrompt, .endInstructions:
            return controller.lastOutput ?? controller.lastPhoto
        case .afterPhoto, .afterLastPhoto, .processing:
            return controller.lastPhoto ?? controller.liveFrame
        default:
            return controller.liveFrame
        }
    }

    private var mirrored: Bool {
        guard settings.mirrorLiveView else { return false }
        switch controller.stage {
        case .review, .copiesPrompt, .endInstructions, .afterPhoto, .afterLastPhoto, .processing: return false
        default: return true
        }
    }

    @ViewBuilder private var overlay: some View {
        switch controller.stage {
        case .attract:
            banner(settings.text.startText)
        case .outOfService(let reason):
            banner(reason.isEmpty ? settings.text.maintenanceText : reason)
        case .startSession, .getReady:
            banner(settings.text.readyText)
        case .beforePhoto(let n), .afterPhoto(let n):
            banner("Photo \(n) of \(controller.layout.photoCount)")
        case .countdown(let remaining, _):
            Text("\(remaining)")
                .font(.system(size: 280, weight: .bold, design: .rounded))
                .shadow(radius: 20)
        case .takePhoto:
            Color.white.ignoresSafeArea().transition(.opacity)
        case .afterLastPhoto, .processing:
            VStack(spacing: 24) {
                ProgressView().controlSize(.large)
                Text("Creating your photos…").font(.largeTitle)
            }
        case .review:
            VStack {
                Text(settings.text.reviewText).font(.largeTitle.bold()).padding(.top, 40)
                Spacer()
                HStack(spacing: 40) {
                    if controller.retakesRemaining > 0 {
                        Button("Retake") { controller.send(.command(.retake)) }
                    }
                }
                .buttonStyle(BoothButtonStyle())
                .padding(.bottom, 60)
            }
        case .copiesPrompt:
            VStack(spacing: 30) {
                Text(settings.text.copiesPromptText).font(.largeTitle.bold())
                HStack(spacing: 24) {
                    ForEach(1...max(1, settings.maxCopies), id: \.self) { n in
                        Button("\(n)") { controller.send(.copiesChosen(n)) }
                    }
                }
                .buttonStyle(BoothButtonStyle())
            }
        case .endInstructions:
            VStack {
                Spacer()
                banner(settings.text.endText)
                    .padding(.bottom, 60)
            }
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 54, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 28))
    }

    private var pinSheet: some View {
        VStack(spacing: 16) {
            Text("Enter PIN code to exit:").font(.headline)
            SecureField("PIN", text: $pinEntry)
                .frame(width: 200)
                .onSubmit(checkPin)
            HStack {
                Button("Cancel") {
                    pinEntry = ""
                    askingForPin = false
                }
                Button("Exit Booth Mode", action: checkPin).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
    }

    private func exitRequested() {
        if settings.operatorPin?.isEmpty == false {
            askingForPin = true
        } else {
            dismissWindow(id: "booth")
        }
    }

    private func checkPin() {
        guard pinEntry == settings.operatorPin else {
            pinEntry = ""
            return
        }
        pinEntry = ""
        askingForPin = false
        dismissWindow(id: "booth")
    }
}

struct BoothButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .padding(.horizontal, 48)
            .padding(.vertical, 22)
            .background(.white.opacity(configuration.isPressed ? 0.35 : 0.2), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 2))
    }
}

/// Gives SwiftUI content access to its hosting `NSWindow`.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
