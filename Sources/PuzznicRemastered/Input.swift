import AppKit
import GameController
import Combine

enum CaptureTarget: Equatable {
    case key(player: Int, button: NESButton)
    case pad(player: Int, button: NESButton)
    case hotkey(Hotkey)
}

extension PadControl {
    func isPressed(_ gp: GCExtendedGamepad, deadzone: Float) -> Bool {
        switch self {
        case .dpadUp: return gp.dpad.up.isPressed
        case .dpadDown: return gp.dpad.down.isPressed
        case .dpadLeft: return gp.dpad.left.isPressed
        case .dpadRight: return gp.dpad.right.isPressed
        case .buttonA: return gp.buttonA.isPressed
        case .buttonB: return gp.buttonB.isPressed
        case .buttonX: return gp.buttonX.isPressed
        case .buttonY: return gp.buttonY.isPressed
        case .leftShoulder: return gp.leftShoulder.isPressed
        case .rightShoulder: return gp.rightShoulder.isPressed
        case .leftTrigger: return gp.leftTrigger.value > 0.5
        case .rightTrigger: return gp.rightTrigger.value > 0.5
        case .menu: return gp.buttonMenu.isPressed
        case .options: return gp.buttonOptions?.isPressed ?? false
        case .stickUp: return gp.leftThumbstick.yAxis.value > deadzone
        case .stickDown: return gp.leftThumbstick.yAxis.value < -deadzone
        case .stickLeft: return gp.leftThumbstick.xAxis.value < -deadzone
        case .stickRight: return gp.leftThumbstick.xAxis.value > deadzone
        }
    }
}

/// Keyboard + game controller input with live rebinding.
final class InputManager: ObservableObject {
    @Published var capture: CaptureTarget? {
        didSet { capture == nil ? stopPadPolling() : startPadPollingIfNeeded() }
    }
    @Published private(set) var controllerNames: [String] = []

    weak var gameWindow: NSWindow?
    var onHotkey: ((Hotkey) -> Void)?

    private var down = Set<UInt16>()
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var padTimer: Timer?
    private var padNeedsRelease = false

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshControllers()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshControllers()
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let w = note.object as? NSWindow, w === self.gameWindow else { return }
            self.down.removeAll()
        })
        refreshControllers()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var gamepads: [GCController] { GCController.controllers().filter { $0.extendedGamepad != nil } }

    private func refreshControllers() {
        controllerNames = gamepads.enumerated().map { i, c in
            "Player \(i + 1): \(c.vendorName ?? "Controller")"
        }
    }

    func isHeld(_ hotkey: Hotkey) -> Bool {
        guard let kb = SettingsStore.shared.input.hotkeys[hotkey] else { return false }
        return down.contains(kb.code)
    }

    // MARK: Keyboard

    private func isModifierDown(_ e: NSEvent) -> Bool {
        guard let mask = KeyNames.modifierMasks[e.keyCode] else { return false }
        return (e.modifierFlags.rawValue & mask) != 0
    }

    private func isBound(_ code: UInt16) -> Bool {
        let s = SettingsStore.shared.input
        for p in s.players where p.keys.values.contains(where: { $0.code == code }) { return true }
        return s.hotkeys.values.contains(where: { $0.code == code })
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if let target = capture {
            switch target {
            case .pad:
                if e.type == .keyDown && e.keyCode == 53 { capture = nil; return nil }
                return e
            case .key, .hotkey:
                switch e.type {
                case .keyDown:
                    if e.keyCode == 53 { capture = nil; return nil } // Esc cancels
                    assignKey(target, code: e.keyCode)
                    return nil
                case .flagsChanged:
                    if isModifierDown(e) { assignKey(target, code: e.keyCode) }
                    return nil
                default:
                    return nil
                }
            }
        }

        guard let w = e.window, w === gameWindow else { return e }
        switch e.type {
        case .keyDown:
            if e.modifierFlags.contains(.command) { return e } // leave menu shortcuts alone
            if !e.isARepeat {
                down.insert(e.keyCode)
                let hk = SettingsStore.shared.input.hotkeys.first(where: { $0.value.code == e.keyCode })?.key
                if let hk, hk != .fastForward { onHotkey?(hk) }
            }
            return isBound(e.keyCode) ? nil : e
        case .keyUp:
            down.remove(e.keyCode)
            return isBound(e.keyCode) ? nil : e
        case .flagsChanged:
            if isModifierDown(e) { down.insert(e.keyCode) } else { down.remove(e.keyCode) }
            return e
        default:
            return e
        }
    }

    private func assignKey(_ target: CaptureTarget, code: UInt16) {
        let kb = KeyBinding(code)
        var s = SettingsStore.shared.input
        switch target {
        case .key(let player, let button):
            guard player < s.players.count else { break }
            for (b, existing) in s.players[player].keys where existing.code == code && b != button {
                s.players[player].keys[b] = nil
            }
            s.players[player].keys[button] = kb
        case .hotkey(let hk):
            for (h, existing) in s.hotkeys where existing.code == code && h != hk { s.hotkeys[h] = nil }
            s.hotkeys[hk] = kb
        case .pad:
            break
        }
        SettingsStore.shared.input = s
        capture = nil
    }

    // MARK: Game controllers

    private func startPadPollingIfNeeded() {
        guard case .pad = capture, padTimer == nil else { return }
        padNeedsRelease = true
        padTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.pollPadCapture()
        }
    }

    private func stopPadPolling() {
        padTimer?.invalidate()
        padTimer = nil
    }

    private func pollPadCapture() {
        guard case .pad(let player, let button) = capture else { stopPadPolling(); return }
        let dz = Float(max(0.5, SettingsStore.shared.input.deadzone))
        var pressed: PadControl?
        for c in gamepads {
            guard let gp = c.extendedGamepad else { continue }
            if let hit = PadControl.allCases.first(where: { $0.isPressed(gp, deadzone: dz) }) { pressed = hit; break }
        }
        // wait until everything is released once, so a held button is not captured by accident
        if padNeedsRelease { if pressed == nil { padNeedsRelease = false }; return }
        guard let ctl = pressed else { return }
        var s = SettingsStore.shared.input
        if player < s.players.count {
            for (b, existing) in s.players[player].pad where existing == ctl && b != button { s.players[player].pad[b] = nil }
            s.players[player].pad[button] = ctl
            SettingsStore.shared.input = s
        }
        capture = nil
    }

    // MARK: Per-frame state

    func buttons(for port: Int, frame: UInt64) -> UInt8 {
        let s = SettingsStore.shared.input
        guard port < s.players.count else { return 0 }
        let pb = s.players[port]
        var pressed = Set<NESButton>()
        for (btn, kb) in pb.keys where down.contains(kb.code) { pressed.insert(btn) }

        let pads = gamepads
        if port < pads.count, let gp = pads[port].extendedGamepad {
            let dz = Float(s.deadzone)
            for (btn, ctl) in pb.pad where ctl.isPressed(gp, deadzone: dz) { pressed.insert(btn) }
            if s.stickAsDPad {
                let x = gp.leftThumbstick.xAxis.value, y = gp.leftThumbstick.yAxis.value
                if x < -dz { pressed.insert(.left) }
                if x > dz { pressed.insert(.right) }
                if y > dz { pressed.insert(.up) }
                if y < -dz { pressed.insert(.down) }
            }
        }

        let half = max(1, Int((60.0 / (2.0 * max(1.0, s.turboRate))).rounded()))
        let turboOn = (Int(frame % 1_000_000) / half) % 2 == 0
        var mask: UInt8 = 0
        for b in pressed {
            if b.isTurbo { if turboOn { mask |= b.mask } } else { mask |= b.mask }
        }
        return mask
    }
}
