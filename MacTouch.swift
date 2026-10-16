// MacTouch: drive a HID multi-touch digitizer (default: the ILITEK controller in Wisecoco touch
// displays, USB 222a:0001) as mouse, scroll and pinch-zoom input on macOS, which has no touchscreen
// driver of its own. Runs as a menu bar app; settings live in the defaults domain local.mactouch.
//
// Gestures
//   tap / double-tap        click / double click
//   1 finger, move          drag            (one-finger scroll: scroll)
//   1 finger, hold          right click     (one-finger scroll: hold+move = drag; hold+lift, or keep
//                                            holding still another 0.5 s, = right click)
//   2 fingers, move         scroll
//   2 fingers, pinch        zoom (trackpad magnify, or Cmd+/Cmd- per app)
//   2 fingers, tap          right click     (only with two-finger tap)
//   3-4 fingers, swipe      left/right: switch Space, up: Mission Control, down: App Exposé
//   window edge, move       resize the window (a touch near an edge is moved onto it)
//
// Command line (settings options apply to this run only, unless --save is given)
//   --check                 print displays, touch device, permissions and settings, then exit
//   --save [options]        store the given settings and exit     --reset   forget all settings and exit
//   --probe                 log contacts only, post no events     --raw     log every HID value
// Settings options (numbers may be decimal or 0x-hex; booleans take =false to turn off)
//   --vid=0x222a --pid=N    USB IDs of the touch controller (pid 0 or omitted: any)
//   --display=VEND:MODEL    CoreGraphics vendor:model of the touch display (default 0x2613:0x2023),
//                           or "main"; falls back to the main display if not connected
//   --flip-x --flip-y --swap   extra axis fixes, applied after the display's rotation
//   --cal=ax,bx,ay,by       error model touched = a*target + b in display fractions; inverted on every point
//   --one-finger-scroll     iPad-style one-finger scrolling (see above)
//   --two-finger-tap        two-finger tap = right click
//   --hold=0.6              long-press seconds
//   --scroll-scale=1.0      --invert-scroll
//   --zoom=gesture|keys|off --zoom-scale=1.0
//   --zoom-key-apps=A,B     apps (window owner names) where pinch sends Cmd+/Cmd- instead of magnify
//   --drag-apps=A,B         apps where one finger always drags and hold does nothing (default AssistiveControl,
//                           the Accessibility Keyboard)
//   --titlebar=44           touches this many points from the top of a normal window drag at once (0 = off)
//   --edge=12               touches this close to a window's side, bottom or top edge resize it (0 = off)
//   --swipes=3|4|off        multi-finger swipes with three or four fingers, four only, or off
//   --auto-keyboard         expand the minimized Accessibility Keyboard when a touch focuses a text field (default on)
//   --keep-keyboard         put the Accessibility Keyboard back where it was after the display sleeps (default on)
//   --ring-color=#FF6A00    hold cue ring colour: #RRGGBB or "accent" (default gauge orange)
//   --piano-octaves=3       piano mode keyboard size (1-6)        --piano-sound=0   General MIDI program
import AppKit
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
import ApplicationServices
import AVFoundation
import CoreMIDI

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: helpers

let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
func log(_ s: String) { print(stamp.string(from: Date()) + " " + s) }
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
let logPath = NSHomeDirectory() + "/Library/Logs/MacTouch.log"
let repoURL = "https://github.com/kashmeister/mactouch"

// MARK: settings

struct Config {
    var vid = 0x222A, pid = 0, display = "0x2613:0x2023"
    var flipX = false, flipY = false, swap = false
    var cal: [Double] = [1, 0, 1, 0]
    var oneFingerScroll = false, twoFingerTap = false, invertScroll = false, paused = false, keepKeyboard = true, autoKeyboard = true
    var pianoOctaves = 3, pianoSound = 0, pianoShift = 0, pianoDynamics = false
    var hold = 0.6, scrollScale = 1.0, zoomScale = 1.0, titlebar = 44.0
    var zoom = "gesture", swipes = "3", edge = 12.0, ringColor = "#FF6A00"
    var dragApps = ["AssistiveControl"], zoomKeyApps: [String] = []
}

let identityCal: [Double] = [1, 0, 1, 0]

enum Kind { case bool, double, int, string, zoom, swipes, list, cal, color }
let options: [(flag: String, key: String, kind: Kind)] = [
    ("--vid", "vid", .int), ("--pid", "pid", .int), ("--display", "display", .string),
    ("--flip-x", "flipX", .bool), ("--flip-y", "flipY", .bool), ("--swap", "swap", .bool), ("--cal", "cal", .cal),
    ("--one-finger-scroll", "oneFingerScroll", .bool), ("--two-finger-tap", "twoFingerTap", .bool),
    ("--hold", "hold", .double), ("--scroll-scale", "scrollScale", .double), ("--invert-scroll", "invertScroll", .bool),
    ("--zoom", "zoom", .zoom), ("--zoom-scale", "zoomScale", .double),
    ("--zoom-key-apps", "zoomKeyApps", .list), ("--drag-apps", "dragApps", .list), ("--titlebar", "titlebar", .double),
    ("--edge", "edge", .double), ("--swipes", "swipes", .swipes), ("--keep-keyboard", "keepKeyboard", .bool),
    ("--auto-keyboard", "autoKeyboard", .bool),
    ("--ring-color", "ringColor", .color),
    ("--piano-octaves", "pianoOctaves", .int), ("--piano-sound", "pianoSound", .int),
]
let actionFlags: Set<String> = ["--check", "--save", "--reset", "--probe", "--raw"]

func num(_ s: Substring) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }
func parse(_ s: String, _ kind: Kind) -> Any? {
    switch kind {
    case .bool: return ["", "1", "true", "yes", "on"].contains(s.lowercased()) ? true
                     : ["0", "false", "no", "off"].contains(s.lowercased()) ? false : nil
    case .double: return Double(s)
    case .int: return num(Substring(s))
    case .string: return s.isEmpty ? nil : s
    case .zoom: return ["gesture", "keys", "off"].contains(s) ? s : nil
    case .color:
        if s == "accent" { return s }
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        return h.count == 6 && UInt32(h, radix: 16) != nil ? "#" + h.uppercased() : nil
    case .swipes: return ["3", "4", "off"].contains(s) ? s : nil
    case .list: return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    case .cal:
        let v = s.split(separator: ",").compactMap { Double($0) }
        return v.count == 4 && v[0] != 0 && v[2] != 0 ? v : nil
    }
}

let args = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }   // Finder may add -psn_... etc.
var overrides: [String: Any] = [:]
for a in args where !actionFlags.contains(a) {
    let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
    guard let o = options.first(where: { $0.flag == parts[0] }) else { fail("unknown option \(a); see the header of MacTouch.swift") }
    guard let v = parse(parts.count > 1 ? parts[1] : "", o.kind) else { fail("invalid value in \(a)") }
    overrides[o.key] = v
}
let checkOnly = args.contains("--check"), probe = args.contains("--probe"), raw = args.contains("--raw")

let defaults = UserDefaults.standard
if args.contains("--reset") {
    for o in options { defaults.removeObject(forKey: o.key) }
    for k in ["paused", "previousCal", "keyboardPositions"] { defaults.removeObject(forKey: k) }
    print("settings reset"); exit(0)
}
if args.contains("--save") {
    if overrides["cal"] != nil, let old = defaults.array(forKey: "cal") { defaults.set(old, forKey: "previousCal") }
    for (k, v) in overrides { defaults.set(v, forKey: k) }
    print("saved: " + overrides.keys.sorted().joined(separator: ", ")); exit(0)
}
defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)

func loadConfig() -> Config {
    var c = Config()
    func rd<T>(_ k: String, _ p: WritableKeyPath<Config, T>) { if let v = defaults.object(forKey: k) as? T { c[keyPath: p] = v } }
    rd("vid", \.vid); rd("pid", \.pid); rd("display", \.display)
    rd("flipX", \.flipX); rd("flipY", \.flipY); rd("swap", \.swap); rd("cal", \.cal)
    rd("oneFingerScroll", \.oneFingerScroll); rd("twoFingerTap", \.twoFingerTap)
    rd("invertScroll", \.invertScroll); rd("paused", \.paused); rd("keepKeyboard", \.keepKeyboard)
    rd("hold", \.hold); rd("scrollScale", \.scrollScale); rd("zoomScale", \.zoomScale); rd("titlebar", \.titlebar)
    rd("ringColor", \.ringColor); rd("zoom", \.zoom); rd("swipes", \.swipes); rd("edge", \.edge); rd("dragApps", \.dragApps); rd("zoomKeyApps", \.zoomKeyApps)
    rd("pianoOctaves", \.pianoOctaves); rd("pianoSound", \.pianoSound); rd("pianoShift", \.pianoShift); rd("pianoDynamics", \.pianoDynamics); rd("autoKeyboard", \.autoKeyboard)
    c.pianoOctaves = min(max(c.pianoOctaves, 1), 6); c.pianoSound = min(max(c.pianoSound, 0), 127)
    if c.cal.count != 4 || c.cal[0] == 0 || c.cal[2] == 0 { c.cal = identityCal }
    return c
}
var cfg = loadConfig()

// Store a setting from the menu; it also beats any command-line value for the rest of this run.
func setSetting(_ key: String, _ value: Any) {
    defaults.set(value, forKey: key)
    var vol = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    vol.removeValue(forKey: key)
    defaults.setVolatileDomain(vol, forName: UserDefaults.argumentDomain)
    cfg = loadConfig()
    log("set \(key) = \(value)")
}

// Every calibration change keeps the one it replaces, so Undo Calibration can switch back.
var previousCal: [Double]? {
    let v = defaults.array(forKey: "previousCal") as? [Double]
    return v?.count == 4 && v![0] != 0 && v![2] != 0 ? v : nil
}
func setCalibration(_ new: [Double]) {
    if new != cfg.cal { defaults.set(cfg.cal, forKey: "previousCal") }
    setSetting("cal", new)
}

// MARK: target display

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return Array(ids.prefix(Int(n)))
}
func isTarget(_ d: CGDirectDisplayID) -> Bool {
    let p = cfg.display.split(separator: ":")
    guard p.count == 2, let v = num(p[0]), let m = num(p[1]) else { return false }
    return CGDisplayVendorNumber(d) == UInt32(v) && CGDisplayModelNumber(d) == UInt32(m)
}
var cachedDisplay: CGDirectDisplayID?, targetFound = false, lastLookup = 0.0
func targetDisplay() -> CGDirectDisplayID {
    // A fallback is retried every 2 s: around display sleep and wake the touch display can be
    // briefly missing, and a reconfiguration notice may not follow.
    if let d = cachedDisplay, targetFound || now() - lastLookup < 2 { return d }
    lastLookup = now()
    let d = cfg.display == "main" ? nil : onlineDisplays().first(where: isTarget)
    let found = d != nil || cfg.display == "main", use = d ?? CGMainDisplayID()
    if use != cachedDisplay || found != targetFound {
        log(found ? "using display \(use) rotation \(Int(CGDisplayRotation(use)))"
                  : "display \(cfg.display) not connected; using the main display \(use)")
    }
    targetFound = found; cachedDisplay = use
    return use
}
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { cachedDisplay = nil }
}, nil)
func screen(for d: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d }
}

struct Axis { var v = 0.0, lo = 0.0, hi = 1.0
    var norm: Double { hi > lo ? min(max((v - lo) / (hi - lo), 0), 1) : 0 } }
struct Slot { var tip = false, x = Axis(), y = Axis() }

// Panel-native fractions -> display fractions, before calibration.
func frac(_ s: Slot) -> CGPoint {
    var u = s.x.norm, v = s.y.norm
    switch Int(CGDisplayRotation(targetDisplay())) {   // the panel turns with the picture
    case 90: (u, v) = (1 - v, u)
    case 180: (u, v) = (1 - u, 1 - v)
    case 270: (u, v) = (v, 1 - u)
    default: break
    }
    if cfg.swap { swap(&u, &v) }
    if cfg.flipX { u = 1 - u }
    if cfg.flipY { v = 1 - v }
    return CGPoint(x: u, y: v)
}
func applyCal(_ f: CGPoint, _ c: [Double]) -> CGPoint {
    CGPoint(x: min(max((f.x - c[1]) / c[0], 0), 1), y: min(max((f.y - c[3]) / c[2], 0), 1))
}
func toScreen(_ f: CGPoint) -> CGPoint {
    let b = CGDisplayBounds(targetDisplay()), p = applyCal(f, cfg.cal)
    return CGPoint(x: (b.minX + p.x * (b.width - 1)).rounded(), y: (b.minY + p.y * (b.height - 1)).rounded())
}

// Owner of the topmost real window under p. Skips windows that cover the whole display: the Dock,
// Notification Center and the Accessibility Keyboard all keep transparent full-screen layers.
func windowAt(_ p: CGPoint) -> (owner: String, frame: CGRect, layer: Int)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let disp = CGDisplayBounds(targetDisplay())
    for w in list {
        guard let bd = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: bd as! CFDictionary) else { continue }
        if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 || r.contains(disp) { continue }
        if r.contains(p) { return (w[kCGWindowOwnerName as String] as? String ?? "", r, w[kCGWindowLayer as String] as? Int ?? 0) }
    }
    return nil
}
// A touch within cfg.edge points of a normal window's left, right or bottom edge, or just above its
// top edge, should resize it. Touches scatter by about that much, so the press is moved onto the
// edge (1 pt outside the frame, inside the resize zone). Returns that point, or nil.
func edgeGrab(_ p: CGPoint) -> CGPoint? {
    guard cfg.edge > 0,
          let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    let disp = CGDisplayBounds(targetDisplay()), t = cfg.edge
    for w in list {
        guard let bd = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: bd as! CFDictionary) else { continue }
        if (w[kCGWindowAlpha as String] as? Double ?? 1) == 0 || r.contains(disp) { continue }
        guard r.insetBy(dx: -t, dy: -t).contains(p) else { continue }
        guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { return nil }   // the topmost window here decides
        var q = p
        if abs(p.x - r.minX) <= t { q.x = r.minX - 1 } else if abs(p.x - r.maxX) <= t { q.x = r.maxX }
        if abs(p.y - r.maxY) <= t { q.y = r.maxY } else if p.y < r.minY { q.y = r.minY - 1 }
        return q == p ? nil : q
    }
    return nil
}

// Window owner name of a running app, as windowAt reports it.
func ownerName(of app: NSRunningApplication) -> String {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let w = list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier }
    return w?[kCGWindowOwnerName as String] as? String ?? app.localizedName ?? ""
}

// MARK: gesture state

enum Two { case undecided, scroll, zoom }
enum Mode {
    case idle
    case pending(CGPoint, Int)      // one finger down, not yet tap/move/hold (start, timer seq)
    case held(CGPoint)              // one-finger scroll: held still; move = drag, lift = right click
    case dragging
    case scroll1                    // one-finger scroll: scrolling with one finger
    case two(CGPoint, Double, Two)  // last centroid, start time, gesture kind
    case swipe(CGPoint, CGPoint, Bool)   // 3+ fingers: origin, last centroid, action fired
    case done                       // gesture consumed; wait for all fingers up
}

let heldRightClickSecs = 0.5   // one-finger scroll: holding still this long after the hold right-clicks
let moveTol = 10.0, tapMaxSecs = 0.35, dblSecs = 0.45, dblDist = 24.0, pinchTol = 25.0, zoomKeyStep = log(1.25)
var slots: [Int: Slot] = [:]   // keyed by finger collection cookie
var mode = Mode.idle, dirty = false, pressSeq = 0, lastN = 0
var lastPt = CGPoint.zero, twoStart = CGPoint.zero
var lastTapTime = 0.0, lastTapPt = CGPoint.zero, clicks: Int64 = 1
var accX = 0.0, accY = 0.0
var pinchStart = 0.0, pinchLast = 0.0, zoomKeyAcc = 0.0
var inDragApp = false, zoomHere = "gesture"   // decided per gesture from the window under the finger(s)
var edgeSnap: CGPoint?, dragOffset = CGPoint.zero   // window-edge resize: press point on the edge, finger offset
func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dragOffset.x, y: p.y + dragOffset.y) }
let src = CGEventSource(stateID: .hidSystemState)

// MARK: event output

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clickState: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: clickState) }
    e.post(tap: .cghidEventTap)
}

var lastTouchTap = 0.0
func tap(_ p: CGPoint) {
    lastTouchTap = now()
    let t = now()
    clicks = (t - lastTapTime < dblSecs && dist(p, lastTapPt) < dblDist) ? clicks + 1 : 1
    lastTapTime = t; lastTapPt = p
    post(.mouseMoved, p)
    post(.leftMouseDown, p, clickState: clicks)
    post(.leftMouseUp, p, clickState: clicks)
    log("tap x\(clicks) at \(Int(p.x)),\(Int(p.y))")
}

func rightClick(_ p: CGPoint, _ why: String) {
    post(.mouseMoved, p)
    post(.rightMouseDown, p, .right)
    post(.rightMouseUp, p, .right)
    log("right click (\(why)) at \(Int(p.x)),\(Int(p.y))")
}

func startDrag(_ from: CGPoint, _ to: CGPoint) {
    post(.leftMouseDown, from); post(.leftMouseDragged, to)
    mode = .dragging; log("drag start at \(Int(from.x)),\(Int(from.y))")
}

// Posted events don't count as user activity, so a touch alone would never wake a sleeping display
// or reset the idle timer. Declaring activity does both.
var activityID: IOPMAssertionID = 0
func declareUserActivity() {
    _ = IOPMAssertionDeclareUserActivity("MacTouch touch" as CFString, kIOPMUserActiveLocal, &activityID)
}

func endGesture() {   // release anything held, e.g. when pausing or the controller goes away
    if case .dragging = mode { post(.leftMouseUp, shifted(lastPt)) }
    mode = .idle
    holdRing.hide()
}

// Hold cue for one-finger scroll: once a hold registers, a ring under the finger fills over
// heldRightClickSecs. Moving while it shows drags; when it is full, the right click fires.
// "#RRGGBB" or "accent" (the system accent colour).
func color(_ spec: String) -> NSColor {
    if spec == "accent" { return .controlAccentColor }
    guard let v = UInt32(spec.dropFirst(), radix: 16) else { return .orange }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

final class HoldRing {
    let size: CGFloat = 120   // wider than a fingertip, so the ring stays visible around it
    var window: NSWindow?
    let track = CAShapeLayer(), progress = CAShapeLayer()

    func show(at p: CGPoint, duration: Double) {
        let w = window ?? make()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0   // CG is top-down, Cocoa bottom-up
        w.setFrame(NSRect(x: p.x - size / 2, y: primaryHeight - p.y - size / 2, width: size, height: size), display: false)
        progress.strokeColor = color(cfg.ringColor).cgColor
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0; fill.toValue = 1; fill.duration = duration
        progress.removeAllAnimations()
        progress.strokeEnd = 1
        progress.add(fill, forKey: "fill")
        w.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let path = CGMutablePath()   // from 12 o'clock, clockwise
        path.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: size / 2 - 10,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for (layer, color, width) in [(track, NSColor(white: 0, alpha: 0.35), 9.0), (progress, NSColor.white, 5.0)] {
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = width
            layer.lineCap = .round
            layer.contentsScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            v.layer?.addSublayer(layer)
        }
        w.contentView = v
        window = w
        return w
    }
}
let holdRing = HoldRing()

func scroll(_ dx: Double, _ dy: Double) {
    let dir = cfg.invertScroll ? -1.0 : 1.0
    accX += dx * cfg.scrollScale * dir; accY += dy * cfg.scrollScale * dir
    let ix = Int32(accX.rounded(.towardZero)), iy = Int32(accY.rounded(.towardZero))
    if ix == 0 && iy == 0 { return }
    accX -= Double(ix); accY -= Double(iy)
    guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.post(tap: .cghidEventTap)
}

// Trackpad-style magnify: NSEventTypeGesture (29) carrying kIOHIDEventTypeZoom (8). These CGEvent
// fields are private (110 = HID event type, 113 = magnification, 132 = phase), as used by Mac Mouse Fix.
let gestureType = unsafeBitCast(UInt32(29), to: CGEventType.self)
func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
func magnify(_ m: Double, phase: Int64, at p: CGPoint) {   // phase: 1 began, 2 changed, 4 ended
    guard let e = CGEvent(source: nil) else { return }
    e.type = gestureType
    e.location = p
    e.setIntegerValueField(field(110), value: 8)
    e.setIntegerValueField(field(132), value: phase)
    e.setDoubleValueField(field(113), value: m)
    e.post(tap: .cghidEventTap)
}

// Presses a key like a keyboard does: modifier keys go down first and come up last, so the system
// never believes ⌃ or ⌘ stays held. (Approach from macTouchScreen.)
func keyCombo(_ code: CGKeyCode, _ flags: CGEventFlags) {
    func send(_ c: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: down) else { return }
        if c == 59 || c == 55 { e.type = .flagsChanged }
        e.flags = f
        e.post(tap: .cghidEventTap)
    }
    let mods: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (55, .maskCommand)].filter { flags.contains($0.1) }
    var held: CGEventFlags = []
    for (m, f) in mods { held.insert(f); send(m, true, held) }
    send(code, true, flags); send(code, false, flags)
    for (m, f) in mods.reversed() { held.remove(f); send(m, false, held) }
}

func zoomKey(_ zoomIn: Bool) { keyCombo(zoomIn ? 24 : 27, .maskCommand) }   // Cmd+= / Cmd+-

// Launching Mission Control toggles it whatever the keyboard shortcuts are; argument "2" opens App
// Exposé for the frontmost app.
func missionControl(_ arguments: [String] = []) {
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = arguments
    config.activates = false
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                                       configuration: config) { _, error in if let error { log("Mission Control: \(error)") } }
}

// Fires the swipe action once the fingers have travelled far enough; returns whether it fired.
// Directions follow the trackpad: fingers moving left show the Space to the right.
func swipeAction(_ dx: Double, _ dy: Double, at c: CGPoint) -> Bool {
    let b = CGDisplayBounds(targetDisplay())
    let needX = min(b.width * 0.1, 160), needY = min(b.height * 0.12, 120)
    let arrows: CGEventFlags = [.maskControl, .maskSecondaryFn]   // exactly the system shortcut's flags
    post(.mouseMoved, c)   // act on the touched display
    if abs(dx) > needX && abs(dx) > 1.5 * abs(dy) {
        keyCombo(dx < 0 ? 124 : 123, arrows); log("swipe \(dx < 0 ? "left: next" : "right: previous") Space")
    } else if abs(dy) > needY && abs(dy) > 1.5 * abs(dx) {
        if dy < 0 { missionControl(); log("swipe up: Mission Control") } else { missionControl(["2"]); log("swipe down: App Exposé") }
    } else { return false }
    return true
}

func pinch(_ d: Double, at c: CGPoint) {
    defer { pinchLast = d }
    guard pinchLast > 0 else { return }
    switch zoomHere {
    case "keys":
        zoomKeyAcc += log(d / pinchLast) * cfg.zoomScale
        while zoomKeyAcc > zoomKeyStep { zoomKey(true); zoomKeyAcc -= zoomKeyStep }
        while zoomKeyAcc < -zoomKeyStep { zoomKey(false); zoomKeyAcc += zoomKeyStep }
    case "gesture":
        magnify((d / pinchLast - 1) * cfg.zoomScale, phase: 2, at: c)
    default: break
    }
}

// MARK: gesture recognition, run once per HID report

func commit() {
    dirty = false
    let fracs = slots.sorted { $0.key < $1.key }.filter { $0.value.tip }.map { frac($0.value) }
    let active = fracs.map(toScreen)
    let n = active.count
    defer {
        lastN = n; if n == 1 { lastPt = active[0] }
        if case .held = mode {} else { holdRing.hide() }
    }
    if calibrator.active { calibrator.feed(fracs); return }
    if piano.active {
        piano.feed(Dictionary(uniqueKeysWithValues: slots.filter { $0.value.tip }.map { ($0.key, toScreen(frac($0.value))) }))
        return
    }
    if probe {
        if n != lastN || n > 0 { log("contacts=\(n) " + active.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")) }
        return
    }
    if cfg.paused { mode = .idle; return }
    if n > 0 && lastN == 0 {   // touch-down
        let asleep = CGDisplayIsAsleep(targetDisplay()) != 0
        declareUserActivity()
        if asleep { mode = .done; log("touch woke the display"); return }   // wake only, like a phone
    }
    switch n {
    case 0:
        switch mode {
        case .pending(let s, _): tap(s)
        case .held(let s): rightClick(s, "long press")
        case .dragging: post(.leftMouseUp, shifted(lastPt)); log("drag end at \(Int(lastPt.x)),\(Int(lastPt.y))")
        case .swipe(_, _, let fired): if !fired { log("swipe end (too short)") }
        case .scroll1: log("scroll end (1 finger)")
        case .two(let c, let t0, let kind):
            switch kind {
            case .zoom: if zoomHere == "gesture" { magnify(0, phase: 4, at: c) }; log("zoom end")
            case .scroll: log("scroll end")
            case .undecided: if cfg.twoFingerTap && now() - t0 < tapMaxSecs { rightClick(twoStart, "two-finger tap") }
            }
        default: break
        }
        mode = .idle
    case 1:
        let p = active[0]
        switch mode {
        case .idle:
            post(.mouseMoved, p)
            dragOffset = .zero
            edgeSnap = edgeGrab(p)
            let win = windowAt(p), app = win?.owner ?? ""
            let onTitlebar = win.map { $0.layer == 0 && p.y - $0.frame.minY < cfg.titlebar } ?? false
            inDragApp = cfg.dragApps.contains(app) || onTitlebar || edgeSnap != nil
            if inDragApp { log("down in \(app)\(edgeSnap != nil ? " window edge" : onTitlebar ? " title bar" : ""): drag mode") }
            pressSeq += 1
            let seq = pressSeq
            mode = .pending(p, seq)
            DispatchQueue.main.asyncAfter(deadline: .now() + cfg.hold) {
                guard case .pending(let s, let q) = mode, q == seq, !inDragApp else { return }
                if cfg.oneFingerScroll {
                    mode = .held(s); log("hold at \(Int(s.x)),\(Int(s.y))")
                    holdRing.show(at: s, duration: heldRightClickSecs)
                    // Still holding without moving: right click now rather than waiting for the lift.
                    DispatchQueue.main.asyncAfter(deadline: .now() + heldRightClickSecs) {
                        guard case .held(let h) = mode, pressSeq == seq else { return }
                        holdRing.hide(); rightClick(h, "long press"); mode = .done
                    }
                } else { rightClick(s, "long press"); mode = .done }
            }
        case .pending(let s, _):
            if dist(p, s) > moveTol {
                if let snap = edgeSnap {   // resize: press on the edge, then keep the finger's offset
                    dragOffset = CGPoint(x: snap.x - s.x, y: snap.y - s.y)
                    post(.mouseMoved, snap); startDrag(snap, shifted(p))
                } else if cfg.oneFingerScroll && !inDragApp {
                    mode = .scroll1; accX = 0; accY = 0; scroll(p.x - s.x, p.y - s.y); log("scroll start (1 finger)")
                } else { startDrag(s, p) }
            }
        case .held(let s):
            if dist(p, s) > moveTol { startDrag(s, p) }
        case .dragging:
            if p != lastPt { post(.leftMouseDragged, shifted(p)) }
        case .scroll1:
            if lastN == 1 { scroll(p.x - lastPt.x, p.y - lastPt.y) }
        default: break   // one finger left over from a two-finger gesture
        }
    default:
        let c = CGPoint(x: active.map(\.x).reduce(0, +) / Double(n), y: active.map(\.y).reduce(0, +) / Double(n))
        let d = dist(active[0], active[1])
        let minFingers = cfg.swipes == "4" ? 4 : 3
        if case .swipe(let origin, let last, var fired) = mode {
            // Finger count changed: shift the origin so the travel so far is kept, not the centroid jump.
            let o = n == lastN ? origin : CGPoint(x: origin.x + c.x - last.x, y: origin.y + c.y - last.y)
            if !fired && n >= minFingers { fired = swipeAction(c.x - o.x, c.y - o.y, at: c) }
            mode = .swipe(o, c, fired)
            return
        }
        if cfg.swipes != "off" && n >= 3 {
            var start = false
            switch mode {
            case .two(_, _, .undecided), .idle, .pending, .held, .scroll1, .dragging: start = true
            default: break
            }
            if start {
                if case .dragging = mode { post(.leftMouseUp, shifted(lastPt)) }
                mode = .swipe(c, c, false); log("swipe start (\(n) fingers)")
                return
            }
        }
        switch mode {
        case .two(let last, let t0, var kind):
            if n == lastN {   // finger count changed -> re-anchor instead of jumping
                if case .undecided = kind {
                    let dd = abs(d - pinchStart), dc = dist(c, twoStart)
                    if cfg.zoom != "off" && dd > pinchTol && dd > dc {
                        kind = .zoom; pinchLast = d; zoomKeyAcc = 0
                        let app = windowAt(c)?.owner ?? ""
                        zoomHere = cfg.zoomKeyApps.contains(app) ? "keys" : cfg.zoom
                        if zoomHere == "gesture" { magnify(0, phase: 1, at: c) }
                        log("zoom start (\(zoomHere)) in \(app)")
                    } else if dc > moveTol {
                        kind = .scroll; log("scroll start (\(n) fingers)")
                    }
                }
                switch kind {
                case .scroll: scroll(c.x - last.x, c.y - last.y)
                case .zoom: pinch(d, at: c)
                case .undecided: break
                }
            } else if case .zoom = kind { pinchLast = d }
            mode = .two(c, t0, kind)
        case .done: break
        default:
            if case .dragging = mode { post(.leftMouseUp, shifted(lastPt)) }
            twoStart = c; pinchStart = d; pinchLast = 0; accX = 0; accY = 0
            post(.mouseMoved, c)
            mode = .two(c, now(), .undecided)
        }
    }
}

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

func autoKeyboardTick() {
    guard cfg.autoKeyboard, !cfg.paused, AXIsProcessTrusted(), !screenLocked, !piano.active, !calibrator.active,
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

// MARK: calibration wizard

// Full-screen targets on the touch display. Each tap's touch-down point, before calibration, is
// paired with its target; a per-axis least-squares line gives the new calibration.
final class CalibrationWindow: NSWindow { override var canBecomeKey: Bool { true } }

final class CalibrationView: NSView {
    weak var owner: Calibrator?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { owner?.cancel() } }   // Esc
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.07, alpha: 1).setFill(); bounds.fill()
        guard let c = owner else { return }
        NSColor.systemGreen.setFill()
        for p in c.dots {
            NSBezierPath(ovalIn: NSRect(x: p.x * bounds.width - 4, y: p.y * bounds.height - 4, width: 8, height: 8)).fill()
        }
        if let t = c.currentTarget {
            let x = t.x * bounds.width, y = t.y * bounds.height
            NSColor.systemRed.setFill()
            NSRect(x: x - 1, y: y - 22, width: 2, height: 44).fill()
            NSRect(x: x - 22, y: y - 1, width: 44, height: 2).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        let text = c.message as NSString, size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height * 0.3 - size.height / 2), withAttributes: attrs)
    }
}

final class Calibrator: NSObject {
    let targets: [CGPoint] = (0..<2).flatMap { _ in [0.1, 0.5, 0.9].flatMap { y in [0.05, 0.5, 0.95].map { x in CGPoint(x: x, y: y) } } }
    var window: NSWindow?, view: CalibrationView?, idle: Timer?
    var index = 0, finished = false, message = ""
    var samples: [(target: CGPoint, touch: CGPoint)] = [], dots: [CGPoint] = []
    var down: CGPoint?
    var active: Bool { window != nil && !finished }
    var currentTarget: CGPoint? { active && index < targets.count ? targets[index] : nil }

    func start() {
        guard window == nil else { return }
        guard let s = screen(for: targetDisplay()) ?? NSScreen.main else { return }
        endGesture()
        let w = CalibrationWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = CalibrationView(frame: NSRect(origin: .zero, size: s.frame.size))
        v.owner = self
        w.contentView = v
        w.setFrame(s.frame, display: true)
        window = w; view = v
        index = 0; finished = false; samples = []; dots = []; down = nil
        prompt()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        resetIdle()
        log("calibration started")
    }

    func prompt() {
        message = "Tap the centre of the red cross with your fingertip (\(index + 1) of \(targets.count)). Esc cancels."
        view?.needsDisplay = true
    }

    // Called once per HID report with the contacts' display fractions before calibration.
    func feed(_ fracs: [CGPoint]) {
        if let f = fracs.first { if down == nil { down = f }; return }
        guard let f = down, let t = currentTarget else { return }
        down = nil
        samples.append((t, f)); dots.append(applyCal(f, cfg.cal))
        index += 1
        resetIdle()
        if index == targets.count { finish() } else { prompt() }
    }

    func finish() {
        func fit(_ xs: [Double], _ ys: [Double]) -> (Double, Double) {   // ys = a*xs + b
            let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            let a = sxx > 0 ? sxy / sxx : 1
            return (a, my - a * mx)
        }
        let (ax, bx) = fit(samples.map { $0.target.x }, samples.map { $0.touch.x })
        let (ay, by) = fit(samples.map { $0.target.y }, samples.map { $0.touch.y })
        let new = [ax, bx, ay, by].map { ($0 * 10000).rounded() / 10000 }
        let b = CGDisplayBounds(targetDisplay())
        func meanError(_ c: [Double]) -> Double {
            samples.reduce(0) { s, x in
                let p = applyCal(x.touch, c)
                return s + hypot((p.x - x.target.x) * b.width, (p.y - x.target.y) * b.height)
            } / Double(samples.count)
        }
        let before = meanError(cfg.cal), after = meanError(new)
        finished = true
        if (0.8...1.25).contains(ax) && (0.8...1.25).contains(ay) && abs(bx) < 0.15 && abs(by) < 0.15 {
            setCalibration(new)
            message = String(format: "Saved. Average error on these taps: %.0f pt before, %.0f pt now.", before, after)
        } else {
            message = "These taps don't fit a calibration (check rotation and display); nothing was saved."
        }
        log("calibration finished: fit \(new), mean error \(Int(before)) -> \(Int(after)) pt")
        view?.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.close() }
    }

    func cancel() { log("calibration cancelled"); close() }

    func close() {
        idle?.invalidate(); idle = nil
        window?.orderOut(nil)
        window = nil; view = nil
    }

    func resetIdle() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.cancel() }
    }
}
let calibrator = Calibrator()

// MARK: piano mode

// A full-screen keyboard on the touch display. While it is open, touches bypass mouse emulation:
// every finger plays its own note (chords, both hands, glissando when a finger slides), through
// the General MIDI sounds that ship with macOS and a virtual MIDI source for other apps.
let pianoSounds: [(name: String, program: Int)] = [
    ("Grand Piano", 0), ("Electric Piano", 4), ("Harpsichord", 6), ("Vibraphone", 11),
    ("Organ", 16), ("Strings", 48), ("Choir", 52),
]
let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
let whiteSteps = [0, 2, 4, 5, 7, 9, 11]   // semitones of C D E F G A B
let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
func noteName(_ n: Int) -> String { noteNames[n % 12] + "\(n / 12 - 1)" }

enum PianoHit: Equatable { case note(Int), down, up, octaves, dynamics, sound, sustain, loop, clearLoop, done, none }

// Simple looper: arm it, play (recording starts on the first note), tap again to loop what you
// played while you keep playing over it.
enum LoopState { case empty, armed, recording(Double), playing, stopped }

final class PianoView: NSView {
    weak var owner: Piano?
    let toolbar: CGFloat = 44
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { owner?.close() } }   // Esc

    var whiteCount: Int { 7 * cfg.pianoOctaves + 1 }   // ends on a C
    var whiteWidth: CGFloat { bounds.width / CGFloat(whiteCount) }
    var keyTop: CGFloat { toolbar }
    var blackHeight: CGFloat { (bounds.height - toolbar) * 0.62 }

    // Toolbar buttons: octave shift, range and size on the left, sound in the middle, the rest on the right
    func bar(_ x: CGFloat, _ w: CGFloat) -> NSRect { NSRect(x: x, y: 4, width: w, height: toolbar - 8) }
    var downRect: NSRect { bar(8, 64) }
    var upRect: NSRect { bar(80, 64) }
    var rangeRect: NSRect { bar(152, 170) }
    var octavesRect: NSRect { bar(330, 150) }
    var dynamicsRect: NSRect { bar(488, 150) }
    var soundRect: NSRect { bar(bounds.midX - 130, 260) }
    var doneRect: NSRect { bar(bounds.maxX - 128, 120) }
    var clearRect: NSRect { bar(doneRect.minX - 72, 64) }
    var loopRect: NSRect { bar(clearRect.minX - 228, 220) }
    var sustainRect: NSRect { bar(loopRect.minX - 128, 120) }

    func whiteNote(_ i: Int) -> Int { (owner?.start ?? 48) + 12 * (i / 7) + whiteSteps[i % 7] }
    func hasBlack(_ i: Int) -> Bool { [0, 1, 3, 4, 5].contains(i % 7) && i < whiteCount - 1 }
    func blackRect(_ i: Int) -> NSRect {
        let w = whiteWidth * 0.6
        return NSRect(x: CGFloat(i + 1) * whiteWidth - w / 2, y: keyTop, width: w, height: blackHeight)
    }

    func hit(_ p: CGPoint) -> PianoHit {
        if p.y < toolbar {
            for (r, h) in [(downRect, PianoHit.down), (upRect, .up), (octavesRect, .octaves), (dynamicsRect, .dynamics), (soundRect, .sound),
                           (sustainRect, .sustain), (loopRect, .loop), (clearRect, .clearLoop), (doneRect, .done)]
            where r.contains(p) { return h == .clearLoop && !(owner?.hasLoop ?? false) ? .none : h }
            return .none
        }
        let i = min(max(Int(p.x / whiteWidth), 0), whiteCount - 1)
        if p.y < keyTop + blackHeight {   // black keys sit on top of the whites
            for j in [i - 1, i] where j >= 0 && hasBlack(j) && blackRect(j).contains(p) { return .note(whiteNote(j) + 1) }
        }
        return .note(whiteNote(i))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill(); bounds.fill()
        guard let o = owner else { return }
        let lit = color(cfg.ringColor), keyH = bounds.height - toolbar
        for i in 0..<whiteCount {
            let r = NSRect(x: CGFloat(i) * whiteWidth, y: keyTop, width: whiteWidth, height: keyH).insetBy(dx: 1, dy: 0)
            let level = o.sounding(whiteNote(i))
            (level == 2 ? lit : level == 1 ? lit.blended(withFraction: 0.55, of: .white)! : NSColor(white: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            if whiteNote(i) % 12 == 0 {
                label(noteName(whiteNote(i)), in: NSRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 20),
                      size: 13, color: NSColor(white: 0.45, alpha: 1))
            }
        }
        for i in 0..<whiteCount where hasBlack(i) {
            let level = o.sounding(whiteNote(i) + 1)
            (level == 2 ? lit.blended(withFraction: 0.35, of: .black)! : level == 1 ? lit.blended(withFraction: 0.65, of: .black)!
                : NSColor(white: 0.12, alpha: 1)).setFill()
            NSBezierPath(roundedRect: blackRect(i), xRadius: 3, yRadius: 3).fill()
        }
        let range = "\(noteName(o.start)) – \(noteName(o.start + 12 * cfg.pianoOctaves))"
        button("◀", downRect); button("▶", upRect)
        label(range, in: rangeRect, size: 17, color: .white)
        button("\(cfg.pianoOctaves) octave\(cfg.pianoOctaves == 1 ? "" : "s")", octavesRect)
        button("Dynamics", dynamicsRect, on: cfg.pianoDynamics)
        button("♪ " + (pianoSounds.first { $0.program == cfg.pianoSound }?.name ?? "Program \(cfg.pianoSound)"), soundRect)
        button("Sustain", sustainRect, on: o.sustain)
        switch o.loop {
        case .empty: button("● Loop", loopRect)
        case .armed: button("● Play to record", loopRect, fill: .systemRed)
        case .recording: button("■ Stop recording", loopRect, fill: .systemRed)
        case .playing: button(String(format: "■ Stop loop (%.1f s)", o.loopLength), loopRect, on: true)
        case .stopped: button(String(format: "▶ Play loop (%.1f s)", o.loopLength), loopRect)
        }
        if o.hasLoop { button("✕", clearRect) }
        button("Done", doneRect)
    }

    func button(_ title: String, _ r: NSRect, on: Bool = false, fill: NSColor? = nil) {
        (fill ?? (on ? color(cfg.ringColor) : NSColor(white: 0.22, alpha: 1))).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        label(title, in: r, size: 17, color: on ? .black : .white)
    }

    func label(_ s: String, in r: NSRect, size: CGFloat, color: NSColor, align: NSTextAlignment = .center) {
        let para = NSMutableParagraphStyle(); para.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                    .foregroundColor: color, .paragraphStyle: para]
        let h = (s as NSString).size(withAttributes: attrs).height
        (s as NSString).draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: attrs)
    }
}

final class Piano: NSObject {
    var window: NSWindow?, view: PianoView?
    var active: Bool { window != nil }
    let engine = AVAudioEngine(), sampler = AVAudioUnitSampler()
    var audioReady = false, loadedProgram = -1
    var midiClient = MIDIClientRef(), midiSource = MIDIEndpointRef()
    var fingers: [Int: PianoHit] = [:]   // slot -> what that finger is on
    var counts: [Int: Int] = [:]         // note -> fingers holding it
    var sustain = false
    var loop = LoopState.empty, loopEvents: [(t: Double, note: Int, velocity: UInt8)] = [], loopLength = 0.0
    var loopGen = 0, loopSounding: Set<Int> = []
    var hasLoop: Bool { switch loop { case .playing, .stopped: return true; default: return false } }
    var base: Int { 60 - 12 * (cfg.pianoOctaves / 2) }   // middle C near the centre
    func startFor(shift: Int) -> Int { base + 12 * shift }
    func shiftAllowed(_ shift: Int) -> Bool { (12...(108 - 12 * cfg.pianoOctaves)).contains(startFor(shift: shift)) }
    var start: Int { min(max(startFor(shift: cfg.pianoShift), 12), 108 - 12 * cfg.pianoOctaves) }

    func sounding(_ n: Int) -> Int { (counts[n] ?? 0) > 0 ? 2 : loopSounding.contains(n) ? 1 : 0 }   // 2 you, 1 loop

    func open() {
        guard window == nil, let s = screen(for: targetDisplay()) ?? NSScreen.main else { return }
        endGesture()
        setUpAudio()
        let w = CalibrationWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PianoView(frame: NSRect(origin: .zero, size: s.frame.size))
        v.owner = self
        w.contentView = v
        w.setFrame(s.frame, display: true)
        window = w; view = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        log("piano open: \(cfg.pianoOctaves) octaves from \(noteName(start))")
    }

    func close() {
        allOff()
        if sustain { setSustain(false) }
        if case .playing = loop { stopLoop(); loop = .stopped }
        if case .recording = loop { loop = .empty; loopEvents = [] }
        if case .armed = loop { loop = .empty }
        window?.orderOut(nil)
        window = nil; view = nil
        log("piano closed")
    }

    func setUpAudio() {
        if !audioReady {
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            MIDIClientCreate("MacTouch" as CFString, nil, nil, &midiClient)
            MIDISourceCreateWithProtocol(midiClient, "MacTouch Piano" as CFString, ._1_0, &midiSource)
            audioReady = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { log("piano audio failed to start: \(error)") }
        }
        if loadedProgram != cfg.pianoSound {
            do {
                try sampler.loadSoundBankInstrument(at: soundBank, program: UInt8(cfg.pianoSound),
                                                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                loadedProgram = cfg.pianoSound
            } catch { log("piano sound \(cfg.pianoSound) failed to load: \(error)") }
        }
    }

    func settingsChanged() {
        guard active else { return }
        allOff(); setUpAudio(); view?.needsDisplay = true
    }

    // MIDI 1.0 channel voice message on the virtual source, channel 1.
    func midi(_ status: UInt8, _ a: UInt8, _ b: UInt8) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2) << 28 | UInt32(status) << 16 | UInt32(a) << 8 | UInt32(b)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(midiSource, &list)
    }

    func noteOn(_ n: Int, velocity: UInt8) {
        counts[n, default: 0] += 1
        guard counts[n] == 1 else { return }
        if case .armed = loop { loop = .recording(now()); view?.needsDisplay = true }
        if case .recording(let t0) = loop { loopEvents.append((now() - t0, n, velocity)) }
        sampler.startNote(UInt8(n), withVelocity: velocity, onChannel: 0)
        midi(0x90, UInt8(n), velocity)
    }

    func noteOff(_ n: Int) {
        guard let c = counts[n], c > 0 else { return }
        counts[n] = c - 1
        guard c == 1 else { return }
        if case .recording(let t0) = loop { loopEvents.append((now() - t0, n, 0)) }
        sampler.stopNote(UInt8(n), onChannel: 0)
        midi(0x80, UInt8(n), 0)
    }

    func allOff() {
        for (n, c) in counts where c > 0 { counts[n] = 1; noteOff(n) }
        fingers.removeAll()
    }

    // MARK: looper

    func loopTapped() {
        switch loop {
        case .empty: loop = .armed
        case .armed: loop = .empty
        case .recording(let t0):
            loopLength = now() - t0
            let held = Set(loopEvents.map(\.note)).filter { n in loopEvents.last { $0.note == n }?.velocity ?? 0 > 0 }
            loopEvents += held.map { (loopLength, $0, 0) }   // close notes still held at the loop point
            if loopLength < 0.2 || loopEvents.isEmpty { clearLoop(); return }
            loop = .playing; startLoop()
            log(String(format: "loop recorded: %.2f s, %d notes", loopLength, loopEvents.filter { $0.velocity > 0 }.count))
        case .playing: stopLoop(); loop = .stopped
        case .stopped: loop = .playing; startLoop()
        }
    }

    func clearLoop() { stopLoop(); loop = .empty; loopEvents = []; loopLength = 0 }

    // Each pass is scheduled from the previous pass's start, so the loop does not drift.
    func startLoop() { loopGen += 1; pass(from: .now(), gen: loopGen) }
    func pass(from start: DispatchTime, gen: Int) {
        for e in loopEvents {
            DispatchQueue.main.asyncAfter(deadline: start + e.t) { [weak self] in
                guard let self, gen == self.loopGen else { return }
                self.loopNote(e.note, e.velocity)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: start + loopLength) { [weak self] in
            guard let self, gen == self.loopGen else { return }
            self.pass(from: start + self.loopLength, gen: gen)
        }
    }

    func loopNote(_ n: Int, _ velocity: UInt8) {
        if velocity > 0 {
            sampler.startNote(UInt8(n), withVelocity: velocity, onChannel: 0)
            midi(0x90, UInt8(n), velocity); loopSounding.insert(n)
        } else {
            if (counts[n] ?? 0) == 0 { sampler.stopNote(UInt8(n), onChannel: 0) }   // unless you are holding it
            midi(0x80, UInt8(n), 0); loopSounding.remove(n)
        }
        view?.needsDisplay = true
    }

    func stopLoop() {
        loopGen += 1
        for n in loopSounding { loopNote(n, 0) }
    }

    func setSustain(_ on: Bool) {
        sustain = on
        sampler.sendController(64, withValue: on ? 127 : 0, onChannel: 0)
        midi(0xB0, 64, on ? 127 : 0)
    }

    // With Dynamics on, the front of a key (bottom of the screen) plays louder, like striking it harder.
    func velocity(_ p: CGPoint) -> UInt8 {
        guard cfg.pianoDynamics, let v = view else { return 100 }
        let f = min(max((p.y - v.keyTop) / (v.bounds.height - v.keyTop), 0), 1)
        return UInt8(45 + 82 * f)
    }

    // Called once per HID report with every touching finger: slot -> global screen point.
    func feed(_ touches: [Int: CGPoint]) {
        guard let v = view, let w = window else { return }
        let origin = w.frame.origin, primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var changed = false
        for (slot, g) in touches {
            let p = CGPoint(x: g.x - origin.x, y: g.y - (primaryHeight - origin.y - w.frame.height))   // view coords
            let h = v.hit(p)
            if let old = fingers[slot] {
                guard case .note = old, case .note(let n) = h, old != h else { continue }   // slide onto another key
                if case .note(let o) = old { noteOff(o) }
                noteOn(n, velocity: velocity(p)); fingers[slot] = h; changed = true
                continue
            }
            declareUserActivity()
            fingers[slot] = h; changed = true
            switch h {
            case .note(let n): noteOn(n, velocity: velocity(p))
            case .down, .up:
                let shift = cfg.pianoShift + (h == .up ? 1 : -1)
                if shiftAllowed(shift) { allOff(); setSetting("pianoShift", shift) }
            case .sound:
                let i = pianoSounds.firstIndex { $0.program == cfg.pianoSound } ?? -1
                setSetting("pianoSound", pianoSounds[(i + 1) % pianoSounds.count].program)
                settingsChanged()
            case .sustain: setSustain(!sustain)
            case .loop: loopTapped()
            case .clearLoop: clearLoop()
            case .dynamics: setSetting("pianoDynamics", !cfg.pianoDynamics)
            case .octaves:
                allOff()
                setSetting("pianoOctaves", cfg.pianoOctaves % 6 + 1)
                if !shiftAllowed(cfg.pianoShift) { setSetting("pianoShift", 0) }
            case .done: close(); mode = .done; return   // ignore the fingers still down
            case .none: break
            }
        }
        for (slot, h) in fingers where touches[slot] == nil {   // lifted
            if case .note(let n) = h { noteOff(n) }
            fingers[slot] = nil; changed = true
        }
        if changed { v.needsDisplay = true }
    }
}
let piano = Piano()

// MARK: HID input

// The controller reports up to 10 contacts, each in its own Finger collection (0x0D/0x22) holding
// Tip Switch (0x0D/0x42), X (0x01/0x30) and Y (0x01/0x31). Values arrive one by one; all values of
// a report are delivered in one run loop pass, so commit() runs once per report.
let valueCB: IOHIDValueCallback = { _, _, _, value in
    let e = IOHIDValueGetElement(value)
    let pg = IOHIDElementGetUsagePage(e), u = IOHIDElementGetUsage(e)
    let iv = IOHIDValueGetIntegerValue(value)
    let par = IOHIDElementGetParent(e)
    if raw {
        let pp = par.map { hex(IOHIDElementGetUsagePage($0)) + "/" + hex(IOHIDElementGetUsage($0)) + "#\(IOHIDElementGetCookie($0))" } ?? "-"
        log("rid=\(IOHIDElementGetReportID(e)) page=\(hex(pg)) usage=\(hex(u)) v=\(iv) parent=\(pp)")
    }
    guard let par = par, IOHIDElementGetUsagePage(par) == 0x0D, IOHIDElementGetUsage(par) == 0x22 else { return }
    let key = Int(IOHIDElementGetCookie(par))
    var s = slots[key] ?? Slot()
    let lo = Double(IOHIDElementGetLogicalMin(e)), hi = Double(IOHIDElementGetLogicalMax(e))
    switch (pg, u) {
    case (0x0D, 0x42): s.tip = iv != 0
    case (0x01, 0x30): s.x = Axis(v: Double(iv), lo: lo, hi: hi)
    case (0x01, 0x31): s.y = Axis(v: Double(iv), lo: lo, hi: hi)
    default: return
    }
    slots[key] = s
    if !dirty { dirty = true; DispatchQueue.main.async { commit() } }
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
var match: [String: Any] = [kIOHIDVendorIDKey: cfg.vid]
if cfg.pid != 0 { match[kIOHIDProductIDKey] = cfg.pid }
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
func touchDevices() -> [IOHIDDevice] { Array((IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []) }
var hidOpen = false

if checkOnly {
    for d in onlineDisplays() {
        let b = CGDisplayBounds(d)
        print("display \(d): vendor \(hex(CGDisplayVendorNumber(d))) model \(hex(CGDisplayModelNumber(d)))",
              "rotation \(Int(CGDisplayRotation(d))) bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))",
              CGDisplayIsBuiltin(d) != 0 ? "built-in" : "", isTarget(d) ? "<- target" : "")
    }
    let devs = touchDevices()
    print("touch devices matching vid \(hex(UInt32(cfg.vid)))\(cfg.pid != 0 ? " pid " + hex(UInt32(cfg.pid)) : ""): \(devs.count)")
    for dev in devs { print("  \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) ?? "?" as CFTypeRef)") }
    let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    print("Input Monitoring: \(im == kIOHIDAccessTypeGranted ? "granted" : im == kIOHIDAccessTypeDenied ? "denied" : "not decided")")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
    print("(run from a terminal, permissions are the terminal's; the log is authoritative)")
    print("settings: \(cfg)")
    exit(0)
}

// MARK: menu bar app

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
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in rememberKeyboard() }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in autoKeyboardTick() }
        updateIcon()
    }

    func startHID() {
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
            log("attached \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) ?? "?" as CFTypeRef)")
            (NSApp.delegate as? AppDelegate)?.updateIcon()
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, _ in
            endGesture(); slots.removeAll(); lastN = 0
            log("touch controller removed")
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.updateIcon() }
        }, nil)
        IOHIDManagerRegisterInputValueCallback(mgr, valueCB, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        log("start \(Bundle.main.bundleIdentifier ?? "unbundled") probe=\(probe) settings: \(cfg)")
        // Input Monitoring applies to new processes only, and a running process never sees the grant:
        // exit after a while (non-zero, so launchd restarts us) and let a fresh process try again.
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("Input Monitoring missing; enable MacTouch in System Settings > Privacy & Security > Input Monitoring")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in exit(75) }
            return
        }
        hidOpen = true
        log("Input Monitoring granted; HID manager open")
        // Accessibility applies to the running process.
        if !probe && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            log("Accessibility missing; enable MacTouch in System Settings > Privacy & Security > Accessibility")
            axTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                t.invalidate(); log("Accessibility granted"); self?.updateIcon()
            }
        }
        log("ready; display \(targetDisplay()) rotation \(Int(CGDisplayRotation(targetDisplay())))")
    }

    var status: String {
        if !hidOpen { return "Waiting for Input Monitoring permission" }
        if !probe && !AXIsProcessTrusted() { return "Waiting for Accessibility permission" }
        if touchDevices().isEmpty { return "No touch screen connected" }
        if cfg.paused { return "Paused" }
        if probe { return "Probe mode: logging only" }
        let d = targetDisplay()
        let name = screen(for: d)?.localizedName ?? "display \(d)"
        return targetFound ? "Touch active on \(name)" : "Touch display not found; using \(name)"
    }

    func updateIcon() {
        let ok = status.hasPrefix("Touch active")
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
        add(menu, status, nil)
        menu.addItem(.separator())
        add(menu, "Pause Touch", #selector(toggle(_:)), on: cfg.paused, obj: "paused")
        menu.addItem(.separator())
        add(menu, "One-Finger Scroll", #selector(toggle(_:)), on: cfg.oneFingerScroll, obj: "oneFingerScroll")
        add(menu, "Two-Finger Tap Right-Clicks", #selector(toggle(_:)), on: cfg.twoFingerTap, obj: "twoFingerTap")
        add(menu, "Invert Scrolling", #selector(toggle(_:)), on: cfg.invertScroll, obj: "invertScroll")
        add(menu, "Keep Keyboard Position", #selector(toggle(_:)), on: cfg.keepKeyboard, obj: "keepKeyboard")
        add(menu, "Auto Keyboard", #selector(toggle(_:)), on: cfg.autoKeyboard, obj: "autoKeyboard")
        choices(menu, "Pinch", "zoom", cfg.zoom, [("Trackpad Zoom", "gesture"), ("⌘+ / ⌘− Keys", "keys"), ("Off", "off")])
        choices(menu, "Long Press", "hold", cfg.hold, [0.4, 0.5, 0.6, 0.8, 1.0].map { (String(format: "%.1f s", $0), $0) })
        ringColors(menu)
        choices(menu, "Scroll Speed", "scrollScale", cfg.scrollScale, [0.5, 0.75, 1.0, 1.5, 2.0].map { ("\($0)×", $0) })
        choices(menu, "Multi-Finger Swipes", "swipes", cfg.swipes, [("Three or Four Fingers", "3"), ("Four Fingers Only", "4"), ("Off", "off")])
        add(menu, "Resize Windows at Edges", #selector(toggleEdge(_:)), on: cfg.edge > 0)
        menu.addItem(.separator())
        appList(menu, "Drag Apps", "dragApps", cfg.dragApps, "In these apps one finger always drags.")
        appList(menu, "Zoom-Key Apps", "zoomKeyApps", cfg.zoomKeyApps, "In these apps pinch sends ⌘+ / ⌘−.")
        menu.addItem(.separator())
        add(menu, piano.active ? "Close Piano" : "Piano…", #selector(togglePiano(_:)), enabled: hidOpen && !touchDevices().isEmpty)
        menu.addItem(.separator())
        add(menu, "Calibrate Touch…", #selector(calibrate(_:)), enabled: hidOpen && !touchDevices().isEmpty)
        add(menu, "Undo Calibration", #selector(undoCalibration(_:)), enabled: previousCal.map { $0 != cfg.cal } ?? false)
        add(menu, "Reset Calibration", #selector(resetCalibration(_:)), enabled: cfg.cal != identityCal)
        menu.addItem(.separator())
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

    func choices<T: Equatable>(_ menu: NSMenu, _ title: String, _ key: String, _ current: T, _ opts: [(String, T)]) {
        let sub = NSMenu(); sub.autoenablesItems = false
        for (label, v) in opts { add(sub, label, #selector(choose(_:)), on: v == current, obj: [key, v] as [Any]) }
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = sub
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

    func value(_ key: String) -> Bool {
        switch key {
        case "paused": return cfg.paused
        case "oneFingerScroll": return cfg.oneFingerScroll
        case "twoFingerTap": return cfg.twoFingerTap
        case "invertScroll": return cfg.invertScroll
        case "keepKeyboard": return cfg.keepKeyboard
        case "autoKeyboard": return cfg.autoKeyboard
        default: return false
        }
    }

    @objc func toggle(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String else { return }
        if key == "paused" { endGesture() }
        setSetting(key, !value(key))
        updateIcon()
    }
    @objc func toggleEdge(_ s: NSMenuItem) { setSetting("edge", cfg.edge > 0 ? 0.0 : 12.0) }
    @objc func choose(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [Any], let key = kv[0] as? String else { return }
        setSetting(key, kv[1])
        if key.hasPrefix("piano") { piano.settingsChanged() }
    }
    @objc func togglePiano(_ s: NSMenuItem) { piano.active ? piano.close() : piano.open() }
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
    @objc func calibrate(_ s: NSMenuItem) { calibrator.start() }
    @objc func resetCalibration(_ s: NSMenuItem) { setCalibration(identityCal) }
    @objc func undoCalibration(_ s: NSMenuItem) { if let p = previousCal { setCalibration(p) } }   // a second undo redoes
    @objc func openLog(_ s: NSMenuItem) {
        let url = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: logPath) ? url : url.deletingLastPathComponent())
    }
    @objc func openRepo(_ s: NSMenuItem) { NSWorkspace.shared.open(URL(string: repoURL)!) }
    @objc func quit(_ s: NSMenuItem) { endGesture(); log("quit from menu"); NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
