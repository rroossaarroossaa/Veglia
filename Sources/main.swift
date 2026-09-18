// Veglia (Italian for "vigil", a night kept awake by candlelight) — a menu bar app that
// keeps the Mac awake while Claude Code or another coding agent is working.
//
// Why: you walk away from the laptop while an agent keeps working (or keeps talking to
// you through a bot). On battery a MacBook sleeps a minute after the display goes dark,
// and the work stops. Veglia notices a running agent and holds an IOKit power assertion
// for exactly as long as it lives — the same mechanism as the system `caffeinate` tool,
// with an indicator in the menu bar.
//
// What it watches:
//   • known command-line agents (Claude Code, Codex CLI, Gemini CLI, …) — automatically,
//     see `knownAgents`; any of them can be unticked in the menu;
//   • any windowed app ticked under "Watch apps" (renders, exports);
//   • optionally any open terminal (off by default: many people keep a terminal open
//     all day, and the Mac would never sleep).
//
// No Xcode project: `Sources/*.swift`, built by `build.sh` with swiftc.

import Cocoa
import IOKit.pwr_mgt
import ServiceManagement

// UserDefaults keys.
private enum Pref {
    static let alwaysOn = "alwaysOn"              // stay awake always
    static let keepDisplay = "keepDisplay"        // keep the display on
    static let watched = "watchedApps"            // bundle ids of windowed apps to watch
    static let disabledAgents = "disabledAgents"  // ids from knownAgents the user unticked
    static let terminals = "watchTerminals"       // hold while any terminal is open
    static let lidMode = "lidMode"                // work with the lid closed (needs the system helper)
}

/// Known command-line agents: settings id, menu name, process names.
/// A process name is the basename of the first word of the command line, or of the
/// second word for node/python/bun scripts (so `node …/gemini.js` is recognised as gemini).
private let knownAgents: [(id: String, name: String, procs: [String])] = [
    ("claude",   "Claude Code",         ["claude"]),
    ("codex",    "Codex CLI",           ["codex"]),
    ("gemini",   "Gemini CLI",          ["gemini"]),
    ("copilot",  "GitHub Copilot CLI",  ["copilot", "github-copilot-cli"]),
    ("cursor",   "Cursor Agent",        ["cursor-agent"]),
    ("aider",    "Aider",               ["aider"]),
    ("opencode", "OpenCode",            ["opencode"]),
    ("amp",      "Amp",                 ["amp"]),
    ("goose",    "Goose",               ["goose"]),
    ("qwen",     "Qwen Code",           ["qwen"]),
    ("kimi",     "Kimi CLI",            ["kimi"]),
    ("grok",     "Grok CLI",            ["grok"]),
    ("continue", "Continue CLI",        ["cn"]),
    ("kiro",     "Kiro CLI",            ["kiro-cli", "kiro"]),
    ("crush",    "Crush",               ["crush"]),
    ("cline",    "Cline CLI",           ["cline"]),
]

/// Terminal apps that count as "a terminal is open".
private let terminalBundles: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
    "com.mitchellh.ghostty", "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty",
    "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.termius-dmg.mac",
]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let agentsItem = NSMenuItem(title: L.t(.watchAgents), action: nil, keyEquivalent: "")
    private let agentsMenu = NSMenu()
    private let appsItem = NSMenuItem(title: L.t(.watchApps), action: nil, keyEquivalent: "")
    private let appsMenu = NSMenu()
    private let terminalsItem = NSMenuItem(title: L.t(.terminals), action: #selector(toggleTerminals), keyEquivalent: "")
    private let alwaysItem = NSMenuItem(title: L.t(.alwaysOn), action: #selector(toggleAlways), keyEquivalent: "")
    private let displayItem = NSMenuItem(title: L.t(.keepDisplay), action: #selector(toggleDisplay), keyEquivalent: "")
    private let lidItem = NSMenuItem(title: L.t(.lidMode), action: #selector(toggleLid), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: L.t(.launchAtLogin), action: #selector(toggleLogin), keyEquivalent: "")
    private let languageItem = NSMenuItem(title: L.t(.language), action: nil, keyEquivalent: "")
    private let languageMenu = NSMenu()
    private let quitItem = NSMenuItem(title: L.t(.quit), action: #selector(quit), keyEquivalent: "q")

    // IOKit assertions. 0 means not held.
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var holding = false
    private var holdingSince: Date?
    private var timer: Timer?

    // Who is currently keeping the Mac awake, for the status line.
    private var activeAgents: [String] = []
    private var runningWatched: [String] = []
    private var terminalOpen = false

    private var alwaysOn: Bool { UserDefaults.standard.bool(forKey: Pref.alwaysOn) }
    private var keepDisplay: Bool {
        // Off by default: the display dims as usual while the Mac keeps working,
        // which spares the battery.
        UserDefaults.standard.bool(forKey: Pref.keepDisplay)
    }
    private var watchTerminals: Bool { UserDefaults.standard.bool(forKey: Pref.terminals) }
    private var lidMode: Bool { UserDefaults.standard.bool(forKey: Pref.lidMode) }
    private var watched: [String] {
        get { UserDefaults.standard.stringArray(forKey: Pref.watched) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Pref.watched) }
    }
    private var disabledAgents: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Pref.disabledAgents) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Pref.disabledAgents) }
    }

    // Flag directory and flag file for the lid helper. The helper (root, launchd) watches
    // the directory: flag present → `pmset disablesleep 1`, absent → 0. See lid/install-helper.sh.
    private var flagDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Veglia", isDirectory: true)
    }
    private var flagFile: URL { flagDir.appendingPathComponent("lid-awake") }
    private var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.rosathings.veglia.lid.plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        agentsItem.submenu = agentsMenu
        agentsMenu.delegate = self
        menu.addItem(agentsItem)
        appsItem.submenu = appsMenu
        appsMenu.delegate = self
        menu.addItem(appsItem)
        terminalsItem.target = self
        menu.addItem(terminalsItem)
        menu.addItem(.separator())
        for item in [alwaysItem, displayItem, lidItem, loginItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Language submenu: "Same as system" plus 20 languages by their native names. Built once.
        languageItem.submenu = languageMenu
        languageMenu.delegate = self
        let sys = NSMenuItem(title: L.t(.systemLanguage), action: #selector(pickLanguage(_:)), keyEquivalent: "")
        sys.target = self
        sys.representedObject = ""
        languageMenu.addItem(sys)
        languageMenu.addItem(.separator())
        for entry in L.names {
            let item = NSMenuItem(title: entry.native, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.code
            languageMenu.addItem(item)
        }
        menu.addItem(languageItem)
        menu.addItem(.separator())
        quitItem.target = self
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
        applyLanguage()

        check()
        // Every 5 seconds see which agents and watched apps are alive. Cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        release()
        // On quit the lid must put the Mac to sleep again, otherwise it could stay up all night.
        try? FileManager.default.removeItem(at: flagFile)
    }

    // MARK: — what we watch

    /// Names of running agents from `knownAgents` (minus the unticked ones).
    /// One `ps` call per check. The helper process `claude --chrome-native-host` (the bridge
    /// to the Chrome extension) is ignored: it is always there and does no work.
    private func runningAgents() -> [String] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let interpreters: Set<String> = ["node", "python", "python3", "bun", "deno", "uv", "npx"]
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            if line.contains("chrome-native-host") { continue }
            let tokens = line.split(separator: " ", maxSplits: 2)
            guard let first = tokens.first else { continue }
            var names = [(String(first) as NSString).lastPathComponent]
            if interpreters.contains(names[0]), tokens.count > 1 {
                let second = (String(tokens[1]) as NSString).lastPathComponent
                names.append((second as NSString).deletingPathExtension)
            }
            for name in names { seen.insert(name) }
        }
        let disabled = disabledAgents
        return knownAgents
            .filter { !disabled.contains($0.id) && !$0.procs.filter { seen.contains($0) }.isEmpty }
            .map { $0.name }
    }

    /// Ordinary windowed apps (what shows in the Dock), excluding Veglia itself.
    private func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    /// Names of ticked apps that are running right now.
    private func watchedRunning() -> [String] {
        let ids = Set(watched)
        return regularApps()
            .filter { ids.contains($0.bundleIdentifier!) }
            .compactMap { $0.localizedName }
    }

    private func anyTerminalRunning() -> Bool {
        regularApps().contains { terminalBundles.contains($0.bundleIdentifier!) }
    }

    // MARK: — holding the system awake

    private func check() {
        activeAgents = runningAgents()
        runningWatched = watchedRunning()
        terminalOpen = watchTerminals && anyTerminalRunning()
        let wanted = alwaysOn || !activeAgents.isEmpty || !runningWatched.isEmpty || terminalOpen
        if wanted && !holding { hold() }
        if !wanted && holding { release() }
        // The display setting may have changed on the fly: re-create the assertions.
        if holding && ((displayAssertion != 0) != keepDisplay) { release(); hold() }
        syncLidFlag()
        updateIcon()
    }

    /// The lid-helper flag exists exactly while the lid mode is on and we are holding.
    /// So a closed Mac stays awake only during work, not around the clock.
    private func syncLidFlag() {
        let want = lidMode && holding && helperInstalled
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: flagFile.path)
        if want && !exists {
            try? fm.createDirectory(at: flagDir, withIntermediateDirectories: true)
            fm.createFile(atPath: flagFile.path, contents: Data())
        } else if !want && exists {
            try? fm.removeItem(at: flagFile)
        }
    }

    private func hold() {
        let reason = "Veglia: an agent or a watched app is running" as CFString
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
        if keepDisplay {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        }
        holding = true
        holdingSince = Date()
    }

    private func release() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        holding = false
        holdingSince = nil
    }

    // MARK: — appearance

    private func updateIcon() {
        // Our own candle (icons/menubar-candle.html): filled while watching, outline while
        // resting. A template image adapts to light and dark menu bars by itself.
        let name = holding ? "candle-on" : "candle-off"
        let image = Bundle.main.image(forResource: name)
        image?.isTemplate = true
        image?.size = NSSize(width: 20, height: 20)
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !holding
        statusItem.button?.toolTip = holding ? L.t(.tipOn) : L.t(.tipOff)
    }

    /// Status line: who exactly is holding the Mac.
    private func statusText() -> String {
        guard holding else { return L.t(.idle) }
        var who = activeAgents + runningWatched
        if terminalOpen { who.append(L.t(.terminalName)) }
        var text: String
        if who.isEmpty {
            text = L.t(.manual)
        } else {
            let names = who.joined(separator: ", ")
            text = String(format: L.t(who.count == 1 ? .runningOne : .runningMany), names)
        }
        if let since = holdingSince {
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            if minutes >= 1 { text += " · " + String(format: L.t(.minutes), minutes) }
        }
        return text
    }

    /// "Watch agents" submenu: every known agent with a tick; the ones running right now
    /// get a dot in front of the name.
    private func rebuildAgentsMenu() {
        agentsMenu.removeAllItems()
        let hint = NSMenuItem(title: L.t(.agentsHint), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        agentsMenu.addItem(hint)
        agentsMenu.addItem(.separator())
        let disabled = disabledAgents
        let active = Set(activeAgents)
        for agent in knownAgents {
            let title = (active.contains(agent.name) ? "● " : "") + agent.name
            let item = NSMenuItem(title: title, action: #selector(toggleAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.state = disabled.contains(agent.id) ? .off : .on
            agentsMenu.addItem(item)
        }
    }

    /// "Watch apps" submenu: running apps first, then ticked apps that are currently
    /// closed (so they can be unticked).
    private func rebuildAppsMenu() {
        appsMenu.removeAllItems()
        let hint = NSMenuItem(title: L.t(.watchHint), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        appsMenu.addItem(hint)
        appsMenu.addItem(.separator())

        let ids = Set(watched)
        let running = regularApps().sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        var seen = Set<String>()
        for app in running {
            let id = app.bundleIdentifier!
            seen.insert(id)
            let item = NSMenuItem(title: app.localizedName ?? id, action: #selector(toggleApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = ids.contains(id) ? .on : .off
            if let icon = app.icon {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 18, height: 18)
                item.image = small
            }
            appsMenu.addItem(item)
        }
        let closed = watched.filter { !seen.contains($0) }
        if !closed.isEmpty {
            appsMenu.addItem(.separator())
            for id in closed {
                let name = (id.split(separator: ".").last).map(String.init) ?? id
                let item = NSMenuItem(title: name + " " + L.t(.closed), action: #selector(toggleApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = .on
                appsMenu.addItem(item)
            }
        }
    }

    /// Re-applies every title in the current language. Called at launch and after a language change.
    private func applyLanguage() {
        agentsItem.title = L.t(.watchAgents)
        appsItem.title = L.t(.watchApps)
        terminalsItem.title = L.t(.terminals)
        alwaysItem.title = L.t(.alwaysOn)
        displayItem.title = L.t(.keepDisplay)
        lidItem.title = L.t(.lidMode)
        loginItem.title = L.t(.launchAtLogin)
        languageItem.title = L.t(.language)
        languageMenu.items.first?.title = L.t(.systemLanguage)
        quitItem.title = L.t(.quit)
        updateIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === agentsMenu { rebuildAgentsMenu(); return }
        if menu === appsMenu { rebuildAppsMenu(); return }
        if menu === languageMenu {
            let current = L.override ?? ""
            for item in languageMenu.items { item.state = (item.representedObject as? String) == current ? .on : .off }
            return
        }
        check()
        statusLine.title = statusText()
        terminalsItem.state = watchTerminals ? .on : .off
        alwaysItem.state = alwaysOn ? .on : .off
        displayItem.state = keepDisplay ? .on : .off
        lidItem.state = (lidMode && helperInstalled) ? .on : .off
        if #available(macOS 13, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginItem.isHidden = false
        } else {
            loginItem.isHidden = true
        }
    }

    // MARK: — menu actions

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var set = disabledAgents
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        disabledAgents = set
        check()
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var list = watched
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
        watched = list
        check()
    }

    @objc private func toggleTerminals() {
        UserDefaults.standard.set(!watchTerminals, forKey: Pref.terminals)
        check()
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String ?? ""
        L.override = code.isEmpty ? nil : code
        applyLanguage()
    }

    /// Closed-lid mode. Turning on: warning → administrator password → helper install.
    /// Turning off: just drop the flag and the setting.
    @objc private func toggleLid() {
        if lidMode && helperInstalled {
            UserDefaults.standard.set(false, forKey: Pref.lidMode)
            check()
            return
        }
        let alert = NSAlert()
        alert.messageText = L.t(.lidWarnTitle)
        alert.informativeText = L.t(.lidWarnText)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L.t(.enable))
        alert.addButton(withTitle: L.t(.cancel))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if !helperInstalled && !installHelper() {
            let fail = NSAlert()
            fail.messageText = L.t(.lidFailed)
            fail.alertStyle = .critical
            fail.runModal()
            return
        }
        UserDefaults.standard.set(true, forKey: Pref.lidMode)
        check()
    }

    /// Installs the launchd daemon through the system password prompt (osascript
    /// "with administrator privileges"). The install script ships in the app resources.
    private func installHelper() -> Bool {
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else { return false }
        try? FileManager.default.createDirectory(at: flagDir, withIntermediateDirectories: true)
        let quoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "/bin/sh \(quoted(script)) \(quoted(flagDir.path))"
        let source = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error { NSLog("Veglia: helper install failed: \(error)"); return false }
        return result != nil && helperInstalled
    }

    @objc private func toggleAlways() {
        UserDefaults.standard.set(!alwaysOn, forKey: Pref.alwaysOn)
        check()
    }

    @objc private func toggleDisplay() {
        UserDefaults.standard.set(!keepDisplay, forKey: Pref.keepDisplay)
        check()
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Veglia: could not change launch at login: \(error)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, menu bar only
app.run()
