import SwiftUI

@main
struct AuraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        SnapshotRunner.runIfRequested()   // dev-only: renders PNGs and exits when launched with --snapshot
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Aura", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .preferredColorScheme(.dark)
                .containerBackground(.black, for: .window)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stop()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 800)
        .commands { VisualiserCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct VisualiserCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Visualiser") {
            ForEach(VisualMode.allCases) { mode in
                Button((model.mode == mode ? "✓ " : "    ") + mode.title) { model.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(mode.rawValue + 1)")), modifiers: [])
            }
            Divider()
            Button("Next Mode") { model.mode = model.mode.next(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous Mode") { model.mode = model.mode.next(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Auto-Change: \(model.autoChange.label)") {
                let all = AutoChange.allCases
                model.autoChange = all[(all.firstIndex(of: model.autoChange)! + 1) % all.count]
            }
            .keyboardShortcut("a", modifiers: [])
            Divider()
            Button(model.hudVisible ? "Hide Controls" : "Show Controls") { model.toggleHUD() }
                .keyboardShortcut("h", modifiers: [])
            Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [])
        }

        CommandMenu("Lyrics") {
            Button(model.showLyrics ? "Hide Lyrics" : "Show Lyrics") { model.showLyrics.toggle() }
                .keyboardShortcut("l", modifiers: [])
            Divider()
            ForEach(LyricTheme.allCases) { theme in
                Button((model.lyricTheme == theme ? "✓ " : "    ") + theme.title) { model.lyricTheme = theme }
            }
            Button("Next Lyric Style") { model.cycleLyricTheme() }
                .keyboardShortcut("t", modifiers: [])
            Divider()
            Button("Lyrics Earlier") { model.nudgeLyrics(-0.1) }
                .keyboardShortcut("[", modifiers: [])
            Button("Lyrics Later") { model.nudgeLyrics(0.1) }
                .keyboardShortcut("]", modifiers: [])
            Button("Automatic Lyric Timing") { model.resetLyricTiming() }
                .keyboardShortcut("\\", modifiers: [])
        }

        CommandMenu("Playback") {
            Button("Play / Pause") { model.playPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next Song") { model.nextTrack() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Song") { model.previousTrack() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
    }
}
