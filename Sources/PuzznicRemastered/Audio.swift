import Foundation
import AVFoundation

/// Pulls samples from the emulator's lock-free ring buffer on the audio render thread.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var sampleRate: Double = 48000
    private var configObserver: NSObjectProtocol?

    /// `pull` fills interleaved stereo frames (L, R) and returns how many frames it wrote.
    init(pull: @escaping (UnsafeMutablePointer<Float>, Int) -> Int) {
        let hwFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = hwFormat.sampleRate > 8000 ? hwFormat.sampleRate : 48000
        // standard format = deinterleaved float32, one buffer per channel
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        // boxed so the (possibly @Sendable) render block never mutates a captured `var`;
        // the scratch buffer is allocated once, never on the audio thread
        final class RenderState {
            var lastL: Float = 0, lastR: Float = 0
            let chunk = 2048
            let scratch: UnsafeMutablePointer<Float>
            init() { scratch = .allocate(capacity: 2048 * 2); scratch.initialize(repeating: 0, count: 2048 * 2) }
            deinit { scratch.deallocate() }
        }
        let state = RenderState()
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let d0 = buffers[0].mData else { return noErr }
            let outL = d0.assumingMemoryBound(to: Float.self)
            let outR = (buffers.count > 1 ? buffers[1].mData : nil)?.assumingMemoryBound(to: Float.self)
            let total = Int(frameCount)
            var done = 0
            var starved = false
            while done < total {
                let want = min(state.chunk, total - done)
                let got = starved ? 0 : pull(state.scratch, want)
                for i in 0..<got {
                    outL[done + i] = state.scratch[2 * i]
                    outR?[done + i] = state.scratch[2 * i + 1]
                }
                if got > 0 { state.lastL = state.scratch[2 * (got - 1)]; state.lastR = state.scratch[2 * (got - 1) + 1] }
                if got < want {
                    // underrun: fade out instead of clicking
                    starved = true
                    for i in got..<want {
                        state.lastL *= 0.995; state.lastR *= 0.995
                        outL[done + i] = state.lastL
                        outR?[done + i] = state.lastR
                    }
                }
                done += want
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch { NSLog("Audio engine failed to start: \(error)") }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if !self.engine.isRunning { try? self.engine.start() }
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.stop()
    }

    func setVolume(_ v: Float) {
        engine.mainMixerNode.outputVolume = max(0, min(1, v))
    }
}
