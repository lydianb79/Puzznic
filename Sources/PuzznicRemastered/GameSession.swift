import AppKit
import Combine
import UniformTypeIdentifiers
import NESCore

/// Central app state: ROM loading, frame pacing, save states, hotkeys.
final class GameSession: ObservableObject {
    static let shared = GameSession()

    @Published var isPaused = false
    @Published private(set) var romLoaded = false
    @Published private(set) var romName = ""
    @Published var fps = 0
    @Published var toast: String?

    let emulator = Emulator()
    let input = InputManager()
    private(set) var audio: AudioOutput?
    /// Bumped whenever a new ROM is loaded so the renderer can re-apply palettes.
    private(set) var romGeneration = 0

    private var frameCounter: UInt64 = 0
    private var accumulator = 0.0
    private var wasFastForwarding = false
    private var appActive = true
    private var cancellables = Set<AnyCancellable>()

    static let frameTime = 1.0 / 60.0988

    private init() {
        let emu = emulator
        audio = AudioOutput(pull: { out, n in emu.pullAudio(out, n) })
        input.onHotkey = { [weak self] hk in self?.handleHotkey(hk) }

        SettingsStore.shared.$audio
            .sink { [weak self] a in self?.applyAudio(a) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.appActive = false; self?.applyAudio(SettingsStore.shared.audio) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.appActive = true; self?.applyAudio(SettingsStore.shared.audio) }
            .store(in: &cancellables)

        DispatchQueue.main.async { self.autoLoadROM() }
    }

    private func applyAudio(_ a: AudioSettings) {
        let silent = a.muted || (a.muteWhenInactive && !appActive)
        audio?.setVolume(silent ? 0 : Float(a.volume))
    }

    // MARK: ROM

    private func autoLoadROM() {
        var candidates: [URL] = []
        if let p = SettingsStore.shared.lastROMPath { candidates.append(URL(fileURLWithPath: p)) }
        if let bundled = Bundle.main.url(forResource: "Puzznic", withExtension: "nes") { candidates.append(bundled) }
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(appDir.appendingPathComponent("Puzznic.nes"))
        candidates.append(appDir.deletingLastPathComponent().appendingPathComponent("Puzznic.nes"))
        candidates.append(appDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Puzznic.nes"))
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if (try? loadROMThrowing(url)) != nil { return }
        }
    }

    func openROMPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open NES ROM"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let nes = UTType(filenameExtension: "nes") { panel.allowedContentTypes = [nes] }
        if panel.runModal() == .OK, let url = panel.url { loadROM(url) }
    }

    func loadROM(_ url: URL) {
        do { try loadROMThrowing(url) } catch { showToast(error.localizedDescription) }
    }

    private func loadROMThrowing(_ url: URL) throws {
        try emulator.load(url: url)
        guard let nes = emulator.nes else { return }
        nes_set_sample_rate(nes, audio?.sampleRate ?? 48000)
        romName = url.deletingPathExtension().lastPathComponent
        romLoaded = true
        isPaused = false
        romGeneration += 1
        frameCounter = 0
        accumulator = 0
        SettingsStore.shared.lastROMPath = url.path
        showToast("Loaded \(romName)")
    }

    // MARK: Frame pacing (called by the renderer every display refresh)

    /// Runs as many emulated frames as the elapsed time requires. Returns true if a new frame was produced.
    @discardableResult
    func tick(dt: Double) -> Bool {
        guard let nes = emulator.nes, !isPaused else { accumulator = 0; return false }
        let g = SettingsStore.shared.graphics
        let a = SettingsStore.shared.audio
        nes_set_unlimited_sprites(nes, g.unlimitedSprites ? 1 : 0)
        nes_set_channel_mask(nes, a.channelMask)
        nes_set_audio_mode(nes, a.soundMode == .remastered ? 1 : 0)
        nes_set_remaster_audio(nes, Float(a.reverb), Float(a.stereoWidth), Float(a.bass), a.leadTone.code)

        var frames = 0
        if abs(dt - Self.frameTime) < 0.0025 {
            // display runs at ~60 Hz: lock one emulated frame to each refresh; audio rate control absorbs the drift
            frames = 1
            accumulator = 0
        } else {
            accumulator += dt
            while accumulator >= Self.frameTime && frames < 4 { accumulator -= Self.frameTime; frames += 1 }
            if frames == 4 { accumulator = 0 }
        }

        let ff = input.isHeld(.fastForward)
        if ff != wasFastForwarding { nes_set_audio_enabled(nes, ff ? 0 : 1); wasFastForwarding = ff }
        if ff { frames = max(frames, 1) * 4 }

        for _ in 0..<frames {
            nes_set_buttons(nes, 0, input.buttons(for: 0, frame: frameCounter))
            nes_set_buttons(nes, 1, input.buttons(for: 1, frame: frameCounter))
            nes_run_frame(nes)
            frameCounter &+= 1
        }

        // dynamic rate control: keep ~45 ms of audio queued
        let rate = audio?.sampleRate ?? 48000
        let target = rate * 0.045
        let avail = Double(nes_audio_available(nes))
        nes_set_rate_adjust(nes, 1.0 + 0.005 * (target - avail) / target)
        return frames > 0
    }

    // MARK: Commands

    func togglePause() {
        guard romLoaded else { return }
        isPaused.toggle()
        showToast(isPaused ? "Paused" : "Resumed")
    }

    func reset() {
        guard let nes = emulator.nes else { return }
        nes_reset(nes)
        isPaused = false
        showToast("Reset")
    }

    private var stateURL: URL? {
        guard romLoaded,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Puzznic Remastered/States", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(romName).state")
    }

    func saveState() {
        guard let url = stateURL, let data = emulator.saveState() else { return }
        do { try data.write(to: url); showToast("State saved") } catch { showToast("Could not save state") }
    }

    func loadState() {
        guard let url = stateURL else { return }
        guard let data = try? Data(contentsOf: url), emulator.loadState(data) else {
            showToast("No saved state yet"); return
        }
        isPaused = false
        showToast("State loaded")
    }

    private func handleHotkey(_ hk: Hotkey) {
        switch hk {
        case .pause: togglePause()
        case .saveState: saveState()
        case .loadState: loadState()
        case .reset: reset()
        case .fastForward: break
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
