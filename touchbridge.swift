// touchbridge: drive a HID multi-touch digitizer (default: the ILITEK controller in Wisecoco
// touch displays, USB 222a:0001) as mouse, scroll and pinch-zoom input on macOS, which has no
// touchscreen driver of its own.
//
// Gestures
//   tap / double-tap        click / double click
//   1 finger, move          drag            (--one-finger-scroll: scroll)
//   1 finger, hold          right click     (--one-finger-scroll: hold+move = drag, hold+lift = right click)
//   2 fingers, move         scroll
//   2 fingers, pinch        zoom (trackpad magnify, or Cmd+/Cmd- per app)
//   2 fingers, tap          right click     (only with --two-finger-tap)
//
// Options (all optional; numbers may be decimal or 0x-hex)
//   --check                 print displays, touch device and permission status, then exit
//   --probe                 log contacts only, post no events          --raw   log every HID value
//   --vid=0x222a --pid=N    USB IDs of the touch controller (pid: any if omitted)
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
import Foundation
import IOKit
import IOKit.hid
import CoreGraphics
import ApplicationServices

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: options

let known: Set<String> = ["--check", "--probe", "--raw", "--vid", "--pid", "--display", "--flip-x", "--flip-y", "--swap",
                          "--cal", "--one-finger-scroll", "--two-finger-tap", "--hold", "--scroll-scale", "--invert-scroll",
                          "--zoom", "--zoom-scale", "--zoom-key-apps", "--drag-apps", "--titlebar"]
let args = Array(CommandLine.arguments.dropFirst())
for a in args where !known.contains(String(a.split(separator: "=", maxSplits: 1)[0])) {
    FileHandle.standardError.write("unknown option \(a); see the header of touchbridge.swift\n".data(using: .utf8)!)
    exit(2)
}
func optS(_ name: String, _ def: String) -> String {
    args.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } ?? def
}
func opt(_ name: String, _ def: Double) -> Double { Double(optS(name, "")) ?? def }
func optList(_ name: String, _ def: String) -> Set<String> {
    Set(optS(name, def).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
}
func num(_ s: Substring) -> UInt32? { s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : UInt32(s) }

let checkOnly = args.contains("--check"), probe = args.contains("--probe"), raw = args.contains("--raw")
let touchVID = num(Substring(optS("--vid", "0x222a"))) ?? 0x222A
let touchPID = num(Substring(optS("--pid", "")))
let displaySpec = optS("--display", "0x2613:0x2023")
let flipX = args.contains("--flip-x"), flipY = args.contains("--flip-y"), swapXY = args.contains("--swap")
let cal: [Double] = {
    let v = optS("--cal", "").split(separator: ",").compactMap { Double($0) }
    return v.count == 4 && v[0] != 0 && v[2] != 0 ? v : [1, 0, 1, 0]
}()
let oneFingerScroll = args.contains("--one-finger-scroll"), twoFingerTap = args.contains("--two-finger-tap")
let hold = opt("--hold", 0.6), scrollScale = opt("--scroll-scale", 1.0)
let scrollDir = args.contains("--invert-scroll") ? -1.0 : 1.0
let zoomMode = optS("--zoom", "gesture"), zoomScale = opt("--zoom-scale", 1.0)
let zoomKeyApps = optList("--zoom-key-apps", ""), dragApps = optList("--drag-apps", "AssistiveControl")
let titlebar = opt("--titlebar", 44)

let moveTol = 10.0, tapMaxSecs = 0.35, dblSecs = 0.45, dblDist = 24.0, pinchTol = 25.0, zoomKeyStep = log(1.25)

// MARK: helpers

let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
func log(_ s: String) { print(stamp.string(from: Date()) + " " + s) }
func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

// MARK: target display

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return Array(ids.prefix(Int(n)))
}
func isTarget(_ d: CGDirectDisplayID) -> Bool {
    let p = displaySpec.split(separator: ":")
    guard p.count == 2, let v = num(p[0]), let m = num(p[1]) else { return false }
    return CGDisplayVendorNumber(d) == v && CGDisplayModelNumber(d) == m
}
var cachedDisplay: CGDirectDisplayID?
func targetDisplay() -> CGDirectDisplayID {
    if let d = cachedDisplay { return d }
    let d = displaySpec == "main" ? nil : onlineDisplays().first(where: isTarget)
    if d == nil && displaySpec != "main" { log("display \(displaySpec) not connected; using the main display") }
    cachedDisplay = d ?? CGMainDisplayID()
    return cachedDisplay!
}
CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
    if !flags.contains(.beginConfigurationFlag) { cachedDisplay = nil }
}, nil)

struct Axis { var v = 0.0, lo = 0.0, hi = 1.0
    var norm: Double { hi > lo ? min(max((v - lo) / (hi - lo), 0), 1) : 0 } }
struct Slot { var tip = false, x = Axis(), y = Axis() }

// Panel-native fractions -> global screen point on the target display.
func point(_ s: Slot) -> CGPoint {
    let d = targetDisplay(), b = CGDisplayBounds(d)
    var u = s.x.norm, v = s.y.norm
    switch Int(CGDisplayRotation(d)) {   // the panel turns with the picture
    case 90: (u, v) = (1 - v, u)
    case 180: (u, v) = (1 - u, 1 - v)
    case 270: (u, v) = (v, 1 - u)
    default: break
    }
    if swapXY { swap(&u, &v) }
    if flipX { u = 1 - u }
    if flipY { v = 1 - v }
    u = min(max((u - cal[1]) / cal[0], 0), 1)
    v = min(max((v - cal[3]) / cal[2], 0), 1)
    return CGPoint(x: (b.minX + u * (b.width - 1)).rounded(), y: (b.minY + v * (b.height - 1)).rounded())
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

// MARK: gesture state

enum Two { case undecided, scroll, zoom }
enum Mode {
    case idle
    case pending(CGPoint, Int)      // one finger down, not yet tap/move/hold (start, timer seq)
    case held(CGPoint)              // --one-finger-scroll: held still; move = drag, lift = right click
    case dragging
    case scroll1                    // --one-finger-scroll: scrolling with one finger
    case two(CGPoint, Double, Two)  // last centroid, start time, gesture kind
    case done                       // gesture consumed; wait for all fingers up
}

var slots: [Int: Slot] = [:]   // keyed by finger collection cookie
var mode = Mode.idle, dirty = false, pressSeq = 0, lastN = 0
var lastPt = CGPoint.zero, twoStart = CGPoint.zero
var lastTapTime = 0.0, lastTapPt = CGPoint.zero, clicks: Int64 = 1
var accX = 0.0, accY = 0.0
var pinchStart = 0.0, pinchLast = 0.0, zoomKeyAcc = 0.0
var inDragApp = false, zoomHere = zoomMode   // decided per gesture from the window under the finger(s)
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

func scroll(_ dx: Double, _ dy: Double) {
    accX += dx * scrollScale * scrollDir; accY += dy * scrollScale * scrollDir
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
        zoomKeyAcc += log(d / pinchLast) * zoomScale
        while zoomKeyAcc > zoomKeyStep { zoomKey(true); zoomKeyAcc -= zoomKeyStep }
        while zoomKeyAcc < -zoomKeyStep { zoomKey(false); zoomKeyAcc += zoomKeyStep }
    case "gesture":
        magnify((d / pinchLast - 1) * zoomScale, phase: 2, at: c)
    default: break
    }
}

// MARK: gesture recognition, run once per HID report

func commit() {
    dirty = false
    let active = slots.sorted { $0.key < $1.key }.filter { $0.value.tip }.map { point($0.value) }
    let n = active.count
    defer { lastN = n; if n == 1 { lastPt = active[0] } }
    if probe {
        if n != lastN || n > 0 { log("contacts=\(n) " + active.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")) }
        return
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
            case .undecided: if twoFingerTap && now() - t0 < tapMaxSecs { rightClick(twoStart, "two-finger tap") }
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
            let onTitlebar = win.map { $0.layer == 0 && p.y - $0.frame.minY < titlebar } ?? false
            inDragApp = dragApps.contains(app) || onTitlebar
            if inDragApp { log("down in \(app)\(onTitlebar ? " title bar" : ""): drag mode") }
            pressSeq += 1
            let seq = pressSeq
            mode = .pending(p, seq)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                guard case .pending(let s, let q) = mode, q == seq, !inDragApp else { return }
                if oneFingerScroll { mode = .held(s); log("hold at \(Int(s.x)),\(Int(s.y))") }
                else { rightClick(s, "long press"); mode = .done }
            }
        case .pending(let s, _):
            if dist(p, s) > moveTol {
                if oneFingerScroll && !inDragApp {
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
                    if zoomMode != "off" && dd > pinchTol && dd > dc {
                        kind = .zoom; pinchLast = d; zoomKeyAcc = 0
                        let app = windowAt(c)?.owner ?? ""
                        zoomHere = zoomKeyApps.contains(app) ? "keys" : zoomMode
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
var match: [String: Any] = [kIOHIDVendorIDKey: touchVID]
if let pid = touchPID { match[kIOHIDProductIDKey] = pid }
IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

if checkOnly {
    for d in onlineDisplays() {
        let b = CGDisplayBounds(d)
        print("display \(d): vendor \(hex(CGDisplayVendorNumber(d))) model \(hex(CGDisplayModelNumber(d)))",
              "rotation \(Int(CGDisplayRotation(d))) bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))",
              CGDisplayIsBuiltin(d) != 0 ? "built-in" : "", isTarget(d) ? "<- target" : "")
    }
    let devs = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
    print("touch devices matching vid \(hex(touchVID))\(touchPID.map { " pid " + hex($0) } ?? ""): \(devs.count)")
    for dev in devs { print("  \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) ?? "?" as CFTypeRef)") }
    let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    print("Input Monitoring: \(im == kIOHIDAccessTypeGranted ? "granted" : im == kIOHIDAccessTypeDenied ? "denied" : "not decided")")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
    print("(run from a terminal, permissions are the terminal's; the agent log is authoritative)")
    exit(0)
}

IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
    log("attached \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) ?? "?" as CFTypeRef)")
}, nil)
IOHIDManagerRegisterDeviceRemovalCallback(mgr, { _, _, _, _ in
    if case .dragging = mode { post(.leftMouseUp, lastPt) }
    slots.removeAll(); mode = .idle; lastN = 0
    log("touch controller removed")
}, nil)
IOHIDManagerRegisterInputValueCallback(mgr, valueCB, nil)
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

log("start vid=\(hex(touchVID)) display=\(displaySpec) probe=\(probe) oneFingerScroll=\(oneFingerScroll) " +
    "twoFingerTap=\(twoFingerTap) zoom=\(zoomMode) hold=\(hold) titlebar=\(titlebar) cal=\(cal) " +
    "dragApps=\(dragApps.sorted()) zoomKeyApps=\(zoomKeyApps.sorted())")

// Input Monitoring applies to new processes only, and a running process never sees the grant:
// exit after a while so launchd starts a fresh process that can.
if IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
    log("Input Monitoring missing; enable touchbridge in System Settings > Privacy & Security > Input Monitoring")
    _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    sleep(20)
    exit(0)
}
log("Input Monitoring granted; HID manager open")
// Accessibility applies to the running process.
if !probe && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("Accessibility missing; enable touchbridge in System Settings > Privacy & Security > Accessibility")
    while !AXIsProcessTrusted() { sleep(2) }
}
log("ready; display \(targetDisplay()) rotation \(Int(CGDisplayRotation(targetDisplay())))")
CFRunLoopRun()
