import AppKit

// MARK: calibration wizard

// Full-screen targets on the touch display. Where each tap rested (the median of its reports, as for
// any tap), before calibration, is paired with its target: a per-axis least-squares line from the
// targets inset from the edges, and the touched value at targets near each edge, where touch panels
// read inward (see applyCal).
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
    // A grid inset from the edges, then one at the edges and corners (and the centre again).
    let targets: [CGPoint] = [([0.05, 0.5, 0.95], [0.1, 0.5, 0.9]), ([calEdge, 0.5, 1 - calEdge], [calEdge, 0.5, 1 - calEdge])]
        .flatMap { xs, ys in ys.flatMap { y in xs.map { x in CGPoint(x: x, y: y) } } }
    var window: NSWindow?, view: CalibrationView?, idle: Timer?
    var index = 0, finished = false, message = ""
    var samples: [(target: CGPoint, touch: CGPoint)] = [], dots: [CGPoint] = []
    var touch: [CGPoint] = []   // the current tap's reports
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
        index = 0; finished = false; samples = []; dots = []; touch = []
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

    // Called once per report with the contacts in panel fractions, uncalibrated. Targets are shown in
    // display fractions and fitted in panel fractions, so the calibration holds in every rotation.
    func feed(_ fracs: [CGPoint]) {
        if let f = fracs.first { if touch.count < 30 { touch.append(f) }; return }
        guard !touch.isEmpty, let t = currentTarget else { return }
        let f = median(touch)
        touch = []
        let d = targetDisplay()
        let tr = transform(on: d)
        samples.append((tr.toPanel(t), f)); dots.append(tr.toDisplay(applyCal(f, cfg.cal)))
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
        // Per panel axis: the line through the targets away from its edges, and the mean touched value
        // at the targets near each edge.
        func axis(_ k: KeyPath<CGPoint, CGFloat>) -> (a: Double, b: Double, edges: [Double]) {
            let inner = samples.filter { abs($0.target[keyPath: k] - 0.5) < 0.5 - calEdge - 0.001 }
            let (a, b) = fit(inner.map { $0.target[keyPath: k] }, inner.map { $0.touch[keyPath: k] })
            let edges = [calEdge, 1 - calEdge].map { t in
                let at = samples.filter { abs($0.target[keyPath: k] - t) < 0.001 }.map { Double($0.touch[keyPath: k]) }
                return at.reduce(0, +) / Double(max(at.count, 1))
            }
            // Further than 4% off the line is a missed target rather than the panel reading inward.
            let plausible = zip([calEdge, 1 - calEdge], edges).allSatisfy { abs($1 - (a * $0 + b)) < 0.04 }
            return (a, b, plausible ? edges : [])
        }
        let cx = axis(\.x), cy = axis(\.y), (ax, bx, ay, by) = (cx.a, cx.b, cy.a, cy.b)
        let edges = cx.edges.count == 2 && cy.edges.count == 2 ? cx.edges + cy.edges : []
        let new = validCal(([ax, bx, ay, by] + edges).map { ($0 * 10000).rounded() / 10000 }) ?? identityCal
        let d = targetDisplay(), b = CGDisplayBounds(d)
        func meanError(_ c: [Double]) -> Double {   // in display points
            samples.reduce(0) { s, x in
                let tr = transform(on: d), p = tr.toDisplay(applyCal(x.touch, c)), t = tr.toDisplay(x.target)
                return s + hypot((p.x - t.x) * b.width, (p.y - t.y) * b.height)
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
