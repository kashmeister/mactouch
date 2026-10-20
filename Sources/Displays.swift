import AppKit

// MARK: target display

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return Array(ids.prefix(Int(n)))
}
// A display spec is "VEND:MODEL", or "VEND:MODEL:SERIAL" to tell two identical monitors apart.
func matches(_ spec: String, _ d: CGDirectDisplayID) -> Bool {
    let p = spec.split(separator: ":")
    guard p.count >= 2, let v = num(p[0]), let m = num(p[1]) else { return false }
    if p.count > 2, let s = num(p[2]), s != 0, CGDisplaySerialNumber(d) != UInt32(s) { return false }
    return CGDisplayVendorNumber(d) == UInt32(v) && CGDisplayModelNumber(d) == UInt32(m)
}
func spec(of d: CGDirectDisplayID) -> String {
    let s = CGDisplaySerialNumber(d)
    return "\(hex(CGDisplayVendorNumber(d))):\(hex(CGDisplayModelNumber(d)))" + (s != 0 ? ":\(hex(s))" : "")
}
func display(for spec: String) -> CGDirectDisplayID? { onlineDisplays().first { matches(spec, $0) } }
func displayName(_ d: CGDirectDisplayID) -> String { screen(for: d)?.localizedName ?? "display \(d)" }
func isTarget(_ d: CGDirectDisplayID) -> Bool { matches(cfg.display, d) }
var cachedDisplay: CGDirectDisplayID?, targetFound = false, lastLookup = 0.0
func targetDisplay() -> CGDirectDisplayID {
    // A fallback is retried every 2 s: around display sleep and wake the touch display can be
    // briefly missing, and a reconfiguration notice may not follow. A found display is checked too,
    // in case it went away without a notice.
    if let d = cachedDisplay, (targetFound && (cfg.display == "main" || CGDisplayIsOnline(d) != 0)) || now() - lastLookup < 2 { return d }
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
func watchDisplayChanges() {
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
        if !flags.contains(.beginConfigurationFlag) { cachedDisplay = nil }
    }, nil)
}
func screen(for d: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d }
}

struct Axis { var v = 0.0, lo = 0.0, hi = 1.0
    var norm: Double { hi > lo ? min(max((v - lo) / (hi - lo), 0), 1) : 0 } }
struct Slot { var tip = false, x = Axis(), y = Axis() }

/// A contact's position in panel fractions: the touch layer's own axes, before rotation.
func panel(_ s: Slot) -> CGPoint { CGPoint(x: s.x.norm, y: s.y.norm) }

/// How a touch panel's axes map onto its display, in fractions (0...1): the panel turns with the
/// picture, then the screen's axis fixes apply. This is x = A·p + c with A a signed permutation.
struct PanelTransform {
    var rotation = 0, swap = false, flipX = false, flipY = false

    func toDisplay(_ p: CGPoint) -> CGPoint {
        var u = p.x, v = p.y
        switch rotation {
        case 90: (u, v) = (1 - v, u)
        case 180: (u, v) = (1 - u, 1 - v)
        case 270: (u, v) = (v, 1 - u)
        default: break
        }
        if swap { Swift.swap(&u, &v) }
        if flipX { u = 1 - u }
        if flipY { v = 1 - v }
        return CGPoint(x: u, y: v)
    }

    func toPanel(_ x: CGPoint) -> CGPoint {
        let o = toDisplay(.zero), ex = toDisplay(CGPoint(x: 1, y: 0)), ey = toDisplay(CGPoint(x: 0, y: 1))
        let a = ex.x - o.x, b = ey.x - o.x, c = ex.y - o.y, e = ey.y - o.y, det = a * e - b * c
        let dx = x.x - o.x, dy = x.y - o.y
        return CGPoint(x: (e * dx - b * dy) / det, y: (a * dy - c * dx) / det)
    }

    /// MacTouch 3.1.0 and older kept calibration in display fractions; this rewrites one into panel
    /// fractions. Display axis i reads panel axis j, maybe flipped (x_i = p_j or 1 - p_j), so touched
    /// x = a·t + b becomes touched p = a·t' + b, or a·t' + (1 - a - b) when flipped.
    func calibrationToPanel(_ c: [Double]) -> [Double] {
        var out = Array(c.prefix(4))   // calibrations that old have no edge values
        let o = toDisplay(.zero), ex = toDisplay(CGPoint(x: 1, y: 0))
        for i in 0..<2 {   // display axis: 0 = x, 1 = y
            let a = c[2 * i], b = c[2 * i + 1]
            let j = abs(i == 0 ? ex.x - o.x : ex.y - o.y) > 0.5 ? 0 : 1
            let flipped = (i == 0 ? o.x : o.y) > 0.5
            out[2 * j] = a; out[2 * j + 1] = flipped ? 1 - a - b : b
        }
        return out
    }
}

/// The transform for display d, with the active screen's axis fixes (none while pairing a screen
/// whose fixes are not known yet).
func transform(on d: CGDirectDisplayID, fixes: Bool = true) -> PanelTransform {
    PanelTransform(rotation: Int(CGDisplayRotation(d)), swap: fixes && cfg.swap, flipX: fixes && cfg.flipX, flipY: fixes && cfg.flipY)
}

/// Calibration is kept in panel fractions, so it holds in every rotation. Per panel axis it is a line,
/// touched = a × target + b, inverted on every point: [ax, bx, ay, by]. Touch panels read inward near
/// their edges, so it may also hold the touched value measured calEdge from each edge: [..., x at the
/// low edge, x at the high edge, y low, y high]. Within calInner of an edge, touches then map along
/// the line from that point to the main line, and beyond it.
let calEdge = 0.02, calInner = 0.1
func applyCal(_ f: CGPoint, _ c: [Double]) -> CGPoint {
    func axis(_ u: Double, _ a: Double, _ b: Double, _ edges: (lo: Double, hi: Double)?) -> Double {
        var t = (u - b) / a
        if let e = edges, t < calInner {
            t = calEdge + (u - e.lo) * (calInner - calEdge) / (a * calInner + b - e.lo)
        } else if let e = edges, t > 1 - calInner {
            t = 1 - calEdge - (e.hi - u) * (calInner - calEdge) / (e.hi - a * (1 - calInner) - b)
        }
        return min(max(t, 0), 1)
    }
    let edged = c.count == 8
    return CGPoint(x: axis(f.x, c[0], c[1], edged ? (c[4], c[5]) : nil), y: axis(f.y, c[2], c[3], edged ? (c[6], c[7]) : nil))
}

/// A contact's display fraction on the active screen, calibrated. `on` is for pairing a new screen:
/// that display's rotation, uncalibrated, without axis fixes.
func frac(_ s: Slot, on d: CGDirectDisplayID? = nil) -> CGPoint {
    if let d { return transform(on: d, fixes: false).toDisplay(panel(s)) }
    return transform(on: targetDisplay()).toDisplay(applyCal(panel(s), cfg.cal))
}
func toScreen(_ f: CGPoint) -> CGPoint {
    let b = CGDisplayBounds(targetDisplay())
    return CGPoint(x: (b.minX + f.x * (b.width - 1)).rounded(), y: (b.minY + f.y * (b.height - 1)).rounded())
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
