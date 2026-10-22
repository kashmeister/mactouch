import AppKit
import IOKit.hid

// MARK: menu bar app

/// Redraws the menu bar icon and tooltip after the touchscreens or permissions changed.
func refreshStatusIcon() { (NSApp.delegate as? AppDelegate)?.updateIcon() }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var lastApp: NSRunningApplication?   // the app in front before the menu opened
    var axTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        startHID()
        // Put the keyboard back after display changes settle, after wake and unlock (which re-centre it),
        // and at launch. Later passes catch late moves.
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in scheduleRestore([3, 8], "display change") }, nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            screenLocked = true; log("screen locked")
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            screenLocked = false; log("screen unlocked"); scheduleRestore([1, 3, 8], "unlock")
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            scheduleRestore([3, 8], "wake")
        }
        scheduleRestore([2], "launch")
        // Panels move when dragged (remembered right after each drag); this catches anything else.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in rememberKeyboard() }.tolerance = 5
        updateIcon()
    }

    func startHID() {
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
            attached(dev)
            refreshStatusIcon()
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, dev in
            detached(dev)
            DispatchQueue.main.async { refreshStatusIcon() }
        }, nil)
        IOHIDManagerRegisterInputValueCallback(mgr, valueCB, nil)
        watchRawDigitizers()
        // A touchscreen's display can arrive after the touchscreen, and the notice can be missed.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { refreshDisplays() } }
        }, nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let before = devices.values.map { $0.display }
            refreshDisplays()
            if devices.values.map({ $0.display }) != before { self?.updateIcon() }
            keyboardFollowTouchscreens()
        }.tolerance = 1
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        log("start \(Bundle.main.bundleIdentifier ?? "unbundled") probe=\(probe) settings: \(cfg)")
        // Input Monitoring applies to new processes only, and a running process never sees the grant:
        // after a while, let a fresh process try again.
        // Opening fails as a whole if one matched device cannot be opened (a keyboard interface, say), so
        // only a missing permission counts as missing.
        let opened = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess && IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            log("HID manager open returned \(hex(UInt32(bitPattern: opened))) with Input Monitoring granted; carrying on")
        }
        guard opened == kIOReturnSuccess || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            log("Input Monitoring missing (open returned \(hex(UInt32(bitPattern: opened)))); enable MacTouch in System Settings > Privacy & Security > Input Monitoring")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in restartProcess() }
            return
        }
        hidOpen = true
        log("Input Monitoring granted; HID manager open")
        // Accessibility applies to the running process.
        if !probe && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            log("Accessibility missing; enable MacTouch in System Settings > Privacy & Security > Accessibility")
            axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate(); log("Accessibility granted"); startEventTap(); self?.updateIcon()
            }
        } else if !probe { startEventTap() }
        log("ready; touchscreens: " + (touchDevices().map { "\($0.label) (\($0.role.label))" }.joined(separator: ", ")).ifEmpty("none"))
    }

    // One line per connected touchscreen.
    var statusLines: [String] {
        if !hidOpen { return ["Waiting for Input Monitoring permission"] }
        if !probe && !AXIsProcessTrusted() { return ["Waiting for Accessibility permission"] }
        if touchDevices().isEmpty { return ["No touch screen connected"] }
        if cfg.paused { return ["Paused"] }
        if probe { return ["Probe mode: logging only"] }
        return touchDevices().map { t in
            if let d = t.display {
                // Came up as a mouse, but has a multi-touch mode (the CX158): power-cycling may bring it.
                let hint = t.couldBeMultiTouch ? " (single touch; unplug it for 15 s for multi-touch)" : ""
                return "Touch active: \(t.name) on \(displayName(d))" + hint
            }
            if pairing.device === t { return "\(t.name): touch the orange target to pair it" }
            return t.role == .singleTouch ? "\(t.name): not paired with a display (Touchscreens ▸ Pair…)"
                                          : "\(t.name): display not found; using the main display"
        }
    }
    var status: String { statusLines.joined(separator: "; ") }

    // The screen the top-level screen settings act on: the one touched last, else the only one connected.
    var menuProfile: String? {
        if let t = activeDevice, touchDevices().contains(where: { $0 === t }) { return t.profile }
        return touchDevices().first?.profile ?? (screens.count == 1 ? screens.keys.first : nil)
    }

    func updateIcon() {
        let ok = statusLines.contains { $0.hasPrefix("Touch active") }
        let img = NSImage(systemSymbolName: ok ? "hand.point.up.left" : "hand.raised.slash", accessibilityDescription: "MacTouch")
        img?.isTemplate = true
        item?.button?.image = img
        item?.button?.toolTip = "MacTouch: " + status
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        let front = NSWorkspace.shared.frontmostApplication
        lastApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        updateIcon()
        for line in statusLines { add(menu, line, nil) }
        menu.addItem(.separator())
        add(menu, "Pause Touch", #selector(toggle(_:)), on: cfg.paused, obj: "paused")
        menu.addItem(.separator())
        // Screen settings act on the screen touched last; with several connected, its name says which.
        let mp = menuProfile, p = mp.flatMap { screens[$0] } ?? [:]
        let suffix = touchDevices().count > 1 ? " (\(mp.map(profileName) ?? "?"))" : ""
        let multi = touchDevices().contains { $0.role == .multiTouch && $0.mode != .single } || touchDevices().isEmpty
        let only = multi ? "" : " (multi-touch screens only)"
        add(menu, "One-Finger Scroll" + suffix, #selector(toggle(_:)), on: p["oneFingerScroll"] as? Bool ?? cfg.oneFingerScroll,
            obj: ["oneFingerScroll", mp as Any])
        add(menu, "Two-Finger Tap Right-Clicks" + only, #selector(toggle(_:)), on: cfg.twoFingerTap, obj: ["twoFingerTap"], enabled: multi)
        add(menu, "Invert Scrolling", #selector(toggle(_:)), on: cfg.invertScroll, obj: ["invertScroll"])
        keyboardItems(menu)
        choices(menu, "Pinch" + only, "zoom", cfg.zoom, [("Trackpad Zoom", "gesture"), ("⌘+ / ⌘− Keys", "keys"), ("Off", "off")]).isEnabled = multi
        choices(menu, "Long Press" + suffix, "hold", p["hold"] as? Double ?? cfg.hold,
                [0.4, 0.5, 0.6, 0.8, 1.0].map { (String(format: "%.1f s", $0), $0) }, profile: mp)
        ringColors(menu)
        choices(menu, "Scroll Speed", "scrollScale", cfg.scrollScale, [0.5, 0.75, 1.0, 1.5, 2.0].map { ("\($0)×", $0) })
        choices(menu, "Scroll Momentum", "momentum", cfg.momentum, [("Default", 0.998), ("Shorter", 0.995), ("Off", 0.0)])
        choices(menu, "Multi-Finger Swipes" + only, "swipes", cfg.swipes,
                [("Three or Four Fingers", "3"), ("Four Fingers Only", "4"), ("Off", "off")]).isEnabled = multi
        add(menu, "Resize Windows at Edges", #selector(toggleEdge(_:)), on: cfg.edge > 0)
        menu.addItem(.separator())
        appList(menu, "Drag Apps", "dragApps", cfg.dragApps, "In these apps one finger always drags.")
        appList(menu, "Zoom-Key Apps", "zoomKeyApps", cfg.zoomKeyApps, "In these apps pinch sends ⌘+ / ⌘−.")
        menu.addItem(.separator())
        let canTouch = hidOpen && !touchDevices().isEmpty
        add(menu, piano.active ? "Close Music" : "Music…", #selector(togglePiano(_:)), enabled: canTouch)
        add(menu, sketch.active && !sketch.overlay ? "Close Whiteboard" : "Whiteboard…", #selector(toggleBoard(_:)), enabled: canTouch)
        add(menu, sketch.active && sketch.overlay ? "Stop Drawing on Screen" : "Draw on Screen…", #selector(toggleOverlay(_:)), enabled: canTouch)
        menu.addItem(.separator())
        calibrationItems(menu, mp, suffix)
        touchscreens(menu)
        menu.addItem(.separator())
        startAtLoginItem(menu)
        add(menu, "Open Log", #selector(openLog(_:)))
        add(menu, "MacTouch on GitHub", #selector(openRepo(_:)))
        add(menu, "Quit MacTouch", #selector(quit(_:)), key: "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, on: Bool = false, obj: Any? = nil,
             enabled: Bool = true, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = on ? .on : .off
        i.representedObject = obj
        i.isEnabled = enabled && action != nil
        menu.addItem(i)
        return i
    }

    @discardableResult
    func choices<T: Equatable>(_ menu: NSMenu, _ title: String, _ key: String, _ current: T, _ opts: [(String, T)],
                               profile: String? = nil) -> NSMenuItem {
        let sub = NSMenu(); sub.autoenablesItems = false
        for (label, v) in opts { add(sub, label, #selector(choose(_:)), on: v == current, obj: [key, v, profile as Any] as [Any]) }
        let i = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    func calibrationItems(_ menu: NSMenu, _ id: String?, _ suffix: String) {
        let connected = touchDevices().contains { $0.profile == id && ($0.role == .multiTouch || $0.driven && $0.display != nil) }
        let cal = calibration(id)
        add(menu, "Calibrate Touch…" + suffix, #selector(calibrate(_:)), obj: id as Any, enabled: hidOpen && connected)
        add(menu, "Undo Calibration", #selector(undoCalibration(_:)), obj: id as Any, enabled: previousCal(id).map { $0 != cal } ?? false)
        add(menu, "Reset Calibration", #selector(resetCalibration(_:)), obj: id as Any, enabled: cal != identityCal)
    }

    // One submenu per touchscreen MacTouch knows, connected or not.
    func touchscreens(_ menu: NSMenu) {
        let sub = NSMenu(); sub.autoenablesItems = false
        for (id, p) in screens.sorted(by: { profileName($0.key) < profileName($1.key) }) {
            let dev = touchDevices().first { $0.profile == id } ?? devices.values.first { $0.profile == id }
            let mode = profileMode(id), spec = p["display"] as? String ?? ""
            let place = dev?.display.map(displayName) ?? (spec.isEmpty ? "no display paired" : "display not connected")
            let what = dev == nil ? "Not connected" : mode == .ignore ? "Not used (not a touchscreen)" : dev!.role.label.capitalizedFirst
            let s = NSMenu(); s.autoenablesItems = false
            add(s, what + " · " + place, nil)
            s.addItem(.separator())
            add(s, "Pair with Display…", #selector(pairScreen(_:)), obj: id, enabled: dev != nil && mode != .ignore && hidOpen)
            calibrationItems(s, id, "")
            add(s, "One-Finger Scroll", #selector(toggle(_:)), on: p["oneFingerScroll"] as? Bool ?? false, obj: ["oneFingerScroll", id])
            var modes: [(String, String)] = [("Automatic" + (dev.map { " (\($0.kind.label))" } ?? ""), ScreenMode.auto.rawValue)]
            if dev?.kind != .singleTouch { modes.append(("Multi-Touch", ScreenMode.multi.rawValue)) }
            modes += [("Single Touch", ScreenMode.single.rawValue), ("Not a Touchscreen", ScreenMode.ignore.rawValue)]
            choices(s, "Mode", "mode", mode.rawValue, modes, profile: id)
            s.addItem(.separator())
            add(s, "Forget This Touchscreen", #selector(forgetScreen(_:)), obj: id)
            let title = (p["name"] as? String ?? id) + (dev == nil ? " (not connected)" : "")
            sub.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = s
        }
        if screens.isEmpty { add(sub, "(none yet: connect a touchscreen)", nil) }
        menu.addItem(withTitle: "Touchscreens", action: nil, keyEquivalent: "").submenu = sub
    }

    func keyboardItems(_ menu: NSMenu) {
        let sub = NSMenu(); sub.autoenablesItems = false
        add(sub, "Show Keyboard", #selector(toggleKeyboard(_:)), on: keyboardOn() == true, enabled: keyboardOn() != nil)
        sub.addItem(.separator())
        add(sub, "Off While No Touchscreen Is Connected", #selector(toggle(_:)), on: cfg.keyboardFollowsTouch, obj: ["keyboardFollowsTouch"],
            enabled: keyboardOn() != nil)
        add(sub, "Keep Keyboard Position", #selector(toggle(_:)), on: cfg.keepKeyboard, obj: ["keepKeyboard"])
        add(sub, "Auto Keyboard", #selector(toggle(_:)), on: cfg.autoKeyboard, obj: ["autoKeyboard"])
        menu.addItem(withTitle: "Accessibility Keyboard", action: nil, keyEquivalent: "").submenu = sub
    }

    func startAtLoginItem(_ menu: NSMenu) {
        if let other = startedByOther { add(menu, "Start at Login (set up by \(other))", nil, on: true); return }
        let status = loginAgent.status
        add(menu, status == .requiresApproval ? "Start at Login (allow it in System Settings ▸ Login Items)" : "Start at Login",
            #selector(toggleStartAtLogin(_:)), on: status == .enabled || status == .requiresApproval)
    }

    func ringColors(_ menu: NSMenu) {
        let presets = [("Gauge Orange", "#FF6A00"), ("Amber", "#FFB000"), ("White", "#FFFFFF"),
                       ("Green", "#34C759"), ("Red", "#FF3B30"), ("Accent Color", "accent")]
        let sub = NSMenu(); sub.autoenablesItems = false
        for (label, v) in presets {
            let i = add(sub, label, #selector(choose(_:)), on: v == cfg.ringColor, obj: ["ringColor", v] as [Any])
            i.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                color(v).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill(); return true
            }
        }
        if !presets.contains(where: { $0.1 == cfg.ringColor }) { add(sub, "Custom \(cfg.ringColor)", nil, on: true) }
        menu.addItem(withTitle: "Hold Ring Color", action: nil, keyEquivalent: "").submenu = sub
    }

    func appList(_ menu: NSMenu, _ title: String, _ key: String, _ apps: [String], _ hint: String) {
        let sub = NSMenu(); sub.autoenablesItems = false
        add(sub, hint, nil)
        for a in apps { add(sub, a, #selector(removeApp(_:)), on: true, obj: [key, a]) }
        if apps.isEmpty { add(sub, "(none)", nil) }
        sub.addItem(.separator())
        if let app = lastApp {
            let name = ownerName(of: app)
            add(sub, "Add \(name)", #selector(addApp(_:)), obj: [key, name], enabled: !apps.contains(name))
        } else {
            add(sub, "Add: switch to the app first, then open this menu", nil)
        }
        sub.addItem(.separator())
        add(sub, "Click an app to remove it", nil)
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = sub
    }

    func value(_ key: String, _ profile: String?) -> Bool {
        if profileKeys.contains(key), let id = profile, let v = screens[id]?[key] as? Bool { return v }
        switch key {
        case "paused": return cfg.paused
        case "oneFingerScroll": return profile == nil ? cfg.oneFingerScroll : false
        case "twoFingerTap": return cfg.twoFingerTap
        case "invertScroll": return cfg.invertScroll
        case "keepKeyboard": return cfg.keepKeyboard
        case "autoKeyboard": return cfg.autoKeyboard
        case "keyboardFollowsTouch": return cfg.keyboardFollowsTouch
        default: return false
        }
    }

    // representedObject: the key, or [key] / [key, profile]
    @objc func toggle(_ s: NSMenuItem) {
        let kv = s.representedObject as? [Any] ?? [s.representedObject as Any]
        guard let key = kv.first as? String else { return }
        let id = kv.count > 1 ? kv[1] as? String : nil
        if key == "paused" { endGesture() }
        if key == "keyboardFollowsTouch" { defaults.removeObject(forKey: keyboardOffForNoTouchscreen) }
        setSetting(key, !value(key, id), profile: id)
        if key == "paused" { updateSeizes() }   // paused screens go back to macOS
        updateIcon()
    }
    @objc func toggleKeyboard(_ s: NSMenuItem) {   // by hand: no longer MacTouch's to turn on or off
        defaults.removeObject(forKey: keyboardOffForNoTouchscreen); keyboardHandedBack = true
        setKeyboard(!(keyboardOn() ?? true), "from the menu")
    }
    @objc func toggleStartAtLogin(_ s: NSMenuItem) { setStartAtLogin(s.state != .on) }
    @objc func toggleEdge(_ s: NSMenuItem) { setSetting("edge", cfg.edge > 0 ? 0.0 : 12.0) }
    @objc func choose(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [Any], let key = kv[0] as? String else { return }
        let id = kv.count > 2 ? kv[2] as? String : nil
        if key == "mode", let id {   // a screen's mode lives only in its profile
            setProfile(id, "mode", kv[1]); log("set mode = \(kv[1]) for \(profileName(id))")
            if activeDevice?.profile == id { endGesture() }
            refreshDisplays(); updateIcon(); return
        }
        setSetting(key, kv[1], profile: id)
        if key.hasPrefix("piano") { piano.settingsChanged() }
    }
    @objc func pairScreen(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let t = devices.values.first(where: { $0.profile == id }) else { return }
        pairing.request(t)
    }
    @objc func forgetScreen(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        var all = screens; all[id] = nil; screens = all
        log("forgot touchscreen profile \(id)")
        for t in allDevices() where t.profile == id {   // a connected one starts over as new
            if activeDevice === t { endGesture(); activeDevice = nil; activeProfile = nil; cfg = loadConfig() }
            if t.raw != nil { t.profile = nil; register(t); continue }
            for d in t.services { devices[ObjectIdentifier(d)] = nil }
            for d in t.services { attached(d) }
        }
        updateIcon()
    }
    @objc func togglePiano(_ s: NSMenuItem) {
        if piano.active { piano.close() } else { if sketch.active { sketch.close() }; piano.open() }
    }
    @objc func toggleBoard(_ s: NSMenuItem) { toggleSketch(overlay: false) }
    @objc func toggleOverlay(_ s: NSMenuItem) { toggleSketch(overlay: true) }
    func toggleSketch(overlay: Bool) {
        let same = sketch.active && sketch.overlay == overlay
        if sketch.active { sketch.close() }
        if same { return }
        if piano.active { piano.close() }
        sketch.open(overlay: overlay)
    }
    @objc func addApp(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String] else { return }
        let list = kv[0] == "dragApps" ? cfg.dragApps : cfg.zoomKeyApps
        setSetting(kv[0], list + [kv[1]])
    }
    @objc func removeApp(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [String] else { return }
        let list = kv[0] == "dragApps" ? cfg.dragApps : cfg.zoomKeyApps
        setSetting(kv[0], list.filter { $0 != kv[1] })
    }
    @objc func calibrate(_ s: NSMenuItem) {   // on the screen whose profile the item belongs to
        if let id = s.representedObject as? String, let t = touchDevices().first(where: { $0.profile == id }) { activate(t) }
        calibrator.start()
    }
    @objc func resetCalibration(_ s: NSMenuItem) { setCalibration(identityCal, profile: s.representedObject as? String) }
    @objc func undoCalibration(_ s: NSMenuItem) {   // a second undo redoes
        let id = s.representedObject as? String
        if let p = previousCal(id) { setCalibration(p, profile: id) }
    }
    @objc func openLog(_ s: NSMenuItem) {
        let url = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logPath) ? url : url.deletingLastPathComponent())
    }
    @objc func openRepo(_ s: NSMenuItem) { NSWorkspace.shared.open(URL(string: repoURL)!) }
    @objc func quit(_ s: NSMenuItem) { endGesture(); log("quit from menu"); NSApp.terminate(nil) }
}
