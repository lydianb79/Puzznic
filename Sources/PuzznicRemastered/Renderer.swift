import Foundation
import MetalKit
import QuartzCore
import NESCore

struct SceneUniforms {
    var view = SIMD4<Float>()
    var rect = SIMD4<Float>()
    var style = SIMD4<Float>()
    var light = SIMD4<Float>()
    var crt = SIMD4<Float>()
    var extra = SIMD4<Float>()
}

struct PostUniforms {
    var a = SIMD4<Float>()
    var b = SIMD4<Float>()
    var c = SIMD4<Float>()
}

/// Metal renderer. Per frame:
///  1. upload the emulator's colour layers + classic framebuffer
///  2. (remastered) compute height maps and the high-resolution reconstruction
///  3. draw the scene (remastered / classic / CRT) into an HDR target
///  4. bloom chain
///  5. composite with tonemapping and lens effects into the drawable
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let heightPipeline: MTLComputePipelineState
    private let upscalePipeline: MTLComputePipelineState
    private let bloomDownPipeline: MTLComputePipelineState
    private let bloomUpPipeline: MTLComputePipelineState

    private let layerTex: MTLTexture
    private let fbTex: MTLTexture
    private let auxTex: MTLTexture
    private var upBG: MTLTexture?
    private var upSP: MTLTexture?
    private var upAux: MTLTexture?
    private var upScale = 0
    private var sceneTex: MTLTexture?
    private var bloomDown: [MTLTexture] = []
    private var bloomUp: [MTLTexture] = []

    private let paletteBuf: MTLBuffer
    private let backdropBuf: MTLBuffer
    private var paletteKey = SIMD3<Float>(-1, -1, -1)
    private var paletteGeneration = -1
    private var layerScratch = [UInt8](repeating: 0, count: 256 * 240 * 2)

    private let session: GameSession
    private let inflight = DispatchSemaphore(value: 1)
    private var lastTime: CFTimeInterval = 0
    private let startTime = CACurrentMediaTime()
    private var fpsCount = 0
    private var fpsStamp: CFTimeInterval = 0
    private var lastVSync: Bool?

    init?(view: MTKView, session: GameSession) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.session = session

        do {
            let lib = try device.makeLibrary(source: ShaderSource.metal, options: nil)
            func fn(_ n: String) throws -> MTLFunction {
                guard let f = lib.makeFunction(name: n) else { throw EmulatorError.load("Missing shader \(n)") }
                return f
            }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = try fn("fsVert")
            pd.fragmentFunction = try fn("sceneFrag")
            pd.colorAttachments[0].pixelFormat = .rgba16Float
            scenePipeline = try device.makeRenderPipelineState(descriptor: pd)
            pd.fragmentFunction = try fn("compositeFrag")
            pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
            compositePipeline = try device.makeRenderPipelineState(descriptor: pd)
            heightPipeline = try device.makeComputePipelineState(function: try fn("heightMaps"))
            upscalePipeline = try device.makeComputePipelineState(function: try fn("upscaleLayers"))
            bloomDownPipeline = try device.makeComputePipelineState(function: try fn("bloomDown"))
            bloomUpPipeline = try device.makeComputePipelineState(function: try fn("bloomUp"))
        } catch {
            NSLog("Metal setup failed: \(error)")
            return nil
        }

        // Shared textures are only valid on Apple-silicon GPUs; Intel iGPUs also report
        // hasUnifiedMemory == true but reject .shared textures, so key off the GPU family.
        let upload: MTLStorageMode = device.supportsFamily(.apple7) ? .shared : .managed
        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ s: MTLStorageMode, mip: Bool = false) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: mip)
            d.usage = usage
            d.storageMode = s
            return device.makeTexture(descriptor: d)
        }
        guard let lt = tex(.rg8Uint, 256, 240, [.shaderRead], upload),
              let ft = tex(.rgba8Unorm_srgb, 256, 240, [.shaderRead, .renderTarget], upload, mip: true),
              let at = tex(.rgba16Float, 256, 240, [.shaderRead, .shaderWrite], .private),
              let pb = device.makeBuffer(length: 64 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let bb = device.makeBuffer(length: 256, options: .storageModeShared)
        else { return nil }
        layerTex = lt; fbTex = ft; auxTex = at; paletteBuf = pb; backdropBuf = bb
        memset(bb.contents(), 0x0F, 256) // black backdrop until a ROM runs

        super.init()
        view.device = device
        view.delegate = self
    }

    // MARK: Resources

    private func makePrivateTex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func ensureSceneTargets(width: Int, height: Int) {
        if let s = sceneTex, s.width == width, s.height == height { return }
        sceneTex = makePrivateTex(.rgba16Float, width, height, [.renderTarget, .shaderRead])
        bloomDown = []
        bloomUp = []
        var w = width / 2, h = height / 2
        while w >= 8 && h >= 8 && bloomDown.count < 6 {
            if let d = makePrivateTex(.rgba16Float, w, h, [.shaderRead, .shaderWrite]),
               let u = makePrivateTex(.rgba16Float, w, h, [.shaderRead, .shaderWrite]) {
                bloomDown.append(d); bloomUp.append(u)
            }
            w /= 2; h /= 2
        }
    }

    private func ensureUpscaleTargets(scale: Int) {
        if scale == upScale, upBG != nil { return }
        upScale = scale
        let w = 256 * scale, h = 240 * scale
        upBG = makePrivateTex(.rgba16Float, w, h, [.shaderRead, .shaderWrite])
        upSP = makePrivateTex(.rgba16Float, w, h, [.shaderRead, .shaderWrite])
        upAux = makePrivateTex(.rgba16Float, w, h, [.shaderRead, .shaderWrite])
    }

    private func updatePalette(_ g: GraphicsSettings) {
        let key = SIMD3<Float>(Float(g.paletteSaturation), Float(g.paletteHue), 1)
        if key == paletteKey && paletteGeneration == session.romGeneration { return }
        paletteKey = key
        paletteGeneration = session.romGeneration
        var rgb = [Float](repeating: 0, count: 192)
        nes_build_palette(&rgb, Float(g.paletteSaturation), Float(g.paletteHue), 1, 0, 2.2)
        if let nes = session.emulator.nes { nes_set_palette(nes, rgb) }
        let p = paletteBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: 64)
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        for i in 0..<64 {
            p[i] = SIMD4<Float>(lin(rgb[i * 3]), lin(rgb[i * 3 + 1]), lin(rgb[i * 3 + 2]), 1)
        }
    }

    private func uploadFrame(_ nes: OpaquePointer) {
        guard let bg = nes_layer_bg(nes), let sp = nes_layer_spr(nes),
              let fb = nes_framebuffer(nes), let bd = nes_layer_backdrop(nes) else { return }
        layerScratch.withUnsafeMutableBufferPointer { buf in
            for i in 0..<(256 * 240) {
                buf[2 * i] = bg[i]
                buf[2 * i + 1] = sp[i]
            }
        }
        let region = MTLRegionMake2D(0, 0, 256, 240)
        layerTex.replace(region: region, mipmapLevel: 0, withBytes: layerScratch, bytesPerRow: 512)
        fbTex.replace(region: region, mipmapLevel: 0, withBytes: fb, bytesPerRow: 1024)
        memcpy(backdropBuf.contents(), bd, 240)
    }

    // MARK: Layout

    private func gameRect(in size: CGSize, g: GraphicsSettings, crop: Float) -> SIMD4<Float> {
        let sw = Float(size.width), sh = Float(size.height)
        let visible = 240 - 2 * crop
        let aspect = (g.aspect == .ntsc ? 256.0 * 8.0 / 7.0 : 256.0) / visible
        var w = min(sw, sh * aspect)
        var h = w / aspect
        if g.integerScaling {
            let s = floorf(h / visible)
            if s >= 1 { h = s * visible; w = h * aspect }
        }
        return SIMD4<Float>(floorf((sw - w) / 2), floorf((sh - h) / 2), w, h)
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? GameSession.frameTime : min(0.1, now - lastTime)
        lastTime = now
        let g = SettingsStore.shared.graphics

        if lastVSync != g.vsync, let layer = view.layer as? CAMetalLayer {
            layer.displaySyncEnabled = g.vsync
            lastVSync = g.vsync
        }

        session.tick(dt: dt)

        fpsCount += 1
        if now - fpsStamp >= 1.0 {
            if g.showFPS { session.fps = Int(Double(fpsCount) / (now - fpsStamp) + 0.5) }
            fpsCount = 0
            fpsStamp = now
        }

        inflight.wait()
        updatePalette(g)
        if let nes = session.emulator.nes { uploadFrame(nes) }

        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }

        let drawableSize = view.drawableSize
        guard drawableSize.width >= 1, drawableSize.height >= 1 else { cmd.commit(); return }
        let rs = max(0.25, min(2.0, g.renderScale))
        let sw = max(1, Int(drawableSize.width * rs)), sh = max(1, Int(drawableSize.height * rs))
        ensureSceneTargets(width: sw, height: sh)
        guard let scene = sceneTex else { cmd.commit(); return }

        let crop: Float = g.cropOverscan ? 8 : 0
        let rect = gameRect(in: CGSize(width: sw, height: sh), g: g, crop: crop)
        let mode: Float = g.mode == .remastered ? 0 : (g.mode == .classic ? 1 : 2)

        // 1. mipmaps for the ambient border glow
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: fbTex)
            blit.endEncoding()
        }

        // 2. remastered reconstruction
        var scale: Float = 1
        if g.mode == .remastered {
            let auto = Int(ceilf(rect.w / (240 - 2 * crop)))
            let s = max(2, min(g.quality.maxScale, auto))
            ensureUpscaleTargets(scale: s)
            scale = Float(s)
            if let upBG, let upSP, let upAux, let enc = cmd.makeComputeCommandEncoder() {
                enc.setTexture(layerTex, index: 0)
                enc.setTexture(auxTex, index: 1)
                dispatch(enc, heightPipeline, 256, 240)

                enc.setTexture(layerTex, index: 0)
                enc.setTexture(auxTex, index: 1)
                enc.setTexture(upBG, index: 2)
                enc.setTexture(upSP, index: 3)
                enc.setTexture(upAux, index: 4)
                enc.setBuffer(paletteBuf, offset: 0, index: 0)
                let sigma = Float(max(0.3, min(0.8, g.edgeSmoothing)))
                let sharpness = Float(max(0.25, g.edgeSharpness))
                let edge = min(0.45, 0.6 / scale / sharpness)
                var up = SIMD4<Float>(scale, sigma, edge, 0)
                enc.setBytes(&up, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                dispatch(enc, upscalePipeline, 256 * s, 240 * s)
                enc.endEncoding()
            }
        }

        // 3. scene
        var su = SceneUniforms()
        su.view = SIMD4<Float>(Float(sw), Float(sh), Float(now - startTime), mode)
        su.rect = rect
        su.style = SIMD4<Float>(g.background == .original ? 0 : (g.background == .aurora ? 1 : 2),
                                g.border == .ambient ? 1 : 0, Float(g.particles), crop)
        su.light = SIMD4<Float>(Float(g.lighting), Float(g.specular), Float(g.shadows), Float(g.rimLight))
        su.crt = SIMD4<Float>(Float(g.crtScanlines), Float(g.crtMask), Float(g.crtCurvature), g.sharpPixels ? 1 : 0)
        let ang = Float(g.lightAngle) * .pi / 180
        su.extra = SIMD4<Float>(cosf(ang) * 0.75, sinf(ang) * 0.75, scale, 0)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = scene
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(scenePipeline)
            enc.setFragmentTexture(fbTex, index: 0)
            let useUp = g.mode == .remastered
            enc.setFragmentTexture(useUp ? upBG : fbTex, index: 1)
            enc.setFragmentTexture(useUp ? upSP : fbTex, index: 2)
            enc.setFragmentTexture(useUp ? upAux : fbTex, index: 3)
            enc.setFragmentBytes(&su, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            enc.setFragmentBuffer(paletteBuf, offset: 0, index: 1)
            enc.setFragmentBuffer(backdropBuf, offset: 0, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 4. bloom
        let bloomOn = g.bloom && g.bloomIntensity > 0 && !bloomDown.isEmpty
        if bloomOn, let enc = cmd.makeComputeCommandEncoder() {
            var params = SIMD4<Float>(Float(g.bloomThreshold), 0.25, 0, 0)
            for i in 0..<bloomDown.count {
                enc.setTexture(i == 0 ? scene : bloomDown[i - 1], index: 0)
                enc.setTexture(bloomDown[i], index: 1)
                params.x = i == 0 ? Float(g.bloomThreshold) : -1
                enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                dispatch(enc, bloomDownPipeline, bloomDown[i].width, bloomDown[i].height)
            }
            let last = bloomDown.count - 1
            var upParams = SIMD4<Float>(1, 0, 0, 0)
            for i in stride(from: last, through: 0, by: -1) {
                let low = i == last ? bloomDown[last] : bloomUp[i + 1]
                enc.setTexture(low, index: 0)
                enc.setTexture(bloomDown[i], index: 1)
                enc.setTexture(bloomUp[i], index: 2)
                upParams.x = i == last ? 0 : 1
                enc.setBytes(&upParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                dispatch(enc, bloomUpPipeline, bloomUp[i].width, bloomUp[i].height)
            }
            enc.endEncoding()
        }

        // 5. composite
        guard let drawable = view.currentDrawable, let finalPass = view.currentRenderPassDescriptor else {
            cmd.commit(); return
        }
        var pu = PostUniforms()
        pu.a = SIMD4<Float>(Float(g.exposure), Float(g.bloomIntensity), Float(g.vignette), Float(g.chromaticAberration))
        pu.b = SIMD4<Float>(Float(g.filmGrain), Float(g.saturation), Float(g.contrast), Float(now - startTime))
        pu.c = SIMD4<Float>(g.tonemapping ? 1 : 0, bloomOn ? 1 : 0, 0, 0)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: finalPass) {
            enc.setRenderPipelineState(compositePipeline)
            enc.setFragmentTexture(scene, index: 0)
            enc.setFragmentTexture(bloomOn ? bloomUp[0] : scene, index: 1)
            enc.setFragmentBytes(&pu, length: MemoryLayout<PostUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(p)
        let tw = 8, th = 8
        enc.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}
