import AppKit

// MARK: pairing a new touchscreen with its display

// A touchscreen without a display in its profile is paired once: every external display without a
// connected touchscreen shows a target, each at a different spot, and the first touch picks the
// display whose target it lands nearest (in that display's rotation). A digitizer with exactly one
// such display is paired without asking. Esc or two idle minutes leave it unpaired; the menu's
// Pair with Display… asks again, and "Not a Touchscreen" makes MacTouch leave the device alone.
final class PairingView: NSView {
    weak var owner: Pairing?
    var target = CGPoint(x: 0.5, y: 0.5)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { owner?.cancel() } }   // Esc
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.07, alpha: 0.92).setFill(); bounds.fill()
        guard let o = owner else { return }
        if !o.finished {
            let c = NSPoint(x: target.x * bounds.width, y: target.y * bounds.height)
            NSColor.systemOrange.setStroke()
            for r in [70.0, 40.0] {
                let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); p.lineWidth = 4; p.stroke()
            }
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor(white: 0.9, alpha: 1)]
        let text = o.message as NSString, size = text.boundingRect(with: NSSize(width: bounds.width * 0.8, height: 400),
                                                                     options: .usesLineFragmentOrigin, attributes: attrs).size
        text.draw(with: NSRect(x: (bounds.width - size.width) / 2, y: bounds.height * 0.18, width: size.width, height: size.height),
                  options: .usesLineFragmentOrigin, attributes: attrs)
    }
}

final class Pairing: NSObject {
    var device: TouchDevice?
    var waiting: [TouchDevice] = []   // more new screens, or ones waiting for a display
    var windows: [CGDirectDisplayID: NSWindow] = [:], targets: [CGDirectDisplayID: CGPoint] = [:]
    var finished = false, message = "", down: Slot?, idle: Timer?
    var active: Bool { device != nil && !finished }

    func candidates(for t: TouchDevice) -> [CGDirectDisplayID] {
        let taken = Set(devices.values.filter { $0 !== t && $0.role != .notTouch }.compactMap(\.display))
        return onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 && !taken.contains($0) }
    }

    func request(_ t: TouchDevice) {
        if device === t { return }
        if device != nil { if !waiting.contains(where: { $0 === t }) { waiting.append(t) }; return }
        waiting.removeAll { $0 === t }
        let cands = candidates(for: t)
        if cands.isEmpty {   // its display may not have arrived yet
            log("\(t.label): no display to pair with yet; waiting")
            waiting.append(t); return
        }
        if t.kind == .multiTouch && cands.count == 1 { pair(t, cands[0], quietly: true); return }
        start(t, cands)
    }

    func start(_ t: TouchDevice, _ cands: [CGDirectDisplayID]) {
        endGesture()
        device = t; finished = false; down = nil
        updateSeize(t)   // a single-touch screen is taken from macOS while it is paired
        let many = cands.count > 1
        message = "MacTouch found a touchscreen: \(t.name).\n"
            + (many ? "Touch the orange target on the screen you are touching." : "Touch the orange target to use it with MacTouch.")
            + "\nEsc: later.   Not a touchscreen? Click the button below."
        for (i, d) in cands.enumerated() {
            guard let s = screen(for: d) else { continue }
            let target = CGPoint(x: (Double(i) + 0.5) / Double(cands.count), y: many && i % 2 == 1 ? 0.62 : 0.45)
            targets[d] = target
            let w = CalibrationWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = PairingView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.owner = self; v.target = target
            let b = NSButton(title: "Not a Touchscreen", target: self, action: #selector(notTouch))
            b.bezelStyle = .rounded; b.sizeToFit()
            b.frame.origin = NSPoint(x: (s.frame.width - b.frame.width) / 2, y: s.frame.height * 0.12)
            v.addSubview(b)
            w.contentView = v
            w.setFrame(s.frame, display: true)
            windows[d] = w
        }
        activate(t)
        NSApp.activate(ignoringOtherApps: true)
        for w in windows.values { w.orderFrontRegardless() }
        if let w = windows.values.first { w.makeKeyAndOrderFront(nil); w.makeFirstResponder(w.contentView) }
        resetIdle()
        log("pairing \(t.label) with one of \(cands.count) display(s)")
    }

    // Called once per report with the screen's contact, if any; the lift decides.
    func feed(_ s: Slot?) {
        guard let t = device, !finished else { return }
        if let s { down = down ?? s; return }
        guard let s = down else { return }
        down = nil
        let best = targets.min { a, b in dist(frac(s, on: a.key), a.value) < dist(frac(s, on: b.key), b.value) }
        if let d = best?.key { pair(t, d, quietly: false) }
    }

    func pair(_ t: TouchDevice, _ d: CGDirectDisplayID, quietly: Bool) {
        guard let id = t.profile else { return }
        setProfile(id, "display", spec(of: d))
        refreshDisplays()
        if activeDevice === t { activeProfile = nil; activate(t) }   // reload cfg with the new display
        log("paired \(t.label) with \(displayName(d)) (\(spec(of: d)))")
        if quietly { notify("MacTouch", "\(t.name) touches now go to \(displayName(d))."); next(); return }
        finished = true
        message = "Done: \(t.name) is paired with \(displayName(d)).\nIf touches land off target, choose "
            + "Touchscreens ▸ \(t.name) ▸ Calibrate… in the MacTouch menu."
        for (k, w) in windows where k != d { w.orderOut(nil) }
        windows[d]?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        windows[d]?.contentView?.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.device === t { self?.close() } }
    }

    @objc func notTouch() {
        if let t = device, let id = t.profile { setProfile(id, "mode", ScreenMode.ignore.rawValue); log("\(t.label) marked as not a touchscreen") }
        close()
    }
    func cancel() { if let t = device { log("pairing \(t.label) put off") }; close() }

    func close() {
        idle?.invalidate(); idle = nil
        for w in windows.values { w.orderOut(nil) }
        windows = [:]; targets = [:]; device = nil; finished = false
        updateSeizes()
        refreshStatusIcon()
        next()
    }
    func next() {
        guard device == nil, let t = waiting.first(where: { isConnected($0) && !candidates(for: $0).isEmpty })
        else { return }
        DispatchQueue.main.async { self.request(t) }
    }
    func resetIdle() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.cancel() }
    }
}
let pairing = Pairing()
