import Foundation
import simd

/// Per-style movement, particles and the per-frame GPU instance list.
extension LyricsLayer {
    // MARK: Motion

    func simulate(dt: Float, beat: Float, beatCount: Int) {
        let kick = beatCount != lastBeatCount
        lastBeatCount = beatCount

        for i in words.indices {
            var w = words[i]
            let age = self.age(of: w)
            let popping = w.popAt != .infinity && clock >= w.popAt
            switch theme {
            case .bubbles:
                let shown = Self.bubbleScale(age)
                if songAdvancing { w.drift = min(w.drift + dt * 0.012, 0.05) }
                var acc = (w.home - SIMD2(0, w.drift) - w.pos) * 16 - w.vel * 5.5
                if kick, shown > 0.5 {
                    acc += SIMD2(Float.random(in: -1...1, using: &rng),
                                 -0.6 - Float.random(in: 0...0.6, using: &rng)) * 9 * beat
                }
                w.vel += acc * dt
                w.pos += w.vel * dt
            case .stickers:
                var acc = (w.home - w.pos) * 70 - w.vel * 10
                if kick, age > 0.3 { acc.y -= 6 * beat }
                w.vel += acc * dt
                w.pos += w.vel * dt
            case .cinema:
                if songAdvancing, age > 0 { w.drift = min(w.drift + dt * 0.008, 0.035) }
                w.pos = w.home - SIMD2(0, w.drift)
            case .embers:
                w.pos = w.home
                if age >= 0, age < 0.8, !popping { emitSparks(from: &w, rate: 24 * (1 - age / 0.8), dt: dt, burst: false) }
                if popping, clock < w.popAt + theme.popDuration * 0.8 { emitSparks(from: &w, rate: 80, dt: dt, burst: true) }
            case .karaoke, .neon:
                w.pos = w.home
            }
            words[i] = w
        }

        if theme == .bubbles {
            relaxBubbles()
            popBubbles()
        }

        for i in particles.indices {
            if theme == .embers {
                particles[i].vel.x += Float.random(in: -0.35...0.35, using: &rng) * dt
                particles[i].vel.y -= dt * 0.06                     // heat rises (−y is up)
                particles[i].vel *= exp(-dt * 0.9)
            } else {
                particles[i].vel *= exp(-dt * 3)
                particles[i].vel.y += dt * 0.25
            }
            particles[i].pos += particles[i].vel * dt
        }
        particles.removeAll { clock > $0.born + $0.life }
        if particles.count > 200 { particles.removeFirst(particles.count - 200) }
        let linger = theme.popDuration + 0.05
        words.removeAll { clock > $0.popAt + linger }
    }

    func age(of w: Word) -> Float { w.appearAt != nil ? Float(clock - w.appearClock) : -1 }

    static func bubbleScale(_ age: Float) -> Float {
        age <= 0 ? 0 : max(0, 1 - exp(-age * 7.5) * cos(age * 11))
    }

    private func emitSparks(from w: inout Word, rate: Float, dt: Float, burst: Bool) {
        w.sparkAccum += rate * dt
        let halfW = w.size * w.aspect * 0.75, halfH = w.size * 0.55
        while w.sparkAccum >= 1 {
            w.sparkAccum -= 1
            let x = w.pos.x + Float.random(in: -halfW...halfW, using: &rng)
            let y = w.pos.y + (burst ? Float.random(in: -halfH...halfH, using: &rng)
                                     : -halfH * Float.random(in: 0.2...1, using: &rng))
            let rise: ClosedRange<Float> = burst ? 0.08...0.28 : 0.04...0.14
            particles.append(Particle(pos: SIMD2(x, y),
                                      vel: SIMD2(Float.random(in: -0.03...0.03, using: &rng), -Float.random(in: rise, using: &rng)),
                                      radius: Float.random(in: 0.0022...0.0055, using: &rng),
                                      born: clock, life: Double.random(in: 0.5...1.1, using: &rng),
                                      seed: Float.random(in: 0...1, using: &rng)))
        }
    }

    private func relaxBubbles() {
        for _ in 0..<2 {
            for i in words.indices {
                let ri = words[i].size * Self.bubbleScale(age(of: words[i]))
                guard ri > 0.01 else { continue }
                for j in (i + 1)..<words.count {
                    let rj = words[j].size * Self.bubbleScale(age(of: words[j]))
                    guard rj > 0.01 else { continue }
                    let d = words[j].pos - words[i].pos
                    let dist = max(simd_length(d), 1e-4)
                    let overlap = ri + rj + 0.006 - dist
                    if overlap > 0 {
                        let push = d / dist * overlap * 0.5
                        words[i].pos -= push
                        words[j].pos += push
                    }
                }
            }
        }
    }

    private func popBubbles() {
        for i in words.indices where !words[i].popped && clock >= words[i].popAt {
            words[i].popped = true
            let w = words[i]
            let r = w.size * Self.bubbleScale(age(of: w))
            guard r > 0.02 else { continue }
            let n = 9 + Int(r * 60)
            for k in 0..<n {
                let a = Float(k) / Float(n) * 2 * .pi + Float.random(in: -0.3...0.3, using: &rng)
                let dir = SIMD2(cos(a), sin(a))
                particles.append(Particle(pos: w.pos + dir * r,
                                          vel: dir * Float.random(in: 0.18...0.42, using: &rng) + SIMD2(0, -0.05),
                                          radius: Float.random(in: 0.004...0.009, using: &rng), born: clock,
                                          life: Double.random(in: 0.35...0.6, using: &rng),
                                          seed: Float.random(in: 0...1, using: &rng)))
            }
        }
    }

    // MARK: GPU instances

    func writeInstances(lyricTime lt: Double?, beat: Float) {
        nextInstanceSlot()                       // never rewrite the buffer a frame in flight is reading
        let ptr = instances.contents().bindMemory(to: LyricGPU.self, capacity: maxInstances)
        var n = 0
        for w in words where n < maxInstances {
            let popT = w.popAt == .infinity ? 0 : Float(min(max((clock - w.popAt) / theme.popDuration, 0), 1))
            let age = self.age(of: w)
            var g = LyricGPU(cx: w.pos.x, cy: w.pos.y, size: w.size, alpha: 1,
                             u0: w.rect.x, v0: w.rect.y, du: w.rect.z, dv: w.rect.w,
                             textAspect: w.aspect, textScale: 1, seed: w.seed, pop: popT,
                             progress: 0, rotation: w.rotation, appear: 0, glow: beat)
            switch theme {
            case .bubbles:
                let shown = Self.bubbleScale(age)
                let scale = shown * (1 + popT * 0.22)
                guard scale > 0.01 else { continue }
                g.size = w.size * scale
                g.alpha = min(shown * 1.4, 1)
                g.textScale = theme.textHeight / max(g.size, 1e-3)
                g.appear = min(max(age / 0.3, 0), 1)
            case .karaoke:
                let enter = Float(min(max((clock - w.spawnClock) / 0.35, 0), 1))
                g.alpha = enter * (1 - popT)
                g.cy += (1 - enter) * 0.03 - popT * 0.03
                if let a = w.appearAt, let lt {
                    let fill = wordByWord ? max(w.duration * 0.9, 0.12) : 0.25
                    g.progress = Float(min(max((lt - a) / fill, 0), 1))
                    g.size *= 1 + 0.1 * sin(min(max(age / 0.25, 0), 1) * .pi)
                }
                g.appear = age < 0 ? 0 : min(age / 0.3, 1)
            case .neon:
                guard age >= 0 else { continue }
                g.appear = min(age / 0.3, 1)
            case .cinema:
                guard age >= 0 else { continue }
                g.appear = min(age / 0.5, 1)
                let e = g.appear * g.appear * (3 - 2 * g.appear)
                g.size *= 1.05 - 0.05 * e
                g.cy += (1 - e) * 0.018 - popT * 0.02
            case .embers:
                guard age >= 0 else { continue }
                g.appear = min(age / 0.35, 1)
                g.progress = min(age / 2.5, 1)
            case .stickers:
                guard age >= 0 else { continue }
                g.appear = min(age / 0.4, 1)
                g.size *= (1 + 0.6 * exp(-age * 6) * cos(age * 14)) * (1 + 0.05 * beat) * (1 - 0.25 * popT)
                g.alpha = 1 - popT * popT
                g.cy += popT * popT * 0.12
                g.rotation += popT * 0.7 * (w.seed > 0.5 ? 1 : -1)
            }
            ptr[n] = g
            n += 1
        }
        for p in particles where n < maxInstances {
            let t = Float((clock - p.born) / p.life)
            ptr[n] = LyricGPU(cx: p.pos.x, cy: p.pos.y, size: p.radius * (1 - t * 0.5), alpha: 1 - t,
                              u0: 0, v0: 0, du: 0, dv: 0, textAspect: 1, textScale: 0, seed: p.seed,
                              pop: theme == .bubbles ? t * 0.6 : t, progress: 0, rotation: 0, appear: 1, glow: 0)
            n += 1
        }
        instanceCount = n
    }
}
