import Foundation
import os
import NESCore

enum EmulatorError: LocalizedError {
    case load(String)
    var errorDescription: String? {
        switch self { case .load(let m): return m }
    }
}

/// Owns the NES machine. Everything runs on the main thread except `pullAudio`,
/// which the audio render thread calls; the pointer swap is guarded by an unfair lock.
final class Emulator {
    private(set) var nes: OpaquePointer?
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        if let nes { nes_destroy(nes) }
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func load(url: URL) throws {
        let data = try Data(contentsOf: url)
        let errLen = 256
        var err = [CChar](repeating: 0, count: errLen)
        let created: OpaquePointer? = data.withUnsafeBytes { raw -> OpaquePointer? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return err.withUnsafeMutableBufferPointer { e in
                nes_create(base, raw.count, e.baseAddress, Int32(errLen))
            }
        }
        guard let created else {
            let msg = err.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw EmulatorError.load(msg.isEmpty ? "Could not read the ROM file." : msg)
        }
        os_unfair_lock_lock(lock)
        let old = nes
        nes = created
        os_unfair_lock_unlock(lock)
        if let old { nes_destroy(old) }
    }

    func pullAudio(_ out: UnsafeMutablePointer<Float>, _ count: Int) -> Int {
        guard os_unfair_lock_trylock(lock) else { return 0 }
        defer { os_unfair_lock_unlock(lock) }
        guard let nes else { return 0 }
        return Int(nes_audio_read(nes, out, Int32(count)))
    }

    func saveState() -> Data? {
        guard let nes else { return nil }
        var data = Data(count: nes_state_size())
        let ok = data.withUnsafeMutableBytes { buf in nes_save_state(nes, buf.baseAddress, buf.count) }
        return ok != 0 ? data : nil
    }

    func loadState(_ data: Data) -> Bool {
        guard let nes else { return false }
        return data.withUnsafeBytes { buf in nes_load_state(nes, buf.baseAddress, buf.count) } != 0
    }
}
