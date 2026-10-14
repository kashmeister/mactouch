// MacTouch: drive a HID multi-touch digitizer (default: the ILITEK controller in Wisecoco touch
// displays, USB 222a:0001) as mouse, scroll and pinch-zoom input on macOS, which has no touchscreen
// driver of its own. Runs as a menu bar app; settings live in the defaults domain local.mactouch.
//
// Gestures
//   tap / double-tap        click / double click
//   1 finger, move          drag            (one-finger scroll: scroll)
//   1 finger, hold          right click     (one-finger scroll: hold+move = drag, hold+lift = right click)
//   2 fingers, move         scroll
//   2 fingers, pinch        zoom (trackpad magnify, or Cmd+/Cmd- per app)
//   2 fingers, tap          right click     (only with two-finger tap)
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
import AppKit
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
import ApplicationServices

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
    var oneFingerScroll = false, twoFingerTap = false, invertScroll = false, paused = false
    var hold = 0.6, scrollScale = 1.0, zoomScale = 1.0, titlebar = 44.0
    var zoom = "gesture"
    var dragApps = ["AssistiveControl"], zoomKeyApps: [String] = []
}

let identityCal: [Double] = [1, 0, 1, 0]

enum Kind { case bool, double, int, string, zoom, list, cal }
let options: [(flag: String, key: String, kind: Kind)] = [
    ("--vid", "vid", .int), ("--pid", "pid", .int), ("--display", "display", .string),
    ("--flip-x", "flipX", .bool), ("--flip-y", "flipY", .bool), ("--swap", "swap", .bool), ("--cal", "cal", .cal),
    ("--one-finger-scroll", "oneFingerScroll", .bool), ("--two-finger-tap", "twoFingerTap", .bool),
    ("--hold", "hold", .double), ("--scroll-scale", "scrollScale", .double), ("--invert-scroll", "invertScroll", .bool),
    ("--zoom", "zoom", .zoom), ("--zoom-scale", "zoomScale", .double),
    ("--zoom-key-apps", "zoomKeyApps", .list), ("--drag-apps", "dragApps", .list), ("--titlebar", "titlebar", .double),
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
    defaults.removeObject(forKey: "paused"); defaults.removeObject(forKey: "previousCal")
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
    rd("invertScroll", \.invertScroll); rd("paused", \.paused)
    rd("hold", \.hold); rd("scrollScale", \.scrollScale); rd("zoomScale", \.zoomScale); rd("titlebar", \.titlebar)
    rd("zoom", \.zoom); rd("dragApps", \.dragApps); rd("zoomKeyApps", \.zoomKeyApps)
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
var cachedDisplay: CGDirectDisplayID?, targetFound = false
func targetDisplay() -> CGDirectDisplayID {
    if let d = cachedDisplay { return d }
    let d = cfg.display == "main" ? nil : onlineDisplays().first(where: isTarget)
    targetFound = d != nil || cfg.display == "main"
    if !targetFound { log("display \(cfg.display) not connected; using the main display") }
    cachedDisplay = d ?? CGMainDisplayID()
    return cachedDisplay!
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
    case done                       // gesture consumed; wait for all fingers up
}

let moveTol = 10.0, tapMaxSecs = 0.35, dblSecs = 0.45, dblDist = 24.0, pinchTol = 25.0, zoomKeyStep = log(1.25)
var slots: [Int: Slot] = [:]   // keyed by finger collection cookie
var mode = Mode.idle, dirty = false, pressSeq = 0, lastN = 0
var lastPt = CGPoint.zero, twoStart = CGPoint.zero
var lastTapTime = 0.0, lastTapPt = CGPoint.zero, clicks: Int64 = 1
var accX = 0.0, accY = 0.0
var pinchStart = 0.0, pinchLast = 0.0, zoomKeyAcc = 0.0
var inDragApp = false, zoomHere = "gesture"   // decided per gesture from the window under the finger(s)
let src = CGEventSource(stateID: .hidSystemState)

// MARK: event output

func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clickState: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: clickState) }
    e.post(tap: .cghidEventTap)
}

func tap(_ p: CGPoint) {
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
    if case .dragging = mode { post(.leftMouseUp, lastPt) }
    mode = .idle
}

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

func zoomKey(_ zoomIn: Bool) {   // Cmd+= / Cmd+-
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: zoomIn ? 24 : 27, keyDown: down) else { continue }
        e.flags = .maskCommand
        e.post(tap: .cghidEventTap)
    }
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
    defer { lastN = n; if n == 1 { lastPt = active[0] } }
    if calibrator.active { calibrator.feed(fracs); return }
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
        case .dragging: post(.leftMouseUp, lastPt); log("drag end at \(Int(lastPt.x)),\(Int(lastPt.y))")
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
            let win = windowAt(p), app = win?.owner ?? ""
            let onTitlebar = win.map { $0.layer == 0 && p.y - $0.frame.minY < cfg.titlebar } ?? false
            inDragApp = cfg.dragApps.contains(app) || onTitlebar
            if inDragApp { log("down in \(app)\(onTitlebar ? " title bar" : ""): drag mode") }
            pressSeq += 1
            let seq = pressSeq
            mode = .pending(p, seq)
            DispatchQueue.main.asyncAfter(deadline: .now() + cfg.hold) {
                guard case .pending(let s, let q) = mode, q == seq, !inDragApp else { return }
                if cfg.oneFingerScroll { mode = .held(s); log("hold at \(Int(s.x)),\(Int(s.y))") }
                else { rightClick(s, "long press"); mode = .done }
            }
        case .pending(let s, _):
            if dist(p, s) > moveTol {
                if cfg.oneFingerScroll && !inDragApp {
                    mode = .scroll1; accX = 0; accY = 0; scroll(p.x - s.x, p.y - s.y); log("scroll start (1 finger)")
                } else { startDrag(s, p) }
            }
        case .held(let s):
            if dist(p, s) > moveTol { startDrag(s, p) }
        case .dragging:
            if p != lastPt { post(.leftMouseDragged, p) }
        case .scroll1:
            if lastN == 1 { scroll(p.x - lastPt.x, p.y - lastPt.y) }
        default: break   // one finger left over from a two-finger gesture
        }
    default:
        let c = CGPoint(x: active.map(\.x).reduce(0, +) / Double(n), y: active.map(\.y).reduce(0, +) / Double(n))
        let d = dist(active[0], active[1])
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
            if case .dragging = mode { post(.leftMouseUp, lastPt) }
            twoStart = c; pinchStart = d; pinchLast = 0; accX = 0; accY = 0
            post(.mouseMoved, c)
            mode = .two(c, now(), .undecided)
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
        choices(menu, "Pinch", "zoom", cfg.zoom, [("Trackpad Zoom", "gesture"), ("⌘+ / ⌘− Keys", "keys"), ("Off", "off")])
        choices(menu, "Long Press", "hold", cfg.hold, [0.4, 0.5, 0.6, 0.8, 1.0].map { (String(format: "%.1f s", $0), $0) })
        choices(menu, "Scroll Speed", "scrollScale", cfg.scrollScale, [0.5, 0.75, 1.0, 1.5, 2.0].map { ("\($0)×", $0) })
        menu.addItem(.separator())
        appList(menu, "Drag Apps", "dragApps", cfg.dragApps, "In these apps one finger always drags.")
        appList(menu, "Zoom-Key Apps", "zoomKeyApps", cfg.zoomKeyApps, "In these apps pinch sends ⌘+ / ⌘−.")
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
        default: return false
        }
    }

    @objc func toggle(_ s: NSMenuItem) {
        guard let key = s.representedObject as? String else { return }
        if key == "paused" { endGesture() }
        setSetting(key, !value(key))
        updateIcon()
    }
    @objc func choose(_ s: NSMenuItem) {
        guard let kv = s.representedObject as? [Any], let key = kv[0] as? String else { return }
        setSetting(key, kv[1])
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
