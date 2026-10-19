import AppKit
import Metal
import QuartzCore
import simd

/// Must match `struct Uniforms` in Shaders/00_Common.msl (4 × float4, then 20 floats = 144 bytes).
struct Uniforms {
    var c0 = SIMD4<Float>(), c1 = SIMD4<Float>(), c2 = SIMD4<Float>(), c3 = SIMD4<Float>()
    var resX: Float = 0, resY: Float = 0, time: Float = 0, flow: Float = 0
    var beat: Float = 0, beatCount: Float = 0, bass: Float = 0, mid: Float = 0
    var treble: Float = 0, energy: Float = 0, artMix: Float = 1, sensitivity: Float = 1
    var modeTime: Float = 0, transition: Float = 1, particleSide: Float = 0, dt: Float = 0
    var hit: Float = 0, beatPhase: Float = 0, tempoLock: Float = 0, reserved: Float = 0
}

/// Where the renderer gets its audio from.
protocol AudioFeed: AnyObject {
    /// Mid, (L+R)/2.
    var ring: SampleRingBuffer { get }
    /// Side, (L−R)/2 — tells centred sounds (usually the voice) from ones spread across the stereo field.
    var sideRing: SampleRingBuffer { get }
    var sampleRate: Double { get }
}

extension AudioTap: AudioFeed {}

/// Spotify's playback position, anchored to a host time so it can be read at any instant.
struct PlaybackClock: Equatable {
    var trackID = ""
    var position = 0.0
    var hostTime = 0.0
    var playing = false
    func position(at t: Double) -> Double { playing ? position + (t - hostTime) : position }
}

/// Owns all GPU state. After start-up every method runs on the render thread; other threads
/// talk to it through `post { }`, which is applied at the start of the next frame.
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var modePipelines: [VisualMode: MTLRenderPipelineState] = [:]
    private var particlePipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!
    private var lyricPipelines: [LyricTheme: MTLRenderPipelineState] = [:]

    private static let sceneFormat = MTLPixelFormat.rgba16Float
    static let outputFormat = MTLPixelFormat.bgra8Unorm

    private var targets: [MTLTexture] = []
    private var frozen: MTLTexture?
    private var current = 0
    private var targetKey = SIMD3<Float>(0, 0, 0)
    private var renderScale: Float = 1

    private var art: MTLTexture!
    private var prevArt: MTLTexture!
    private var artMix: Float = 1
    private var palette = Palette.aura
    private var prevPalette = Palette.aura

    /// Three of each, used round-robin: the GPU may still be reading last frame's copy.
    private let spectrumTextures: [MTLTexture]
    private let waveTextures: [MTLTexture]
    private var texSlot = 0
    private var spectrumTex: MTLTexture { spectrumTextures[texSlot] }
    private var waveTex: MTLTexture { waveTextures[texSlot] }
    /// At most three frames in flight, so a rotated resource is always free to rewrite.
    private let inFlight = DispatchSemaphore(value: 3)
    private var spectrumBytes = [Float16](repeating: 0, count: AudioAnalyzer.bandCount * 2)
    private var waveBytes = [Float16](repeating: 0, count: AudioAnalyzer.waveCount)

    let analyzer = AudioAnalyzer()
    let lyrics: LyricsLayer
    weak var feed: AudioFeed?

    private(set) var mode: VisualMode = .halo
    private var sensitivity: Float = 1
    private var playback = PlaybackClock()
    private var hudVisible = true

    private var time: Double = 0
    private var modeStart: Double = 0
    private var transition: Float = 1
    private var freezePending = false
    private let particleSide = 180
    private var lastDT: Float = 1.0 / 60
    private var lastFrameTime: Double = 0
    private var lastPresentTime: Double = 0

    // Cross-thread plumbing
    private let inboxLock = NSLock()
    private var inbox: [(Renderer) -> Void] = []
    struct Stats {
        var features = AudioAnalyzer.Features()
        var fps = 0.0, slowFrames = 0, gpuMs = 0.0, scale: Float = 1, bubbles = 0, presentMs = 0.0
        var lyricTrack = "", lyricOffset = 0.0, lyricLearned: Double?, lyricSamples = 0, lyricManual: Double?
        var vocalLines = -1.0, vocalGaps = -1.0, songRate = 0.0, wordsShown = 0, wordsSkipped = 0
    }
    private let statsLock = NSLock()
    private var sharedStats = Stats()
    private var frameCount = 0, slowCount = 0, windowStart = 0.0
    private var gpuAccum = 0.0, gpuSamples = 0
    private var captureNext = false
    /// Live ring pulses (sample they started, strength), newest last; ≤ 8.
    private var rings: [(sample: Double, strength: Float)] = []
    private var ringBytes = [Float](repeating: 0, count: 24)
    private var ringSettings = RingSettings()
    private var lastRingTime: Double = 0

    /// Live readout for the Rings settings meter.
    struct RingMeter {
        struct Trigger { var id: UUID; var level: Float; var jump: Float; var needLevel: Float; var needJump: Float; var remembered: Int }
        var triggers: [Trigger] = []
        var ringsLaunched = 0
        var lastRingTime: Double = 0
    }
    private let meterLock = NSLock()
    private var sharedMeter = RingMeter()
    var ringMeter: RingMeter { meterLock.lock(); defer { meterLock.unlock() }; return sharedMeter }
    private var presentAccum = 0.0

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(), let lyrics = LyricsLayer(device: device) else { return nil }
        self.device = device
        self.queue = queue
        self.lyrics = lyrics
        precondition(MemoryLayout<Uniforms>.stride == 144, "Uniforms layout drifted from the shader")

        let specDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: AudioAnalyzer.bandCount,
                                                                height: 1, mipmapped: false)
        let waveDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: AudioAnalyzer.waveCount,
                                                                height: 1, mipmapped: false)
        let specs = (0..<3).compactMap { _ in device.makeTexture(descriptor: specDesc) }
        let waves = (0..<3).compactMap { _ in device.makeTexture(descriptor: waveDesc) }
        guard specs.count == 3, waves.count == 3 else { return nil }
        spectrumTextures = specs
        waveTextures = waves

        do { try buildPipelines() } catch {
            NSLog("Aura: shader build failed: \(error)")
            return nil
        }
        guard let placeholder = makeArtTexture(Placeholder.cover) else { return nil }
        art = placeholder
        prevArt = placeholder
        palette = PaletteExtractor.extract(from: Placeholder.cover)
        prevPalette = palette
    }

    // MARK: Setup

    private func buildPipelines() throws {
        let library = try device.makeLibrary(source: try Self.shaderSource(), options: nil)
        let vertex = library.makeFunction(name: "vFullscreen")

        func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vertex
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        for mode in VisualMode.allCases {
            modePipelines[mode] = try pipeline(mode.fragmentName, format: Self.sceneFormat)
        }
        compositePipeline = try pipeline("fComposite", format: Self.outputFormat)

        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = library.makeFunction(name: "vStardust")
        p.fragmentFunction = library.makeFunction(name: "fStardust")
        p.colorAttachments[0].pixelFormat = Self.sceneFormat
        p.colorAttachments[0].isBlendingEnabled = true
        p.colorAttachments[0].sourceRGBBlendFactor = .one
        p.colorAttachments[0].destinationRGBBlendFactor = .one
        p.colorAttachments[0].sourceAlphaBlendFactor = .zero
        p.colorAttachments[0].destinationAlphaBlendFactor = .one
        particlePipeline = try device.makeRenderPipelineState(descriptor: p)

        for theme in LyricTheme.allCases {
            let b = MTLRenderPipelineDescriptor()
            b.vertexFunction = library.makeFunction(name: theme.vertexFunction)
            b.fragmentFunction = library.makeFunction(name: theme.fragmentFunction)
            b.colorAttachments[0].pixelFormat = Self.outputFormat
            b.colorAttachments[0].isBlendingEnabled = true
            b.colorAttachments[0].sourceRGBBlendFactor = .one
            b.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            b.colorAttachments[0].sourceAlphaBlendFactor = .one
            b.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            lyricPipelines[theme] = try device.makeRenderPipelineState(descriptor: b)
        }
    }

    static func shaderSource() throws -> String {
        guard let dir = Bundle.main.url(forResource: "Shaders", withExtension: nil) else {
            throw NSError(domain: "Aura", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shaders folder missing"])
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "msl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    // MARK: Cross-thread API (safe from any thread)

    func post(_ job: @escaping (Renderer) -> Void) {
        inboxLock.lock(); inbox.append(job); inboxLock.unlock()
    }

    var stats: Stats { statsLock.lock(); defer { statsLock.unlock() }; return sharedStats }

    func setMode(_ m: VisualMode) { post { $0.applyMode(m) } }
    func setSensitivity(_ s: Float) { post { $0.sensitivity = s; $0.analyzer.sensitivity = s } }
    func setSyncOffset(_ seconds: Double) { post { $0.analyzer.syncOffset = seconds } }
    func setPlayback(_ clock: PlaybackClock) { post { $0.playback = clock } }
    /// New song's lyrics plus what Aura already knows about their timing.
    func setLyrics(_ l: Lyrics?, manualOffset: Double? = nil, learnedOffset: Double? = nil, priorOffset: Double = 0) {
        post {
            $0.lyrics.priorOffset = priorOffset
            $0.lyrics.setLyrics(l)
            $0.lyrics.manualOffset = manualOffset
            $0.lyrics.seedAutoOffset(learnedOffset)
        }
    }
    func setLyricsEnabled(_ on: Bool) { post { $0.lyrics.enabled = on } }
    func setLyricTheme(_ t: LyricTheme) { post { $0.lyrics.setTheme(t) } }
    func setLyricsWordByWord(_ on: Bool) { post { $0.lyrics.wordByWord = on } }
    /// New song: drop everything the analyser learned about the last one.
    func trackChanged() { post { $0.analyzer.trackChanged() } }
    /// Shifts this song's lyrics (positive = later). Reports the new manual offset on the main queue.
    func nudgeLyrics(by delta: Double, completion: @escaping (Double) -> Void) {
        post { r in
            let value = max(-3, min(3, (r.lyrics.manualOffset ?? r.lyrics.offset) + delta))
            r.lyrics.manualOffset = (value * 20).rounded() / 20
            let result = r.lyrics.manualOffset ?? 0
            DispatchQueue.main.async { completion(result) }
        }
    }
    func clearLyricNudge() { post { $0.lyrics.manualOffset = nil } }
    func setDetectedGenre(_ g: RingSettings.Genre?) { post { $0.analyzer.detectedGenre = g } }
    func setRingSettings(_ s: RingSettings) {
        post { r in
            r.ringSettings = s
            r.analyzer.ringSettings = s
        }
    }
    func setHUDVisible(_ on: Bool) { post { $0.hudVisible = on } }
    func requestCapture() { post { $0.captureNext = true } }

    /// Decodes on the calling thread, swaps on the render thread.
    func setArtwork(_ image: CGImage?, palette newPalette: Palette?) {
        guard let texture = makeArtTexture(image ?? Placeholder.cover) else { return }
        let resolved = newPalette ?? PaletteExtractor.extract(from: Placeholder.cover)
        post { r in
            r.prevPalette = r.prevPalette.mixed(to: r.palette, ease(r.artMix))
            r.prevArt = r.artMix < 0.5 ? r.prevArt : r.art
            r.art = texture
            r.palette = resolved
            r.artMix = 0
        }
    }

    private func applyMode(_ m: VisualMode) {
        guard m != mode else { return }
        mode = m
        freezePending = true
        transition = 0
        modeStart = time
    }

    private func drainInbox() {
        inboxLock.lock()
        let jobs = inbox
        inbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()
        for job in jobs { job(self) }
    }

    // MARK: Frame

    /// Render-thread entry point from the display link.
    func render(drawable: CAMetalDrawable, presentTime: Double) {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 60 : min(now - lastFrameTime, 0.1)
        let expected = lastPresentTime == 0 ? 1.0 / 60 : max(presentTime - lastPresentTime, 1.0 / 240)
        lastFrameTime = now
        lastPresentTime = presentTime
        presentAccum += presentTime - now

        inFlight.wait()
        step(dt: dt, presentTime: presentTime)

        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let pass = outputPass(drawable.texture)
        guard let (scene, u) = encodeScene(cb, outputSize: size) else { inFlight.signal(); return }
        encodeOutput(cb, pass: pass, scene: scene, uniforms: u, size: size)

        if captureNext {
            captureNext = false
            capture(cb, scene: scene, uniforms: u, size: size)
        }

        cb.addCompletedHandler { [weak self, inFlight] buffer in
            self?.recordGPU(buffer.gpuEndTime - buffer.gpuStartTime)
            inFlight.signal()
        }
        cb.present(drawable)
        cb.commit()
        recordFrame(now: now, dt: dt, expected: expected)
    }

    /// Advances input, analysis, animation and lyrics to the moment `presentTime`.
    func step(dt: Double, presentTime: Double) {
        drainInbox()
        time += dt
        lastDT = Float(dt)
        if let feed {
            analyzer.update(presentTime: presentTime, dt: dt, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
        }
        artMix = min(artMix + Float(dt / 1.4), 1)
        transition = min(transition + Float(dt / 0.9), 1)

        // Ring pulses: each one ages on its own, so several can be on screen at once.
        if let rate = feed?.sampleRate {
            rings.append(contentsOf: analyzer.ringEventsThisFrame)
            let v = analyzer.visualSample
            let life = ringSettings.lifetime
            rings.removeAll { (v - $0.sample) / rate > life + 0.05 }
            let cap = min(max(ringSettings.maxRings, 1), 8)
            if rings.count > cap { rings.removeFirst(rings.count - cap) }
            for k in 0..<8 {
                if k < rings.count {
                    ringBytes[k * 2] = Float((v - rings[k].sample) / rate)
                    ringBytes[k * 2 + 1] = rings[k].strength
                } else {
                    ringBytes[k * 2] = -1
                    ringBytes[k * 2 + 1] = 0
                }
            }
            ringBytes[16] = Float(rings.count)
            ringBytes[17] = Float(life)
            ringBytes[18] = Float(ringSettings.thickness)
            ringBytes[19] = Float(ringSettings.brightness)
            ringBytes[20] = ringSettings.colour.shaderValue

            if !analyzer.ringEventsThisFrame.isEmpty { lastRingTime = CACurrentMediaTime() }
            meterLock.lock()
            sharedMeter = RingMeter(triggers: analyzer.ringDetectors.map {
                                        .init(id: $0.id, level: $0.level, jump: $0.jumpNow,
                                              needLevel: Float($0.rule.loudness), needJump: Float($0.rule.jump), remembered: $0.remembered)
                                    },
                                    ringsLaunched: analyzer.features.ringsLaunched, lastRingTime: lastRingTime)
            meterLock.unlock()
        }

        texSlot = (texSlot + 1) % spectrumTextures.count
        let bands = analyzer.bands, peaks = analyzer.peaks, wave = analyzer.wave
        for i in 0..<AudioAnalyzer.bandCount {
            spectrumBytes[i * 2] = Float16(bands[i])
            spectrumBytes[i * 2 + 1] = Float16(peaks[i])
        }
        for i in 0..<AudioAnalyzer.waveCount { waveBytes[i] = Float16(max(-4, min(4, wave[i]))) }
        spectrumBytes.withUnsafeBytes {
            spectrumTex.replace(region: MTLRegionMake2D(0, 0, AudioAnalyzer.bandCount, 1), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: AudioAnalyzer.bandCount * 4)
        }
        waveBytes.withUnsafeBytes {
            waveTex.replace(region: MTLRegionMake2D(0, 0, AudioAnalyzer.waveCount, 1), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: AudioAnalyzer.waveCount * 2)
        }

        // Lyrics follow the song position of the audio being heard at presentTime.
        let f = analyzer.features
        var songTime: Double?
        if !playback.trackID.isEmpty {
            var lag = 0.03
            if let stamp = feed?.ring.stamp() { lag = max(0, stamp.heardAt - stamp.writtenAt) }
            songTime = playback.position(at: presentTime - lag - analyzer.syncOffset)
        }
        let targetStage: Float = hudVisible ? 0.25 : 0.32
        lyrics.stageY += (targetStage - lyrics.stageY) * Float(min(1, dt * 4))
        let aspect = targetKey.x > 0 ? targetKey.x / max(targetKey.y, 1) : 1.6
        var voice: [(time: Double, strength: Float)] = []
        if let songTime, let rate = feed?.sampleRate {
            let heardNow = analyzer.visualSample - analyzer.visualLead * rate
            for o in analyzer.voiceOnsetsThisFrame { voice.append((songTime + (o.sample - heardNow) / rate, o.strength)) }
        }
        var singingNow: Float = 0, singingSoon: Float = 0
        let lead = lyrics.theme.appearLead
        lyrics.lead = lead
        analyzer.voiceLead = lead
        if let rate = feed?.sampleRate {
            let aim = analyzer.visualSample + (lead - analyzer.visualLead) * rate
            singingNow = analyzer.vocalActivity(atSample: aim)
            singingSoon = analyzer.vocalActivityMax(from: aim - 0.08 * rate, to: aim + 0.08 * rate)
        }
        lyrics.update(songTime: songTime, voiceOnsets: voice, singingNow: singingNow, singingSoon: singingSoon, dt: dt, aspect: aspect,
                      beat: f.beat, beatCount: f.beatCount, bass: f.bass)
    }

    private func uniforms(width: Int, height: Int) -> Uniforms {
        let f = analyzer.features
        let pal = prevPalette.mixed(to: palette, ease(artMix))
        var u = Uniforms()
        u.c0 = SIMD4(pal.primary, 1); u.c1 = SIMD4(pal.secondary, 1)
        u.c2 = SIMD4(pal.accent, 1); u.c3 = SIMD4(pal.shadow, 1)
        u.resX = Float(width); u.resY = Float(height)
        u.time = Float(time.truncatingRemainder(dividingBy: 16384)); u.flow = f.flow
        u.beat = f.beat; u.beatCount = Float(f.beatCount)
        u.bass = f.bass; u.mid = f.mid; u.treble = f.treble; u.energy = f.energy
        u.artMix = ease(artMix); u.sensitivity = sensitivity
        u.modeTime = Float((time - modeStart).truncatingRemainder(dividingBy: 16384)); u.transition = transition
        u.particleSide = Float(particleSide); u.dt = lastDT
        u.hit = f.hit; u.beatPhase = f.beatPhase; u.tempoLock = f.tempoLock
        return u
    }

    private func outputPass(_ texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// Renders the current mode into the ping-pong scene texture.
    func encodeScene(_ cb: MTLCommandBuffer, outputSize size: CGSize) -> (MTLTexture, Uniforms)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let key = SIMD3(Float(size.width), Float(size.height), renderScale)
        if key != targetKey || targets.count != 2 { rebuildTargets(for: size) }
        guard targets.count == 2 else { return nil }

        if freezePending, let frozen {
            freezePending = false
            if let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: targets[current], to: frozen)
                blit.endEncoding()
            }
            clear(targets, in: cb)
        }
        if lyrics.atlasNeedsMipmaps, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: lyrics.atlas)
            blit.endEncoding()
            lyrics.mipmapsGenerated()
        }

        let src = targets[current], dst = targets[1 - current]
        var u = uniforms(width: dst.width, height: dst.height)
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = dst
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        scenePass.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: scenePass) {
            enc.setRenderPipelineState(modePipelines[mode]!)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(prevArt, index: 0)
            enc.setFragmentTexture(art, index: 1)
            enc.setFragmentTexture(spectrumTex, index: 2)
            enc.setFragmentTexture(waveTex, index: 3)
            enc.setFragmentTexture(src, index: 4)
            enc.setFragmentBytes(&ringBytes, length: MemoryLayout<Float>.stride * ringBytes.count, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if mode == .stardust {
                enc.setRenderPipelineState(particlePipeline)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setVertexTexture(prevArt, index: 0)
                enc.setVertexTexture(art, index: 1)
                enc.setVertexTexture(spectrumTex, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: particleSide * particleSide)
            }
            enc.endEncoding()
        }
        current = 1 - current
        return (dst, u)
    }

    /// Composite + lyric bubbles into an output texture (the screen, or a capture).
    func encodeOutput(_ cb: MTLCommandBuffer, pass: MTLRenderPassDescriptor, scene: MTLTexture,
                      uniforms: Uniforms, size: CGSize) {
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var cu = uniforms
        cu.resX = Float(size.width); cu.resY = Float(size.height)
        enc.setRenderPipelineState(compositePipeline)
        enc.setFragmentBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(frozen ?? scene, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if lyrics.instanceCount > 0 {
            enc.setRenderPipelineState(lyricPipelines[lyrics.theme]!)
            enc.setVertexBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(lyrics.instances, offset: 0, index: 1)
            enc.setFragmentBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(scene, index: 0)
            enc.setFragmentTexture(lyrics.atlas, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: lyrics.instanceCount)
        }
        enc.endEncoding()
    }

    private func clear(_ textures: [MTLTexture], in cb: MTLCommandBuffer) {
        for t in textures {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    private func rebuildTargets(for size: CGSize) {
        targetKey = SIMD3(Float(size.width), Float(size.height), renderScale)
        let cap = min(1.0, 1440.0 / Double(size.height))
        let scale = Double(renderScale) * cap
        let w = max(Int(size.width * scale), 16), h = max(Int(size.height * scale), 16)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.sceneFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        targets = (0..<2).compactMap { _ in device.makeTexture(descriptor: desc) }
        frozen = device.makeTexture(descriptor: desc)
        current = 0
        if let cb = queue.makeCommandBuffer() {
            clear(targets + [frozen].compactMap { $0 }, in: cb)
            cb.commit()
        }
    }

    // MARK: Stats + adaptive resolution

    private func recordFrame(now: Double, dt: Double, expected: Double) {
        frameCount += 1
        if dt > expected * 1.6 { slowCount += 1 }
        if windowStart == 0 { windowStart = now }
        guard now - windowStart >= 2 else { return }
        let fps = Double(frameCount) / (now - windowStart)
        gpuLock.lock()
        let gpuMs = gpuSamples > 0 ? gpuAccum / Double(gpuSamples) * 1000 : 0
        let gpuSamples = self.gpuSamples
        gpuAccum = 0; self.gpuSamples = 0
        gpuLock.unlock()
        // Keep GPU time under ~70% of the frame budget.
        if gpuSamples > 0 {
            if gpuMs > expected * 1000 * 0.7 { renderScale = max(0.5, renderScale * 0.85) }
            else if gpuMs < expected * 1000 * 0.35 { renderScale = min(1.0, renderScale * 1.08) }
        }
        statsLock.lock()
        sharedStats = Stats(features: analyzer.features, fps: fps, slowFrames: slowCount, gpuMs: gpuMs,
                            scale: renderScale, bubbles: lyrics.instanceCount,
                            presentMs: presentAccum / Double(max(frameCount, 1)) * 1000,
                            lyricTrack: lyrics.lyrics?.trackID ?? "", lyricOffset: lyrics.offset,
                            lyricLearned: lyrics.learner.estimate, lyricSamples: lyrics.learner.samples.count,
                            lyricManual: lyrics.manualOffset,
                            vocalLines: lyrics.vocalInLines.count > 60 ? lyrics.vocalInLines.sum / Double(lyrics.vocalInLines.count) : -1,
                            vocalGaps: lyrics.vocalInGaps.count > 60 ? lyrics.vocalInGaps.sum / Double(lyrics.vocalInGaps.count) : -1,
                            songRate: lyrics.songRate, wordsShown: lyrics.wordsShown, wordsSkipped: lyrics.wordsSkipped)
        statsLock.unlock()
        presentAccum = 0
        frameCount = 0; slowCount = 0; windowStart = now
    }

    private let gpuLock = NSLock()
    private func recordGPU(_ seconds: Double) {
        guard seconds > 0 else { return }
        gpuLock.lock(); gpuAccum += seconds; gpuSamples += 1; gpuLock.unlock()
    }

    /// Updates just the feature snapshot (used when rendering off-screen).
    func publishFeatures() {
        statsLock.lock(); sharedStats.features = analyzer.features; statsLock.unlock()
    }

    // MARK: Capture (kill -USR1 <pid> → ~/Library/Logs/Aura/capture.png)

    private func capture(_ cb: MTLCommandBuffer, scene: MTLTexture, uniforms: Uniforms, size: CGSize) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.outputFormat, width: Int(size.width),
                                                            height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        encodeOutput(cb, pass: outputPass(tex), scene: scene, uniforms: uniforms, size: size)
        cb.addCompletedHandler { _ in
            guard let image = Renderer.cgImage(from: tex) else { return }
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Aura/capture.png")
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                DiagnosticsLog.write("frame captured → \(url.path)")
            }
        }
    }

    static func cgImage(from tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Art textures

    func makeArtTexture(_ image: CGImage) -> MTLTexture? {
        let side = 640
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        if let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = CGFloat(side) / min(iw, ih)
            ctx.draw(image, in: CGRect(x: (CGFloat(side) - iw * s) / 2, y: (CGFloat(side) - ih * s) / 2,
                                       width: iw * s, height: ih * s))
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: true)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return texture
    }

    // MARK: Off-screen (snapshots)

    private var offscreen: MTLTexture?

    func renderOffscreen(width: Int, height: Int, readback: Bool) -> CGImage? {
        if offscreen?.width != width || offscreen?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.outputFormat, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            offscreen = device.makeTexture(descriptor: desc)
        }
        guard let out = offscreen, let cb = queue.makeCommandBuffer() else { return nil }
        let size = CGSize(width: width, height: height)
        guard let (scene, u) = encodeScene(cb, outputSize: size) else { return nil }
        encodeOutput(cb, pass: outputPass(out), scene: scene, uniforms: u, size: size)
        cb.commit()
        cb.waitUntilCompleted()
        return readback ? Self.cgImage(from: out) : nil
    }
}

private func ease(_ t: Float) -> Float {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}
