import SwiftUI

struct SettingsButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        IconButton(symbol: "slider.horizontal.3", size: 30) { open.toggle() }
            .glassPanel(radius: 15)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SettingsPanel()
                    .environment(model)
            }
            .onChange(of: open) { _, isOpen in model.settingsOpen = isOpen }
            .help("Settings")
    }
}

struct SettingsPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", lyrics = "Lyrics", rings = "Rings"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    /// Off only for the snapshot renderer, which can't draw scroll views.
    var scrolls = true
    @State var tab: Tab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if scrolls {
                ScrollView(.vertical, showsIndicators: false) { content.padding(24).padding(.top, -8) }
            } else {
                content.padding(24).padding(.top, -8)
            }
        }
        .frame(width: 380, height: scrolls ? 660 : nil)
        .foregroundStyle(Tokens.ink)
        .background(Tokens.surface)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("Aura", color: Tokens.accent)
                Text("Settings").font(Tokens.serif(32))
            }
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    let on = tab == t
                    Button { withAnimation(Tokens.ease) { tab = t } } label: {
                        Text(t.rawValue)
                            .font(Tokens.sans(12.5, .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(Capsule().fill(on ? Tokens.ink : Color.clear))
                            .foregroundStyle(on ? Tokens.bg : Tokens.inkDim)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Tokens.inkFaint.opacity(0.6)))
        }
        .padding(24)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general: GeneralSettings()
        case .lyrics: LyricSettings()
        case .rings: RingSettingsView()
        }
    }
}

// MARK: - Shared pieces

private struct Section<Content: View>: View {
    let title: String
    var value: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(title)
                Spacer()
                if let value {
                    Text(value).font(Tokens.mono(11)).foregroundStyle(Tokens.ink).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            content
        }
        .tint(Tokens.accent)
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Tokens.sans(11.5)).foregroundStyle(Tokens.inkDim).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    var hint: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $isOn) { Text(title).font(Tokens.sans(13, .medium)) }
                .toggleStyle(.switch)
                .tint(Tokens.accent)
            if let hint { Hint(hint) }
        }
    }
}

private struct ChipButton: View {
    let title: String
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.sans(12, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(Capsule().fill(selected ? Tokens.ink : Tokens.inkFaint))
                .foregroundStyle(selected ? Tokens.bg : Tokens.ink)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            Section(title: "Sensitivity", value: String(format: "%.1f×", model.sensitivity)) {
                Slider(value: $model.sensitivity, in: 0.5...2)
                Hint("How hard the visuals react. Turn it up for quiet music.")
            }
            Section(title: "Listen to") {
                HStack(spacing: 6) {
                    ForEach(AudioTap.Source.allCases) { s in
                        ChipButton(title: s.label, selected: model.source == s) { model.source = s }
                    }
                }
                Hint("“All Mac audio” also reacts to YouTube, games and everything else.")
            }
            Section(title: "Change mode automatically") {
                HStack(spacing: 6) {
                    ForEach(AutoChange.allCases) { a in
                        ChipButton(title: a.label, selected: model.autoChange == a) { model.autoChange = a }
                    }
                }
            }
            Section(title: "Sync", value: "\(Int(model.syncOffsetMs)) ms") {
                Slider(value: $model.syncOffsetMs, in: -150...350, step: 10)
                Hint("Visuals ahead of the beat? Drag right. Behind it? Drag left.")
            }
            VStack(alignment: .leading, spacing: 10) {
                SwitchRow(title: "Look-ahead", isOn: $model.lookAhead,
                          hint: "Holds Spotify's sound back 60 ms on speakers and wired headphones so every beat lands exactly on time. Bluetooth already has enough delay.")
                SwitchRow(title: "Show the song title when it changes", isOn: $model.showTitleOnChange)
            }

            Rectangle().fill(Tokens.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("Keyboard")
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    shortcut("1 – 8", "Pick a mode")
                    shortcut("← →", "Previous / next mode")
                    shortcut("Space", "Play / pause")
                    shortcut("⌘← ⌘→", "Previous / next song")
                    shortcut("A", "Auto-change modes")
                    shortcut("L", "Lyrics on / off")
                    shortcut("T", "Next lyric style")
                    shortcut("[  ]", "Lyrics earlier / later")
                    shortcut("H", "Hide controls")
                    shortcut("F", "Full screen (or double-click)")
                }
            }
        }
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        GridRow {
            Text(keys).font(Tokens.mono(11, .medium)).foregroundStyle(Tokens.accent)
            Text(what).font(Tokens.sans(12)).foregroundStyle(Tokens.inkDim)
        }
    }
}

// MARK: - Lyrics

private struct LyricSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            SwitchRow(title: "Show lyrics", isOn: $model.showLyrics, hint: lyricsHint)
            Section(title: "Style") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(LyricTheme.allCases) { theme in
                        ChipButton(title: theme.title, selected: model.lyricTheme == theme) { model.lyricTheme = theme }
                            .help(theme.blurb)
                    }
                }
                Hint(model.lyricTheme.blurb)
            }
            Section(title: "Words appear") {
                HStack(spacing: 6) {
                    ChipButton(title: "Line by line", selected: !model.lyricsWordByWord) { model.lyricsWordByWord = false }
                    ChipButton(title: "Word by word", selected: model.lyricsWordByWord) { model.lyricsWordByWord = true }
                        .overlay(alignment: .topTrailing) {
                            Text("EXPERIMENTAL")
                                .font(Tokens.mono(7.5, .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Tokens.accent3))
                                .foregroundStyle(Tokens.bg)
                                .offset(x: -4, y: -8)
                        }
                }
                .padding(.top, 4)
                Hint(model.lyricsWordByWord
                     ? "Experimental: each word pops in as it's sung. Aura guesses each word's timing from the singer's voice, so some words can land a little early or late."
                     : "The whole line appears the moment it starts. The most reliable.")
            }
            Section(title: "Timing for this song", value: timingLabel) {
                HStack(spacing: 8) {
                    pill("Earlier", symbol: "minus") { model.nudgeLyrics(-0.1) }
                    pill("Later", symbol: "plus") { model.nudgeLyrics(0.1) }
                    Spacer()
                    Button("Automatic") { model.resetLyricTiming() }
                        .buttonStyle(.plain)
                        .font(Tokens.sans(12, .semibold))
                        .foregroundStyle(model.lyricNudge == nil ? Tokens.inkDim : Tokens.accent)
                        .disabled(model.lyricNudge == nil)
                }
                Hint("Words early? Tap Later (or press ]). It's remembered for this song and helps every other song start closer.")
            }
        }
    }

    private var timingLabel: String {
        if let n = model.lyricNudge { return String(format: "%+.2f s", n) }
        if let l = model.lyricLearned, abs(l) >= 0.05 { return String(format: "Auto %+.2f s", l) }
        return "Auto"
    }

    private var lyricsHint: String {
        switch model.lyricsStatus {
        case .synced(let n): return "\(n) timed lines for this song, from LRCLIB (a free lyrics database)."
        case .loading: return "Looking up this song's lyrics…"
        case .notFound: return "No timed lyrics found for this song."
        case .instrumental: return "This song is instrumental."
        case .none: return "Words appear as they're sung. Lyrics come from LRCLIB."
        }
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                Text(title).font(Tokens.sans(12, .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Tokens.inkFaint))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rings

private struct RingSettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.ringSettings.mode == .expert { ExpertRings() } else { GenreRings() }
    }
}

/// Simple page: pick a genre (or let Aura detect it), plus how the rings look.
private struct GenreRings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.ringSettings
        VStack(alignment: .leading, spacing: 20) {
            Hint("Rings shoot out from the cover in Halo and ripple through Mosaic.")
            RingPulseLight()

            Section(title: "Genre") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(RingSettings.Genre.allCases) { g in
                        ChipButton(title: g.title, selected: s.genre == g) { model.ringSettings.genre = g }
                    }
                }
                Hint(genreHint)
            }

            Section(title: "How often", value: s.frequency.title) {
                Slider(value: Binding(get: { Double(model.ringSettings.frequency.rawValue) },
                                      set: { model.ringSettings.frequency = RingSettings.Frequency(rawValue: Int($0.rounded())) ?? .hits }),
                       in: 0...Double(RingSettings.Frequency.allCases.count - 1), step: 1)
                HStack {
                    Text("Fewer")
                    Spacer()
                    Text("More")
                }
                .font(Tokens.mono(10))
                .foregroundStyle(Tokens.inkDim)
                Hint(s.frequency.blurb)
            }

            RingLookControls()

            Rectangle().fill(Tokens.line).frame(height: 1)

            Button { withAnimation(Tokens.ease) { model.ringSettings.mode = .expert } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Expert settings").font(Tokens.sans(13, .semibold))
                        Text("Build your own triggers from frequency ranges, loudness and sudden changes.")
                            .font(Tokens.sans(11.5)).foregroundStyle(Tokens.inkDim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Tokens.inkDim)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tokens.inkFaint.opacity(0.6)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var genreHint: String {
        let s = model.ringSettings
        guard s.genre == .auto else { return s.genre.blurb }
        if let g = model.detectedGenre { return "This song sounds like \(g.title) — \(g.blurb.lowercased())" }
        return "Listening to work out this song's genre (takes about 10 seconds)…"
    }
}

/// Expert page: any number of triggers, each with its own range and thresholds.
private struct ExpertRings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.ringSettings
        VStack(alignment: .leading, spacing: 20) {
            Button { withAnimation(Tokens.ease) { model.ringSettings.mode = .genre } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                    Text("Genre presets").font(Tokens.sans(12.5, .semibold))
                }
                .foregroundStyle(Tokens.accent)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Expert triggers", color: Tokens.ink)
                Hint("Every trigger fires rings. Once a sound has fired, Aura remembers it and fires again each time it repeats.")
            }
            RingPulseLight()

            ForEach($model.ringSettings.rules) { $rule in
                TriggerCard(rule: $rule, canDelete: s.rules.count > 1) {
                    model.ringSettings.rules.removeAll { $0.id == rule.id }
                }
            }
            if s.rules.count < 4 {
                Button {
                    let used = Set(s.rules.map(\.source))
                    let next = RingSettings.Source.allCases.first { !used.contains($0) && $0 != .custom } ?? .custom
                    model.ringSettings.rules.append(RingSettings.Rule(source: next, loudness: 0.55, jump: 0.7))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("Add trigger").font(Tokens.sans(12.5, .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tokens.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            SwitchRow(title: "Also pulse on every beat", isOn: $model.ringSettings.alsoOnBeats,
                      hint: "Adds rings from Aura's beat detector on top of your triggers.")
            SwitchRow(title: "Louder hits make stronger rings", isOn: $model.ringSettings.louderIsStronger)
            Section(title: "Minimum gap between rings", value: String(format: "%.2f s", s.minGap)) {
                Slider(value: $model.ringSettings.minGap, in: 0.05...1)
            }
            Section(title: "Most rings at once", value: "\(s.maxRings)") {
                Slider(value: Binding(get: { Double(model.ringSettings.maxRings) },
                                      set: { model.ringSettings.maxRings = Int($0.rounded()) }), in: 1...8, step: 1)
            }

            RingLookControls()

            Button("Reset rings to default") { model.ringSettings = RingSettings() }
                .buttonStyle(.plain)
                .font(Tokens.sans(12, .semibold))
                .foregroundStyle(Tokens.accent)
        }
    }
}

private struct TriggerCard: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: RingSettings.Rule
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).tint(Tokens.accent).controlSize(.small)
                Menu {
                    ForEach(RingSettings.Source.allCases) { source in
                        Button(label(source)) { rule.source = source }
                    }
                } label: {
                    HStack {
                        Text(label(rule.source)).font(Tokens.sans(12.5, .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.inkDim)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tokens.inkFaint))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.inkDim)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this trigger")
                }
            }
            Hint(rule.source.examples)

            if rule.source == .custom {
                Section(title: "From", value: hz(rule.customLow)) { Slider(value: logBinding(\.customLow), in: 0...1) }
                Section(title: "To", value: hz(rule.customHigh)) { Slider(value: logBinding(\.customHigh), in: 0...1) }
            }
            Section(title: "Loudness needed", value: percent(rule.loudness)) {
                Slider(value: $rule.loudness, in: 0...1)
                Hint("0% is this song's quietest moments in this range, 100% its loudest.")
            }
            Section(title: "Sudden change needed", value: percent(rule.jump)) {
                Slider(value: $rule.jump, in: 0.05...1)
                Hint("How sharply it must get louder, compared with the biggest jumps in this range so far. Lower = more rings.")
            }
            TriggerMeter(ruleID: rule.id)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Tokens.bg.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.line))
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private func label(_ source: RingSettings.Source) -> String {
        if let r = source.range { return "\(source.title) · \(r.hzLabel)" }
        return "\(source.title) · \(rule.range.hzLabel)"
    }
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    private func hz(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1f kHz", value / 1000) : "\(Int(value.rounded())) Hz"
    }
    /// 20 Hz – 20 kHz on a log slider.
    private func logBinding(_ key: WritableKeyPath<RingSettings.Rule, Double>) -> Binding<Double> {
        Binding(get: { log(rule[keyPath: key] / 20) / log(1000) },
                set: { rule[keyPath: key] = (20 * pow(1000, $0)).rounded() })
    }
}

/// Look of the rings (shared by both pages).
private struct RingLookControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.ringSettings
        VStack(alignment: .leading, spacing: 20) {
            Section(title: "Ring speed", value: String(format: "%.1f s", s.lifetime)) {
                Slider(value: $model.ringSettings.lifetime, in: 0.4...2.5)
                Hint("How long each ring takes to spread out and fade.")
            }
            Section(title: "Thickness", value: String(format: "%.1f×", s.thickness)) {
                Slider(value: $model.ringSettings.thickness, in: 0.5...3)
            }
            Section(title: "Brightness", value: String(format: "%.1f×", s.brightness)) {
                Slider(value: $model.ringSettings.brightness, in: 0.3...2)
            }
            Section(title: "Colour") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(RingSettings.Colour.allCases) { c in
                        ChipButton(title: c.title, selected: s.colour == c) { model.ringSettings.colour = c }
                    }
                }
            }
        }
    }
}

/// A light that flashes whenever a ring fires, with a running count.
private struct RingPulseLight: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let m = model.ringMeter
            let flash = CACurrentMediaTime() - m.lastRingTime < 0.15
            HStack(spacing: 8) {
                Circle().fill(flash ? Tokens.accent : Tokens.inkFaint).frame(width: 9, height: 9)
                    .shadow(color: flash ? Tokens.accent : .clear, radius: 6)
                Eyebrow(flash ? "Ring!" : "Live", color: flash ? Tokens.accent : Tokens.ink)
                Spacer()
                Text("\(m.ringsLaunched) rings so far").font(Tokens.mono(10)).foregroundStyle(Tokens.inkDim).monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Tokens.bg.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.line))
        }
    }
}

/// Live bars for one trigger: how loud its range is and how sharply it's rising, with the marks
/// that trigger needs.
private struct TriggerMeter: View {
    @Environment(AppModel.self) private var model
    let ruleID: UUID

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let t = model.ringMeter.triggers.first { $0.id == ruleID }
            VStack(alignment: .leading, spacing: 8) {
                bar("Loudness now", value: t?.level ?? 0, mark: t?.needLevel ?? 1)
                bar("Sudden change now", value: t?.jump ?? 0, mark: t?.needJump ?? 1)
                if let t, t.remembered > 0 {
                    Text("Remembering \(t.remembered) repeating sound\(t.remembered == 1 ? "" : "s")")
                        .font(Tokens.mono(10)).foregroundStyle(Tokens.inkDim)
                }
            }
        }
    }

    private func bar(_ title: String, value: Float, mark: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Tokens.mono(10)).foregroundStyle(Tokens.inkDim)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(Tokens.mono(10)).foregroundStyle(Tokens.ink).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Tokens.inkFaint)
                    Capsule().fill(value >= mark ? Tokens.accent : Tokens.ink.opacity(0.5))
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(value, 0), 1))))
                    Rectangle().fill(Tokens.accent3)
                        .frame(width: 2, height: 10)
                        .offset(x: geo.size.width * CGFloat(min(max(mark, 0), 1)) - 1)
                }
            }
            .frame(height: 6)
        }
    }
}
