import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GraphicsSettingsView()
                .tabItem { Label("Graphics", systemImage: "sparkles.tv") }
            InputSettingsView()
                .tabItem { Label("Controls", systemImage: "gamecontroller") }
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
        }
        .frame(width: 620, height: 680)
    }
}

// MARK: - Helpers

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: String = "%.2f"

    var body: some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Graphics

struct GraphicsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Preset") {
                HStack {
                    ForEach(GraphicsPreset.allCases) { p in
                        Button(p.title) { store.graphics = p.apply(to: store.graphics) }
                    }
                }
            }

            Section("Display") {
                Picker("Render mode", selection: $store.graphics.mode) {
                    ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Aspect ratio", selection: $store.graphics.aspect) {
                    ForEach(AspectMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Window border", selection: $store.graphics.border) {
                    ForEach(BorderStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Integer scaling", isOn: $store.graphics.integerScaling)
                Toggle("Crop overscan (8 px top & bottom)", isOn: $store.graphics.cropOverscan)
                SliderRow(title: "Render scale", value: $store.graphics.renderScale, range: 0.5...2.0, format: "%.2f×")
                Toggle("V-Sync", isOn: $store.graphics.vsync)
                Toggle("Show FPS", isOn: $store.graphics.showFPS)
                Toggle("Remove sprite flicker (no 8-sprites-per-line limit)", isOn: $store.graphics.unlimitedSprites)
            }

            switch store.graphics.mode {
            case .remastered:
                Section("Remastered renderer") {
                    Picker("Reconstruction quality", selection: $store.graphics.quality) {
                        ForEach(UpscaleQuality.allCases) { Text($0.title).tag($0) }
                    }
                    SliderRow(title: "Edge rounding", value: $store.graphics.edgeSmoothing, range: 0.3...0.8)
                    SliderRow(title: "Edge sharpness", value: $store.graphics.edgeSharpness, range: 0.25...3.0)
                    SliderRow(title: "Surface lighting", value: $store.graphics.lighting, range: 0...1.5)
                    SliderRow(title: "Specular highlights", value: $store.graphics.specular, range: 0...2)
                    SliderRow(title: "Rim light", value: $store.graphics.rimLight, range: 0...2)
                    SliderRow(title: "Shadows", value: $store.graphics.shadows, range: 0...1)
                    SliderRow(title: "Light direction", value: $store.graphics.lightAngle, range: 0...360, format: "%.0f°")
                    Picker("Background", selection: $store.graphics.background) {
                        ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                    }
                    if store.graphics.background == .aurora {
                        SliderRow(title: "Light motes", value: $store.graphics.particles, range: 0...2)
                    }
                }
            case .classic:
                Section("Classic") {
                    Toggle("Sharp anti-aliased pixels", isOn: $store.graphics.sharpPixels)
                }
            case .crt:
                Section("CRT") {
                    SliderRow(title: "Scanlines", value: $store.graphics.crtScanlines, range: 0...1)
                    SliderRow(title: "Aperture grille", value: $store.graphics.crtMask, range: 0...1)
                    SliderRow(title: "Curvature", value: $store.graphics.crtCurvature, range: 0...1.5)
                }
            }

            Section("Post-processing") {
                Toggle("Bloom", isOn: $store.graphics.bloom)
                if store.graphics.bloom {
                    SliderRow(title: "Bloom intensity", value: $store.graphics.bloomIntensity, range: 0...2)
                    SliderRow(title: "Bloom threshold", value: $store.graphics.bloomThreshold, range: 0.1...1.5)
                }
                Toggle("Filmic tonemapping (ACES)", isOn: $store.graphics.tonemapping)
                SliderRow(title: "Exposure", value: $store.graphics.exposure, range: 0.5...2)
                SliderRow(title: "Saturation", value: $store.graphics.saturation, range: 0...2)
                SliderRow(title: "Contrast", value: $store.graphics.contrast, range: 0.5...1.5)
                SliderRow(title: "Vignette", value: $store.graphics.vignette, range: 0...2)
                SliderRow(title: "Chromatic aberration", value: $store.graphics.chromaticAberration, range: 0...2)
                SliderRow(title: "Film grain", value: $store.graphics.filmGrain, range: 0...2)
            }

            Section("NES palette") {
                SliderRow(title: "Palette saturation", value: $store.graphics.paletteSaturation, range: 0...2)
                SliderRow(title: "Palette hue shift", value: $store.graphics.paletteHue, range: -30...30, format: "%.0f°")
            }

            Section {
                Button("Restore Graphics Defaults") { store.graphics = GraphicsSettings() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Controls

struct BindingButton: View {
    let label: String
    let active: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(active ? "Press…" : label)
                .frame(minWidth: 120)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
    }
}

struct InputSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var input = GameSession.shared.input
    @State private var player = 0

    private func keyLabel(_ b: NESButton) -> String { store.input.players[player].keys[b]?.label ?? "—" }
    private func padLabel(_ b: NESButton) -> String { store.input.players[player].pad[b]?.title ?? "—" }

    var body: some View {
        Form {
            Section {
                Picker("Player", selection: $player) {
                    Text("Player 1").tag(0)
                    Text("Player 2").tag(1)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Click a binding, then press a key or controller button. Esc cancels.")
                    .foregroundStyle(.secondary)
            }

            Section("Buttons") {
                HStack {
                    Text("NES").frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                    Text("Keyboard").frame(minWidth: 140).foregroundStyle(.secondary)
                    Text("Controller").frame(minWidth: 140).foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(NESButton.allCases) { btn in
                    HStack {
                        Text(btn.title).frame(width: 90, alignment: .leading)
                        BindingButton(label: keyLabel(btn), active: input.capture == .key(player: player, button: btn)) {
                            input.capture = .key(player: player, button: btn)
                        }
                        BindingButton(label: padLabel(btn), active: input.capture == .pad(player: player, button: btn)) {
                            input.capture = .pad(player: player, button: btn)
                        }
                        Spacer()
                        Button {
                            store.input.players[player].keys[btn] = nil
                            store.input.players[player].pad[btn] = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear binding")
                    }
                }
            }

            Section("Shortcuts") {
                ForEach(Hotkey.allCases) { hk in
                    HStack {
                        Text(hk.title).frame(width: 170, alignment: .leading)
                        BindingButton(label: store.input.hotkeys[hk]?.label ?? "—", active: input.capture == .hotkey(hk)) {
                            input.capture = .hotkey(hk)
                        }
                        Spacer()
                        Button {
                            store.input.hotkeys[hk] = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Game controllers") {
                if input.controllerNames.isEmpty {
                    Text("No controller connected. Xbox, PlayStation, Switch Pro and MFi pads are supported.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(input.controllerNames, id: \.self) { Text($0) }
                }
                Toggle("Left stick also acts as D-Pad", isOn: $store.input.stickAsDPad)
                SliderRow(title: "Stick dead zone", value: $store.input.deadzone, range: 0.1...0.9)
                SliderRow(title: "Turbo rate", value: $store.input.turboRate, range: 5...30, format: "%.0f Hz")
            }

            Section {
                Button("Restore Default Controls") { store.input = InputSettings() }
            }
        }
        .formStyle(.grouped)
        .onDisappear { input.capture = nil }
    }
}

// MARK: - Audio

struct AudioSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Sound & music", selection: $store.audio.soundMode) {
                    ForEach(SoundMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(store.audio.soundMode == .remastered
                     ? "The original music and effects, performed live with new instruments, stereo chorus and reverb."
                     : "The authentic sound of the NES sound chip.")
                    .foregroundStyle(.secondary)
            }
            if store.audio.soundMode == .remastered {
                Section("Remastered sound") {
                    Picker("Lead instruments", selection: $store.audio.leadTone) {
                        ForEach(LeadTone.allCases) { Text($0.title).tag($0) }
                    }
                    SliderRow(title: "Reverb", value: $store.audio.reverb, range: 0...1)
                    SliderRow(title: "Stereo width", value: $store.audio.stereoWidth, range: 0...1)
                    SliderRow(title: "Bass", value: $store.audio.bass, range: 0...1)
                }
            }
            Section("Output") {
                HStack {
                    Text("Volume").frame(width: 170, alignment: .leading)
                    Slider(value: $store.audio.volume, in: 0...1)
                    Text("\(Int((store.audio.volume * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Toggle("Mute", isOn: $store.audio.muted)
                Toggle("Mute when in background", isOn: $store.audio.muteWhenInactive)
            }
            Section("Sound channels") {
                Toggle("Pulse 1", isOn: $store.audio.pulse1)
                Toggle("Pulse 2", isOn: $store.audio.pulse2)
                Toggle("Triangle", isOn: $store.audio.triangle)
                Toggle("Noise", isOn: $store.audio.noise)
                Toggle("DPCM samples", isOn: $store.audio.dmc)
            }
            Section {
                Button("Restore Audio Defaults") { store.audio = AudioSettings() }
            }
        }
        .formStyle(.grouped)
    }
}
