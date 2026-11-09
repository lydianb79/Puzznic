import SwiftUI
import MetalKit
import UniformTypeIdentifiers

final class GameMTKView: MTKView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    // swallow keys so unbound keys don't trigger the system beep; input is read by InputManager
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
        window?.makeFirstResponder(self)
        window?.backgroundColor = .black
    }
}

struct MetalGameView: NSViewRepresentable {
    let session: GameSession

    final class Coordinator { var renderer: Renderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GameMTKView {
        let view = GameMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.onWindowChange = { [weak session] w in session?.input.gameWindow = w }
        context.coordinator.renderer = Renderer(view: view, session: session)
        return view
    }

    func updateNSView(_ nsView: GameMTKView, context: Context) {}
}

struct GameContainerView: View {
    @EnvironmentObject var session: GameSession
    @ObservedObject private var store = SettingsStore.shared
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            MetalGameView(session: session)
                .ignoresSafeArea()

            if !session.romLoaded {
                RomPromptView()
            } else if session.isPaused {
                PauseOverlay()
            }

            if store.graphics.showFPS {
                VStack {
                    HStack {
                        Spacer()
                        Text("\(session.fps) FPS")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(10)
                    }
                    Spacer()
                }
            }

            if let toast = session.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .animation(.easeOut(duration: 0.2), value: session.toast)
            }

            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .padding(12)
            }
        }
        .background(Color.black)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { session.loadROM(url) } }
            }
            return true
        }
    }
}

struct RomPromptView: View {
    @EnvironmentObject var session: GameSession
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 54))
                .foregroundStyle(.linearGradient(colors: [.mint, .purple], startPoint: .top, endPoint: .bottom))
            Text("Puzznic Remastered")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Drop your Puzznic .nes file here, or open it.")
                .foregroundStyle(.secondary)
            Button("Open ROM…") { session.openROMPanel() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct PauseOverlay: View {
    @EnvironmentObject var session: GameSession
    var body: some View {
        VStack(spacing: 14) {
            Text("PAUSED")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .tracking(6)
            HStack(spacing: 12) {
                Button("Resume") { session.togglePause() }.keyboardShortcut(.defaultAction)
                Button("Reset") { session.reset() }
                SettingsButton()
            }
            .controlSize(.large)
        }
        .padding(36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}
