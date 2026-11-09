import Foundation
import Combine

// MARK: - Graphics

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    case remastered, classic, crt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .remastered: return "Remastered (2026)"
        case .classic: return "Classic Pixels"
        case .crt: return "CRT"
        }
    }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case original, aurora, gradient
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .aurora: return "Aurora (animated)"
        case .gradient: return "Gradient"
        }
    }
}

enum BorderStyle: String, Codable, CaseIterable, Identifiable {
    case black, ambient
    var id: String { rawValue }
    var title: String { self == .black ? "Black" : "Ambient Glow" }
}

enum UpscaleQuality: String, Codable, CaseIterable, Identifiable {
    case performance, balanced, ultra
    var id: String { rawValue }
    var title: String {
        switch self {
        case .performance: return "Performance"
        case .balanced: return "Balanced"
        case .ultra: return "Ultra"
        }
    }
    var maxScale: Int {
        switch self {
        case .performance: return 3
        case .balanced: return 5
        case .ultra: return 8
        }
    }
}

enum AspectMode: String, Codable, CaseIterable, Identifiable {
    case ntsc, square
    var id: String { rawValue }
    var title: String { self == .ntsc ? "4:3 (NTSC TV)" : "Square Pixels" }
}

struct GraphicsSettings: Codable, Equatable {
    var mode: RenderMode = .remastered
    var quality: UpscaleQuality = .balanced
    var renderScale: Double = 1.0
    var edgeSmoothing: Double = 0.5
    var edgeSharpness: Double = 1.0
    var lighting: Double = 1.0
    var specular: Double = 1.0
    var rimLight: Double = 1.0
    var shadows: Double = 1.0
    var lightAngle: Double = 233
    var background: BackgroundStyle = .aurora
    var particles: Double = 1.0
    var bloom: Bool = true
    var bloomIntensity: Double = 0.7
    var bloomThreshold: Double = 0.75
    var tonemapping: Bool = true
    var exposure: Double = 1.1
    var saturation: Double = 1.1
    var contrast: Double = 1.05
    var vignette: Double = 1.0
    var chromaticAberration: Double = 0.3
    var filmGrain: Double = 0.25
    var paletteSaturation: Double = 1.0
    var paletteHue: Double = 0
    var aspect: AspectMode = .ntsc
    var integerScaling: Bool = false
    var cropOverscan: Bool = false
    var border: BorderStyle = .ambient
    var sharpPixels: Bool = true
    var crtScanlines: Double = 0.7
    var crtMask: Double = 0.5
    var crtCurvature: Double = 0.5
    var vsync: Bool = true
    var showFPS: Bool = false
    var unlimitedSprites: Bool = true
}

enum GraphicsPreset: String, CaseIterable, Identifiable {
    case ultra, balanced, classic, crt
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultra: return "Remastered Ultra"
        case .balanced: return "Remastered Light"
        case .classic: return "Classic"
        case .crt: return "CRT"
        }
    }
    func apply(to s: GraphicsSettings) -> GraphicsSettings {
        var g = GraphicsSettings()
        // keep display/system choices
        g.aspect = s.aspect; g.integerScaling = s.integerScaling; g.cropOverscan = s.cropOverscan
        g.vsync = s.vsync; g.showFPS = s.showFPS; g.unlimitedSprites = s.unlimitedSprites
        switch self {
        case .ultra:
            g.quality = .ultra
        case .balanced:
            g.quality = .performance; g.particles = 0; g.chromaticAberration = 0; g.filmGrain = 0
            g.bloomIntensity = 0.5; g.background = .gradient
        case .classic:
            g.mode = .classic; g.bloom = false; g.tonemapping = false; g.exposure = 1; g.saturation = 1
            g.contrast = 1; g.vignette = 0; g.chromaticAberration = 0; g.filmGrain = 0; g.border = .black
        case .crt:
            g.mode = .crt; g.tonemapping = false; g.exposure = 1.15; g.saturation = 1.05; g.contrast = 1
            g.bloomIntensity = 0.5; g.bloomThreshold = 0.6; g.vignette = 0.8; g.chromaticAberration = 0.4
            g.filmGrain = 0.2
        }
        return g
    }
}

// MARK: - Audio

enum SoundMode: String, Codable, CaseIterable, Identifiable {
    case original, remastered
    var id: String { rawValue }
    var title: String { self == .original ? "Original (NES 2A03)" : "Remastered 2026" }
}

enum LeadTone: String, Codable, CaseIterable, Identifiable {
    case clean, warm, supersaw
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clean: return "Clean (hi-fi original)"
        case .warm: return "Warm Analog"
        case .supersaw: return "Supersaw"
        }
    }
    var code: Int32 {
        switch self {
        case .clean: return 0
        case .warm: return 1
        case .supersaw: return 2
        }
    }
}

struct AudioSettings: Codable, Equatable {
    var soundMode: SoundMode = .remastered
    var leadTone: LeadTone = .warm
    var reverb: Double = 0.35
    var stereoWidth: Double = 0.7
    var bass: Double = 0.4
    var volume: Double = 0.8
    var muted: Bool = false
    var pulse1 = true, pulse2 = true, triangle = true, noise = true, dmc = true
    var muteWhenInactive = true

    var channelMask: UInt32 {
        var m: UInt32 = 0
        if pulse1 { m |= 1 }
        if pulse2 { m |= 2 }
        if triangle { m |= 4 }
        if noise { m |= 8 }
        if dmc { m |= 16 }
        return m
    }
}

// MARK: - Input

enum NESButton: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right, a, b, select, start, turboA, turboB
    var id: String { rawValue }
    var title: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .a: return "A"
        case .b: return "B"
        case .select: return "Select"
        case .start: return "Start"
        case .turboA: return "Turbo A"
        case .turboB: return "Turbo B"
        }
    }
    /// Bit in the NES controller shift register.
    var mask: UInt8 {
        switch self {
        case .a, .turboA: return 0x01
        case .b, .turboB: return 0x02
        case .select: return 0x04
        case .start: return 0x08
        case .up: return 0x10
        case .down: return 0x20
        case .left: return 0x40
        case .right: return 0x80
        }
    }
    var isTurbo: Bool { self == .turboA || self == .turboB }
}

enum Hotkey: String, Codable, CaseIterable, Identifiable {
    case pause, fastForward, saveState, loadState, reset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pause: return "Pause / Resume"
        case .fastForward: return "Fast Forward (hold)"
        case .saveState: return "Quick Save"
        case .loadState: return "Quick Load"
        case .reset: return "Reset"
        }
    }
}

struct KeyBinding: Codable, Hashable {
    var code: UInt16
    var label: String
    init(_ code: UInt16) { self.code = code; self.label = KeyNames.name(for: code) }
    init(code: UInt16, label: String) { self.code = code; self.label = label }
}

enum PadControl: String, Codable, CaseIterable, Identifiable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case menu, options
    case stickUp, stickDown, stickLeft, stickRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dpadUp: return "D-Pad Up"
        case .dpadDown: return "D-Pad Down"
        case .dpadLeft: return "D-Pad Left"
        case .dpadRight: return "D-Pad Right"
        case .buttonA: return "South (A / ✕)"
        case .buttonB: return "East (B / ○)"
        case .buttonX: return "West (X / □)"
        case .buttonY: return "North (Y / △)"
        case .leftShoulder: return "L1 / LB"
        case .rightShoulder: return "R1 / RB"
        case .leftTrigger: return "L2 / LT"
        case .rightTrigger: return "R2 / RT"
        case .menu: return "Menu / Start"
        case .options: return "Options / Select"
        case .stickUp: return "Left Stick Up"
        case .stickDown: return "Left Stick Down"
        case .stickLeft: return "Left Stick Left"
        case .stickRight: return "Left Stick Right"
        }
    }
}

struct PlayerBindings: Codable, Equatable {
    var keys: [NESButton: KeyBinding]
    var pad: [NESButton: PadControl]

    static let defaultPad: [NESButton: PadControl] = [
        .up: .dpadUp, .down: .dpadDown, .left: .dpadLeft, .right: .dpadRight,
        .a: .buttonB, .b: .buttonA, .turboA: .buttonY, .turboB: .buttonX,
        .select: .options, .start: .menu,
    ]
    static let player1 = PlayerBindings(keys: [
        .up: KeyBinding(126), .down: KeyBinding(125), .left: KeyBinding(123), .right: KeyBinding(124),
        .a: KeyBinding(7), .b: KeyBinding(6), .turboA: KeyBinding(1), .turboB: KeyBinding(0),
        .select: KeyBinding(60), .start: KeyBinding(36),
    ], pad: defaultPad)
    static let player2 = PlayerBindings(keys: [
        .up: KeyBinding(34), .down: KeyBinding(40), .left: KeyBinding(38), .right: KeyBinding(37),
        .a: KeyBinding(4), .b: KeyBinding(5), .select: KeyBinding(17), .start: KeyBinding(16),
    ], pad: defaultPad)
}

struct InputSettings: Codable, Equatable {
    var players: [PlayerBindings] = [.player1, .player2]
    var hotkeys: [Hotkey: KeyBinding] = [
        .pause: KeyBinding(35), .fastForward: KeyBinding(48),
        .saveState: KeyBinding(96), .loadState: KeyBinding(98), .reset: KeyBinding(120),
    ]
    var turboRate: Double = 15
    var stickAsDPad: Bool = true
    var deadzone: Double = 0.35
}

// MARK: - Store

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var graphics: GraphicsSettings { didSet { Self.save(graphics, key: "graphics.v1") } }
    @Published var audio: AudioSettings { didSet { Self.save(audio, key: "audio.v1") } }
    @Published var input: InputSettings { didSet { Self.save(input, key: "input.v1") } }

    var lastROMPath: String? {
        get { UserDefaults.standard.string(forKey: "lastROMPath") }
        set { UserDefaults.standard.set(newValue, forKey: "lastROMPath") }
    }

    private init() {
        graphics = Self.load(key: "graphics.v1") ?? GraphicsSettings()
        audio = Self.load(key: "audio.v1") ?? AudioSettings()
        input = Self.load(key: "input.v1") ?? InputSettings()
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    private static func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Key names (ANSI layout virtual key codes)

enum KeyNames {
    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 117: "Fwd Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        56: "Left Shift", 60: "Right Shift", 59: "Left Control", 62: "Right Control",
        58: "Left Option", 61: "Right Option", 55: "Left Command", 54: "Right Command", 57: "Caps Lock",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3", 86: "Num 4", 87: "Num 5", 88: "Num 6",
        89: "Num 7", 91: "Num 8", 92: "Num 9", 76: "Num Enter", 65: "Num .", 69: "Num +", 78: "Num -",
        67: "Num *", 75: "Num /", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    ]
    static func name(for code: UInt16) -> String { table[code] ?? "Key \(code)" }

    /// Device-dependent modifier masks (NX_DEVICE*KEYMASK) so left/right modifiers can be bound separately.
    static let modifierMasks: [UInt16: UInt] = [
        56: 0x02, 60: 0x04, 59: 0x01, 62: 0x2000, 58: 0x20, 61: 0x40, 55: 0x08, 54: 0x10, 57: 0x10000,
    ]
}
