import AppKit
import ApplicationServices

// MARK: keep the Accessibility Keyboard in place

// While the touch display sleeps it can vanish from macOS for several seconds. Windows then move to a
// stand-in display, and the Accessibility Keyboard's panels come back centred; unlocking centres them
// again. MacTouch remembers where the panels sit while the display is settled and the screen unlocked,
// and moves them back after display changes, wake, unlock and launch.
let keyboardBundleID = "com.apple.inputmethod.AssistiveControl"
var keyboardPositions = defaults.dictionary(forKey: "keyboardPositions") as? [String: String] ?? [:]
var lastReconfig = now(), restoreGen = 0
var screenLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false

// Restore after each delay; a newer request cancels the older one's remaining passes.
func scheduleRestore(_ delays: [Double], _ why: String) {
    lastReconfig = now(); restoreGen += 1
    let g = restoreGen
    for d in delays {
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { if g == restoreGen { restoreKeyboard(why) } }
    }
}

func keyboardPanels() -> [(window: AXUIElement, origin: CGPoint, size: CGSize)] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: keyboardBundleID).first else { return [] }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &v) == .success,
          let windows = v as? [AXUIElement] else { return [] }
    let disp = CGDisplayBounds(targetDisplay())
    return windows.compactMap { w in
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        // Skip the transparent overlay layers: they span a whole display, possibly the stand-in one.
        if sz.width < 20 || sz.height < 20 || sz.width >= disp.width || sz.height >= disp.height { return nil }
        return (w, p, sz)
    }
}
// Panels are told apart by size: the minimized panel and the full keyboard each keep their own spot.
func panelKey(_ s: CGSize) -> String { "\(Int((s.width / 10).rounded()) * 10)x\(Int((s.height / 10).rounded()) * 10)" }

func rememberKeyboard() {
    guard cfg.keepKeyboard, AXIsProcessTrusted(), !screenLocked, now() - lastReconfig > 10 else { return }
    let d = CGDisplayBounds(targetDisplay())
    guard targetFound else { return }
    var changed = false
    for p in keyboardPanels() {
        // A panel exactly centred is where macOS puts it after a reset, not where the user left it.
        if abs(p.origin.x + p.size.width / 2 - d.midX) < 3 && abs(p.origin.y + p.size.height / 2 - d.midY) < 3 { continue }
        let k = panelKey(p.size), v = "\(Int(p.origin.x)),\(Int(p.origin.y))"
        if keyboardPositions[k] != v { keyboardPositions[k] = v; changed = true }
    }
    if changed { defaults.set(keyboardPositions, forKey: "keyboardPositions") }
}

func restoreKeyboard(_ why: String) {
    guard cfg.keepKeyboard, AXIsProcessTrusted(), !screenLocked else { return }
    _ = targetDisplay()
    guard targetFound else { return }
    for p in keyboardPanels() {
        guard let v = keyboardPositions[panelKey(p.size)]?.split(separator: ","), v.count == 2,
              let x = Double(v[0]), let y = Double(v[1]), abs(p.origin.x - x) > 3 || abs(p.origin.y - y) > 3 else { continue }
        var np = CGPoint(x: x, y: y)
        if let pv = AXValueCreate(.cgPoint, &np), AXUIElementSetAttributeValue(p.window, kAXPositionAttribute as CFString, pv) == .success {
            log("moved keyboard panel \(panelKey(p.size)) back to \(Int(x)),\(Int(y)) (\(why))")
        }
    }
}

// MARK: auto keyboard

// When a touch puts the focus in a text field, expand the Accessibility Keyboard from its minimized
// panel; when the focus leaves text fields, minimize it again, but only if MacTouch expanded it.
// The panels' buttons have no press action, so they get a click, and the pointer is put back.
let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
var wasEditable = false, autoExpanded = false, leftFieldAt = 0.0

func axString(_ e: AXUIElement, _ a: String) -> String {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? String ?? "" : ""
}

func focusIsEditable() -> Bool? {   // nil: focus is on the keyboard itself, so nothing changed
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &v) == .success
    else { return false }
    let e = v as! AXUIElement
    var pid: pid_t = 0
    AXUIElementGetPid(e, &pid)
    if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == keyboardBundleID { return nil }
    return editableRoles.contains(axString(e, kAXRoleAttribute))
}

// Frame of the keyboard button titled "Keyboard" (minimized panel) or "Minimize" (full panel).
func keyboardButton(_ title: String) -> CGRect? {
    func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        if axString(e, kAXRoleAttribute) == "AXButton" && axString(e, kAXTitleAttribute) == title { return e }
        var v: CFTypeRef?
        guard depth < 3, AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, depth + 1) { return f } }
        return nil
    }
    for p in keyboardPanels() {
        guard let b = find(p.window, 0) else { continue }
        var pv: CFTypeRef?, sv: CFTypeRef?
        var o = CGPoint.zero, sz = CGSize.zero
        if AXUIElementCopyAttributeValue(b, kAXPositionAttribute as CFString, &pv) == .success { AXValueGetValue(pv as! AXValue, .cgPoint, &o) }
        if AXUIElementCopyAttributeValue(b, kAXSizeAttribute as CFString, &sv) == .success { AXValueGetValue(sv as! AXValue, .cgSize, &sz) }
        return CGRect(origin: o, size: sz)
    }
    return nil
}

func clickKeyboard(_ r: CGRect) {
    let back = CGEvent(source: nil)?.location ?? .zero, p = CGPoint(x: r.midX, y: r.midY)
    post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p); post(.mouseMoved, back)
}

// Polling runs only when it can matter: every 0.25 s for 2.5 s after a tap, then every second while
// MacTouch has the keyboard expanded, otherwise not at all.
var autoKeyboardTimer: Timer?, autoKeyboardInterval = 0.0

func autoKeyboardTapped() {
    guard cfg.autoKeyboard else { return }
    if !autoExpanded, let e = focusIsEditable() { wasEditable = e }   // focus before this tap lands
    scheduleAutoKeyboard(0.25)
}

func scheduleAutoKeyboard(_ interval: Double) {
    guard interval != autoKeyboardInterval || autoKeyboardTimer == nil else { return }
    autoKeyboardTimer?.invalidate()
    autoKeyboardInterval = interval
    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
        autoKeyboardTick()
        if now() - lastTouchTap < 2.5 { scheduleAutoKeyboard(0.25) }
        else if autoExpanded && cfg.autoKeyboard { scheduleAutoKeyboard(1) }
        else { autoKeyboardTimer?.invalidate(); autoKeyboardTimer = nil; autoKeyboardInterval = 0 }
    }
    t.tolerance = interval * 0.2
    autoKeyboardTimer = t
}

func autoKeyboardTick() {
    guard cfg.autoKeyboard, !cfg.paused, AXIsProcessTrusted(), !screenLocked, !piano.active, !calibrator.active, !(sketch.active && !sketch.overlay),
          let editable = focusIsEditable() else { return }
    defer { wasEditable = editable }
    if editable {
        leftFieldAt = 0
        // Only when a touch moved the focus: with a hardware keyboard nobody wants the panel popping up.
        if !wasEditable && now() - lastTouchTap < 2, let b = keyboardButton("Keyboard") {
            clickKeyboard(b); autoExpanded = true; log("auto keyboard: expanded")
        }
    } else if autoExpanded {
        if keyboardButton("Keyboard") != nil { autoExpanded = false; return }   // minimized by hand
        if leftFieldAt == 0 { leftFieldAt = now() }
        if now() - leftFieldAt > 1.5, let b = keyboardButton("Minimize") {
            clickKeyboard(b); autoExpanded = false; log("auto keyboard: minimized")
        }
    }
}

// MARK: turning the keyboard on and off

// The Accessibility Keyboard's switch in System Settings ▸ Accessibility ▸ Keyboard, through the
// UniversalAccess functions System Settings calls. They are private, so MacTouch looks them up at run
// time and leaves the keyboard alone (the menu item disabled) where they are missing.
let keyboardSwitch: (isOn: @convention(c) () -> Bool, set: @convention(c) (Bool) -> Void)? = {
    guard let h = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess", RTLD_LAZY),
          let isOn = dlsym(h, "UAVirtualKeyboardIsEnabled"), let set = dlsym(h, "UAVirtualKeyboardSetEnabled") else {
        log("cannot switch the Accessibility Keyboard on and off on this macOS"); return nil
    }
    return (unsafeBitCast(isOn, to: (@convention(c) () -> Bool).self), unsafeBitCast(set, to: (@convention(c) (Bool) -> Void).self))
}()

/// Whether the Accessibility Keyboard is on; nil if MacTouch cannot tell.
func keyboardOn() -> Bool? { keyboardSwitch?.isOn() }

let keyboardWasMinimized = "keyboardWasMinimized", keyboardOffForNoTouchscreen = "keyboardOffForNoTouchscreen"

func setKeyboard(_ on: Bool, _ why: String) {
    guard let sw = keyboardSwitch, sw.isOn() != on else { return }
    if !on { defaults.set(keyboardButton("Keyboard") != nil, forKey: keyboardWasMinimized) }
    sw.set(on)
    log("Accessibility Keyboard \(on ? "on" : "off") (\(why))")
    guard on else { return }
    // It comes back expanded and centred: minimize it again if it was, and put its panels where they were.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        if defaults.bool(forKey: keyboardWasMinimized), AXIsProcessTrusted(), let b = keyboardButton("Minimize") { clickKeyboard(b) }
    }
    scheduleRestore([1.5, 4], "keyboard on")
}

// With no touchscreen connected for 10 s (longer than a replug or a controller changing mode), the
// keyboard goes off; it comes back when a touchscreen connects, if MacTouch turned it off. That is
// remembered across restarts, and turning it on by hand in between is left alone.
var noTouchscreenSince: Double?
func keyboardFollowTouchscreens() {
    guard cfg.keyboardFollowsTouch, hidOpen, !probe, !checkOnly else { return }
    let key = keyboardOffForNoTouchscreen
    if !touchDevices().isEmpty {
        noTouchscreenSince = nil
        if defaults.bool(forKey: key) { defaults.removeObject(forKey: key); setKeyboard(true, "a touchscreen is connected") }
    } else if let since = noTouchscreenSince {
        if now() - since > 10, keyboardOn() == true, !defaults.bool(forKey: key) {
            setKeyboard(false, "no touchscreen connected"); defaults.set(true, forKey: key)
        }
    } else {
        noTouchscreenSince = now()
    }
}
