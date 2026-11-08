// Mac app launcher: the settings window shown before the game starts, in the launcher's own process (launcher.c calls dm_mac_launcher before it starts the host). Its settings come from the
// app's Resources/dm/launcher.json (dm/games/settings.py with SETTINGS_PLATFORM=mac); the model and the rows are the iOS launcher's (dm/ios/Sources/LauncherSettings.swift, LauncherRow.swift),
// and so is the store: launcher.<VAR> in the app's preferences, which launcher.c reads when the window is not shown (docs/frontends.md, Saved choices). Basic settings (level basic) come
// first, the others under Advanced settings, each in the list's sections. Play puts the settings into this process's environment, which the host inherits; Quit and closing the window end the
// app without the game. "Show this window at launch" off: no window unless Option is held at launch, and launcher.c applies the saved choices. The window never takes focus by itself: an app
// opened in the background (open -g) keeps its window behind until the player switches to it
import AppKit
import QuartzCore
import SwiftUI

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let done: (Bool) -> Void
    let fit: (CGFloat) -> Void
    @AppStorage("window.show") private var show = true
    @AppStorage("window.advanced") private var advanced = false
    @AppStorage("game.file") private var gameFile = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: Bundle.main.image(forResource: "AppIcon2") ?? NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info("CFBundleName") ?? "Game").font(.title2.weight(.semibold))
                    Text("Version \(info("CFBundleShortVersionString") ?? "1.0")").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                if GameFile.external { GameFileSection() }
                settingSections(basic: true)
                if !ButtonIconsSection.choices.isEmpty { ButtonIconsSection() }
                CloudSavesSection()
                Section {
                    DisclosureGroup("Advanced settings", isExpanded: $advanced) {}
                }
                if advanced {
                    settingSections(basic: false)
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                }
            }
            .formStyle(.grouped)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentSize.height + $0.contentInsets.top + $0.contentInsets.bottom - $0.containerSize.height
            } action: { _, extraHeight in
                fit(extraHeight)
            }
            HStack {
                Toggle("Show this window at launch", isOn: $show).toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { done(false) }
                Button("Play") { done(true) }.keyboardShortcut(.defaultAction)
                    .disabled(!GameFile.ready(gameFile))
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560)
    }

    @ViewBuilder private func settingSections(basic: Bool) -> some View {
        ForEach(m.sections(basic: basic), id: \.self) { section in
            let rows = m.rows(in: section, basic: basic)
            if !rows.isEmpty {
                Section(section) {
                    ForEach(rows) { SettingRow(s: $0, m: m) }
                }
            }
        }
    }
}

/// Cloud saves: a folder the save is synced through (dm/host/save_sync.h), the one the iPhone app picks in its launcher's Cloud saves section. It is kept in this app's
/// preferences as cloudSaves.folder, which launcher.c puts into DM_SAVE_SYNC before the host starts; a DM_SAVE_SYNC an env file or the launch environment set wins, and is shown here.
struct CloudSavesSection: View {
    @AppStorage("cloudSaves.folder") private var folder = ""
    private let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_SAVE_SYNC") || env["DM_SAVE_SYNC"] != nil ? env["DM_SAVE_SYNC"] : nil
    }()

    var body: some View {
        Section {
            LabeledContent("Cloud saves") {
                Text(fixed.map { "\(Self.shown($0)) (env.txt)" } ?? (folder.isEmpty ? "Off" : Self.shown(folder)))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            if fixed == nil {
                HStack {
                    Button(folder.isEmpty ? "Choose a folder…" : "Choose a different folder…", action: choose)
                    if !folder.isEmpty { Button("Turn off") { folder = "" } }
                }
            }
        } footer: {
            Text("Choose the iCloud Drive folder the iPhone app uses for this game. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in the save's -backups folder.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Cloud Saves"
        panel.message = "The folder the iPhone app chose in its launcher's Cloud saves"
        panel.directoryURL = URL(fileURLWithPath: folder.isEmpty ? Self.drive : folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    static let drive = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"   // iCloud Drive, as the Finder shows it

    /// A path under iCloud Drive as the Finder and the Files app name it: iCloud Drive › Documents › dev › Zelda; any other path as it is
    static func shown(_ path: String) -> String {
        guard path == drive || path.hasPrefix(drive + "/") else { return path }
        return (["iCloud Drive"] + path.dropFirst(drive.count).split(separator: "/").map(String.init)).joined(separator: " › ")
    }
}

@_silgen_name("dm_game_file_check")
private func dmGameFileCheck(_ path: UnsafePointer<CChar>, _ why: UnsafeMutablePointer<CChar>, _ n: Int) -> Int32   // launcher.c

/// Game file: an app packed without the game's RomFS (pack_app.py --no-romfs) runs the game from a file the player chooses, the game's NUP (or a RomFS image), kept in this app's
/// preferences as game.file, which launcher.c puts into DM_ROMFS; a DM_ROMFS an env file or the launch environment set wins, and is shown here
enum GameFile {
    static let external: Bool = {
        guard let r = Bundle.main.resourceURL else { return false }
        let fm = FileManager.default
        return !fm.fileExists(atPath: r.appendingPathComponent("romfs.img").path) && !fm.fileExists(atPath: r.appendingPathComponent("romfs").path)
    }()
    static let fixed: String? = {
        let env = ProcessInfo.processInfo.environment
        let keys = ((env["DM_ENV_FILE_KEYS"] ?? "") + " " + (env["DM_ENV_LAUNCH_KEYS"] ?? "")).split(separator: " ")
        return keys.contains("DM_ROMFS") || env["DM_ROMFS"] != nil ? env["DM_ROMFS"] : nil
    }()
    static func ready(_ file: String) -> Bool { !external || fixed != nil || (!file.isEmpty && FileManager.default.fileExists(atPath: file)) }
    /// launcher.c's check (dm_game_file_check): a NUP holding the version this app was built for, or a RomFS image
    static func check(_ path: String) -> (ok: Bool, why: String) {
        var why = [CChar](repeating: 0, count: 1024)
        let ok = path.withCString { dmGameFileCheck($0, &why, why.count) } == 1
        return (ok, String(cString: why))
    }
}

struct GameFileSection: View {
    @AppStorage("game.file") private var file = ""
    @State private var problem: String?
    @StateObject private var scanner = GameFileScanner()

    var body: some View {
        Section {
            LabeledContent("Game file") {
                Text(GameFile.fixed.map { "\($0) (env.txt)" } ?? (file.isEmpty ? "Not chosen" : file))
                    .foregroundStyle(GameFile.ready(file) ? Color.secondary : Color.red).lineLimit(1).truncationMode(.head)
            }
            if GameFile.fixed == nil {
                Button(file.isEmpty ? "Choose game file…" : "Choose a different file…", action: choose)
            }
            Button("Scan for errors", action: startScan).disabled(!GameFile.ready(file))
            if let p = problem ?? missing { Text(p).foregroundStyle(.red).font(.callout) }
        } footer: {
            Text("The game's .nup file. The game is read straight from it, so leave it where it is; a file on an external drive works while the drive is connected.")
        }
        .sheet(isPresented: Binding(get: { scanner.working }, set: { if !$0 { scanner.cancel() } })) {
            ScanProgress(path: GameFile.fixed ?? file, cancel: { scanner.cancel() })
        }
        .sheet(item: $scanner.result) { s in ScanResult(s: s) }
    }

    private var missing: String? {
        GameFile.fixed == nil && !file.isEmpty && !FileManager.default.fileExists(atPath: file) ? "The game file is no longer there: choose it again." : nil
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use This File"; panel.message = "Choose the game's .nup file"
        if !file.isEmpty { panel.directoryURL = URL(fileURLWithPath: file).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let r = GameFile.check(url.path)
        if r.ok { file = url.path; problem = nil } else { problem = r.why }
    }

    private func startScan() {
        let path = GameFile.fixed ?? file
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        scanner.start(path)
    }
}

@_silgen_name("dm_game_file_scan")
private func dmGameFileScan(_ path: UnsafePointer<CChar>, _ files: UnsafeMutablePointer<UInt64>, _ checked: UnsafeMutablePointer<UInt64>, _ damaged: UnsafeMutablePointer<UInt64>, _ packedDamaged: UnsafeMutablePointer<UInt64>, _ zstdFiles: UnsafeMutablePointer<UInt64>, _ zstdOK: UnsafeMutablePointer<Int32>, _ more: UnsafeMutablePointer<UInt64>, _ truncated: UnsafeMutablePointer<Int32>, _ list: UnsafeMutablePointer<CChar>, _ listN: Int, _ why: UnsafeMutablePointer<CChar>, _ whyN: Int) -> Int32   // launcher.c

/// What the scan found (dm_game_file_scan in launcher.c, the checks of dm/host/game_scan.h): the damage a start would not report until the game asked for the file
struct GameScan: Identifiable {
    let id = UUID()
    let path: String
    let error: String?   // the file cannot be read as a game file at all
    let files: UInt64, checked: UInt64, damaged: UInt64, packedDamaged: UInt64, zstdFiles: UInt64
    let zstdOK: Bool
    let more: UInt64   // damaged files past the list's room
    let truncated: Bool
    let list: [String]
    var healthy: Bool { error == nil && damaged == 0 && packedDamaged == 0 }

    static func run(_ path: String) -> GameScan {
        var files: UInt64 = 0, checked: UInt64 = 0, damaged: UInt64 = 0, packed: UInt64 = 0, zstdFiles: UInt64 = 0, more: UInt64 = 0
        var zstdOK: Int32 = 0, truncated: Int32 = 0
        var list = [CChar](repeating: 0, count: 16384), why = [CChar](repeating: 0, count: 1024)
        let v = path.withCString { p in
            dmGameFileScan(p, &files, &checked, &damaged, &packed, &zstdFiles, &zstdOK, &more, &truncated, &list, list.count, &why, why.count)
        }
        return GameScan(path: path, error: v == -1 ? String(cString: why) : nil, files: files, checked: checked, damaged: damaged, packedDamaged: packed,
                        zstdFiles: zstdFiles, zstdOK: zstdOK != 0, more: more, truncated: truncated != 0,
                        list: v == 0 ? String(cString: list).components(separatedBy: "\n").filter { !$0.isEmpty } : [])
    }
}

/// The scan's runner: the C scan blocks its thread for a few seconds, so it runs detached and the sheet stays live; a cancelled scan's late result is dropped
final class GameFileScanner: ObservableObject {
    @Published var result: GameScan?
    @Published var working = false
    private var job: Task<Void, Never>?

    func start(_ path: String) {
        job?.cancel()
        result = nil; working = true
        job = Task.detached(priority: .userInitiated) {
            let s = GameScan.run(path)
            await MainActor.run { [weak self] in
                if !(self?.job?.isCancelled ?? true) { self?.result = s; self?.working = false }
            }
        }
    }

    func cancel() {
        job?.cancel()
        working = false
    }
}

/// The scan at work: an indeterminate progress, the file it is reading, and a way out
struct ScanProgress: View {
    let path: String
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Reading the game file…").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Button("Cancel", action: cancel)
        }
        .padding(30).frame(width: 400)
    }
}

/// The scan's modal: what was checked, what was found, and what the finding means for the game
struct ScanResult: View {
    let s: GameScan
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        if s.error != nil { return "The game file cannot be scanned" }
        return s.healthy ? "No problems found" : "The game file is damaged"
    }

    private var message: String {
        if let e = s.error { return e }
        if s.healthy {
            var t = "The game file's table of contents is whole, and its \(s.files.formatted()) files sit where this app reads them."
            if s.checked > 0 { t += " The \(s.checked.formatted()) files whose format can be checked were looked at, and every one starts as its name promises." }
            if s.zstdFiles > 0 {
                t += s.zstdOK ? " Files stored compressed were unpacked for the check."
                    : " This app was built without the decompressor, so the \(s.zstdFiles.formatted()) files stored compressed were not checked."
            }
            return t + " The scan reads the start of each file; it does not check the whole game file byte for byte."
        }
        var t = "\(s.damaged.formatted()) of the \(s.checked.formatted()) files checked do not start as their names promise (a .zs file that is not a zstd stream):"
        if s.packedDamaged > 0 {
            t += "\n\(s.packedDamaged.formatted()) files were packed as they were read, because their hashes failed (--allow-damaged)."
        }
        if s.more > 0 { t += "\n… and \(s.more.formatted()) more." }
        if s.truncated { t += "\nThe scan did not reach every file." }
        t += "\n\nThe game asks for a file like this again on every pass of its background loader and never stops: several CPU cores stay busy all session and the frame rate sags."
        t += " The damage is in the game file itself, so copying this file again brings the same bytes: the fix is a good copy of the game."
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: s.error != nil ? "xmark.octagon.fill" : s.healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(s.error != nil ? Color.red : s.healthy ? Color.green : Color.orange)
                Text(title).font(.title3.weight(.semibold))
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.callout)
                    if !s.list.isEmpty {
                        Text(s.list.joined(separator: "\n")).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }.padding(1)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 480, height: 400)
    }
}

/// Button icons: the RomFS overlays packed into the app (pack_app.py --overlay NAME=DIR: Resources/overlays/NAME), each another controller's icons and controls screen; the choice is
/// kept as buttonIcons.choice ("" = the game's own), which launcher.c puts in front of DM_ROMFS_OVERLAY
struct ButtonIconsSection: View {
    static let choices: [String] = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("overlays"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }()
    @AppStorage("buttonIcons.choice") private var choice = ""

    var body: some View {
        Section {
            Picker("Button icons", selection: $choice) {
                Text("Switch").tag("")
                ForEach(Self.choices, id: \.self) { Text($0).tag($0) }
            }
        } footer: {
            Text("The button icons the game shows, and the controller on its controls screen.")
        }
    }
}

private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: LauncherModel
    var window: NSWindow?
    var play = false

    init(_ model: LauncherModel) { self.model = model }

    func applicationDidFinishLaunching(_ n: Notification) {
        let name = info("CFBundleName") ?? "Game"
        let menu = NSMenu(), item = NSMenuItem(), app = NSMenu()
        app.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = app; menu.addItem(item); NSApp.mainMenu = menu
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = name; w.isReleasedWhenClosed = false; w.delegate = self
        w.contentMinSize = NSSize(width: 520, height: 0)
        window = w
        if let screen = w.screen ?? NSScreen.main {
            w.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.midX - w.frame.width / 2, y: screen.visibleFrame.maxY))
        }
        let host = NSHostingView(rootView: LauncherView(m: model, done: { [weak self] in self?.finish($0) }, fit: { [weak self] in self?.fit($0) }))
        host.sizingOptions = []   // the Form's measured scroll content owns the height, including after collapse
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        // no activation and no ordering in front of another app's windows: LaunchServices activates an app opened from Finder or the Dock (applicationDidBecomeActive), open -g does not
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderBack(nil) }
    }
    func applicationDidBecomeActive(_ n: Notification) { window?.makeKeyAndOrderFront(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {   // ⌘Q, or a logout or restart: the app ends without the game (exit 0, as Quit)
        fputs("launcher: quit without starting the game\n", stderr)
        return .terminateNow   // not terminateCancel, which a logout or restart takes as a refusal and stops
    }
    func windowWillClose(_ n: Notification) { finish(false) }

    func fit(_ extraHeight: CGFloat) {
        guard let w = window, let screen = w.screen else { return }
        let frame = LauncherWindowLayout.fitted(w.frame, extraHeight: extraHeight, visible: screen.visibleFrame)
        if abs(frame.height - w.frame.height) > 0.5 { w.setFrame(frame, display: true) }
    }

    func finish(_ play: Bool) {
        guard let w = window else { return }
        window = nil; self.play = play
        // The main thread blocks in launcher.c's waitpid once run() returns, so the window must leave the screen now: no fade-out (it runs on later run-loop passes),
        // and dmMacLauncher flushes the order-out (AppKit commits it at the end of a pass). Without both, the window stayed on screen, not responding, until the game ended
        w.animationBehavior = .none
        w.delegate = nil; w.orderOut(nil)
        NSApp.stop(nil)
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)   // run returns at the next event
    }
}

enum LauncherWindowLayout {
    static func fitted(_ frame: NSRect, extraHeight: CGFloat, visible: NSRect) -> NSRect {
        let top = min(frame.maxY, visible.maxY)
        let height = min(frame.height + extraHeight, top - visible.minY)
        return NSRect(x: frame.minX, y: top - height, width: frame.width, height: height)
    }
}

// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off): launcher.c applies the saved choices
@_cdecl("dm_mac_launcher")
public func dmMacLauncher() -> Int32 {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return 2 }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return 2 }
    // DM_LAUNCHER_FORCE (launcher.c): the app has no game file yet, so the window shows to ask for it
    if (UserDefaults.standard.object(forKey: "window.show") as? Bool) == false && !NSEvent.modifierFlags.contains(.option) && ProcessInfo.processInfo.environment["DM_LAUNCHER_FORCE"] == nil {
        fputs("launcher: settings window off (hold Option at launch to show it)\n", stderr)
        return 2
    }
    let model = LauncherModel(file.settings)
    let app = NSApplication.shared, launcher = Launcher(model)
    app.setActivationPolicy(.regular)
    app.delegate = launcher
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    app.run()
    CATransaction.flush()   // finish's order-out
    app.setActivationPolicy(.prohibited)   // the host is the game's app from here on
    guard launcher.play else { fputs("launcher: quit without starting the game\n", stderr); return 0 }
    model.apply()
    return 1
}
