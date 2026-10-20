import AppKit

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

    // Called once per report with the contacts in panel fractions, uncalibrated. Targets are shown in
    // display fractions and fitted in panel fractions, so the calibration holds in every rotation.
    func feed(_ fracs: [CGPoint]) {
        if let f = fracs.first { if down == nil { down = f }; return }
        guard let f = down, let t = currentTarget else { return }
        down = nil
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
        let (ax, bx) = fit(samples.map { $0.target.x }, samples.map { $0.touch.x })
        let (ay, by) = fit(samples.map { $0.target.y }, samples.map { $0.touch.y })
        let new = [ax, bx, ay, by].map { ($0 * 10000).rounded() / 10000 }
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
