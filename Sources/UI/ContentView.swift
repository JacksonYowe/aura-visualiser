import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                MetalView(renderer: renderer).ignoresSafeArea()
            } else {
                VStack(spacing: 8) {
                    Text("Aura").font(Tokens.serif(48))
                    Text("This Mac's graphics couldn't start the visualiser.").font(Tokens.sans(14)).foregroundStyle(Tokens.inkDim)
                }
            }

            if let track = model.titleCardTrack, !model.hudVisible {
                TitleCard(track: track)
                    .transition(.opacity.combined(with: .offset(y: 12)))
            }

            if model.hudVisible || model.banner != nil {
                HUD(showChrome: model.hudVisible)
                    .transition(.opacity)
            }

            if let toast = model.toast {
                Text(toast)
                    .font(Tokens.mono(11, .medium))
                    .tracking(1)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .glassPanel(radius: 17)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, model.hudVisible ? 58 : 18)
                    .transition(.opacity.combined(with: .offset(y: -8)))
                    .allowsHitTesting(false)
            }
        }
        .foregroundStyle(Tokens.ink)
        .onContinuousHover { phase in
            if case .active = phase { model.noteActivity() }
        }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onAppear { model.start() }
    }
}

// MARK: - HUD

struct HUD: View {
    @Environment(AppModel.self) private var model
    let showChrome: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if let banner = model.banner {
                    BannerView(banner: banner)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if showChrome {
                    HStack(spacing: 8) {
                        Spacer()
                        StatusPill()
                        SettingsButton()
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                }
            }
            Spacer(minLength: 0)
            if showChrome {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 16) {
                        NowPlayingCard()
                        Spacer(minLength: 120)
                        ModeDock(compact: false)
                    }
                    HStack(alignment: .bottom, spacing: 16) {
                        NowPlayingCard()
                        Spacer(minLength: 12)
                        ModeDock(compact: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ModeDock(compact: true)
                        NowPlayingCard()
                    }
                }
                .padding(18)
                .transition(.opacity.combined(with: .offset(y: 16)))
            }
        }
    }
}

// MARK: - Now playing

private struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = model.nowPlaying
        HStack(spacing: 14) {
            CoverThumb(image: model.coverImage)

            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(eyebrow(now), color: Tokens.accent)
                Text(now.track?.name.nonEmpty ?? "Nothing playing")
                    .font(Tokens.serif(26))
                    .lineLimit(1)
                Text(subtitle(now))
                    .font(Tokens.sans(12.5, .medium))
                    .foregroundStyle(Tokens.inkDim)
                    .lineLimit(1)
                if let track = now.track, track.duration > 0 {
                    ProgressRow(duration: track.duration)
                        .padding(.top, 6)
                }
            }
            .frame(width: 250, alignment: .leading)

            HStack(spacing: 2) {
                IconButton(symbol: "backward.fill", size: 32) { model.previousTrack() }
                IconButton(symbol: now.state == .playing ? "pause.fill" : "play.fill", size: 40, prominent: true) {
                    model.playPause()
                }
                IconButton(symbol: "forward.fill", size: 32) { model.nextTrack() }
            }
            .disabled(model.spotifyAccess != .granted)
            .opacity(model.spotifyAccess == .granted ? 1 : 0.4)
        }
        .padding(12)
        .padding(.trailing, 6)
        .glassPanel()
    }

    private func eyebrow(_ now: SpotifyClient.NowPlaying) -> String {
        switch model.spotifyAccess {
        case .notRunning: return "Spotify closed"
        case .denied: return "No access"
        default: break
        }
        switch now.state {
        case .playing: return "Now playing"
        case .paused: return "Paused"
        case .stopped: return "Spotify"
        }
    }

    private func subtitle(_ now: SpotifyClient.NowPlaying) -> String {
        guard let t = now.track else { return "Play something in Spotify" }
        return [t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

private struct CoverThumb: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Tokens.accent.opacity(0.7), Tokens.accent2.opacity(0.6), Tokens.accent3.opacity(0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: 22, weight: .semibold)).foregroundStyle(Tokens.bg.opacity(0.7))
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tokens.line))
        .animation(Tokens.ease, value: image)
    }
}

private struct ProgressRow: View {
    @Environment(AppModel.self) private var model
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let pos = model.position
            HStack(spacing: 8) {
                Text(format(pos)).font(Tokens.mono(10)).foregroundStyle(Tokens.inkDim).monospacedDigit()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tokens.inkFaint)
                        Capsule().fill(Tokens.ink)
                            .frame(width: max(3, geo.size.width * min(max(pos / max(duration, 1), 0), 1)))
                    }
                }
                .frame(height: 3)
                Text(format(duration)).font(Tokens.mono(10)).foregroundStyle(Tokens.inkDim).monospacedDigit()
            }
        }
    }

    private func format(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Mode dock

private struct ModeDock: View {
    @Environment(AppModel.self) private var model
    /// Compact: only the selected (or hovered) mode shows its name.
    let compact: Bool
    @Namespace private var pill
    @State private var hovered: VisualMode?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VisualMode.allCases) { mode in
                let selected = model.mode == mode
                let named = !compact || selected || hovered == mode
                Button {
                    withAnimation(Tokens.ease) { model.mode = mode }
                } label: {
                    HStack(spacing: 6) {
                        Text(mode.number)
                            .font(Tokens.mono(10, .medium))
                            .foregroundStyle(selected ? Tokens.bg.opacity(0.55) : Tokens.inkDim)
                        if named {
                            Text(mode.title)
                                .font(Tokens.sans(12.5, .semibold))
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(selected ? Tokens.bg : Tokens.ink)
                    .padding(.horizontal, named ? 12 : 10)
                    .frame(height: 32)
                    .background {
                        if selected {
                            Capsule().fill(Tokens.ink).matchedGeometryEffect(id: "pill", in: pill)
                        } else if hovered == mode {
                            Capsule().fill(Tokens.inkFaint)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(Tokens.ease) { hovered = inside ? mode : (hovered == mode ? nil : hovered) }
                }
                .help("\(mode.title) — \(mode.blurb)  (\(mode.rawValue + 1))")
            }

            Rectangle().fill(Tokens.line).frame(width: 1, height: 18).padding(.horizontal, 6)

            AutoChip()
        }
        .padding(5)
        .glassPanel(radius: 22)
    }
}

private struct AutoChip: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let on = model.autoChange != .off
        Button {
            let all = AutoChange.allCases
            model.autoChange = all[(all.firstIndex(of: model.autoChange)! + 1) % all.count]
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shuffle").font(.system(size: 11, weight: .bold))
                Text(on ? model.autoChange.label : "Auto").font(Tokens.mono(10, .medium)).textCase(.uppercase).tracking(1)
            }
            .foregroundStyle(on ? Tokens.accent : Tokens.inkDim)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(hovering ? Tokens.inkFaint : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Change mode automatically: off, on each new song, or every 30 seconds  (A)")
    }
}

// MARK: - Status, banner, title card

private struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let (label, color) = state
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: color, radius: 4)
            Eyebrow(label, color: Tokens.ink)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassPanel(radius: 15)
    }

    private var state: (String, Color) {
        switch model.tapStatus {
        case .stopped: return ("Starting", Tokens.inkDim)
        case .failed: return ("Audio off", Tokens.accent3)
        case .listening(let spotify, _):
            if spotify {
                let lyrics = { if case .synced = model.lyricsStatus, model.showLyrics { return " · Lyrics" } else { return "" } }()
                return (model.hearingAudio ? "Listening · Spotify\(lyrics)" : "Spotify · quiet", model.hearingAudio ? Tokens.accent : Tokens.inkDim)
            }
            if model.source == .spotify { return ("Waiting for Spotify", model.hearingAudio ? Tokens.accent2 : Tokens.inkDim) }
            return (model.hearingAudio ? "Listening · all audio" : "All audio · quiet", model.hearingAudio ? Tokens.accent2 : Tokens.inkDim)
        }
    }
}

struct Banner: Equatable {
    enum Action: Equatable { case openSpotify, automationSettings, audioSettings, none }
    let title: String
    let detail: String
    let action: Action
    let actionLabel: String
}

private struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Tokens.accent3).frame(width: 7, height: 7).shadow(color: Tokens.accent3, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(Tokens.sans(13, .semibold))
                Text(banner.detail).font(Tokens.sans(12)).foregroundStyle(Tokens.inkDim)
            }
            if banner.action != .none {
                Button {
                    switch banner.action {
                    case .openSpotify: model.openSpotify()
                    case .automationSettings: model.openAutomationSettings()
                    case .audioSettings: model.openAudioCaptureSettings()
                    case .none: break
                    }
                } label: {
                    Text(banner.actionLabel)
                        .font(Tokens.sans(12, .bold))
                        .foregroundStyle(Tokens.bg)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(Capsule().fill(Tokens.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassPanel(radius: 22)
        .frame(maxWidth: 620)
    }
}

struct TitleCard: View {
    let track: SpotifyClient.Track

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Now playing", color: Tokens.accent)
            Text(track.name)
                .font(Tokens.serif(68))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(track.artist)
                .font(Tokens.sans(19, .medium))
                .foregroundStyle(Tokens.inkDim)
        }
        .foregroundStyle(Tokens.ink)
        .shadow(color: .black.opacity(0.7), radius: 24)
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 44)
        .padding(.top, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
