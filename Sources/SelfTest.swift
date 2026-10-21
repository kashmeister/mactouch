import CoreGraphics
import Foundation

// MARK: --self-test

/// Checks the parts that need no hardware: the panel-to-display transforms, the calibration rewrite
/// and every known controller's report layout against its recorded samples. Exits 0 if all pass.
func runSelfTest() -> Never {
    var checks = 0, failures = 0
    func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: " + what()) }
    }
    func near(_ a: CGPoint, _ b: CGPoint, _ tol: Double = 1e-9) -> Bool { abs(a.x - b.x) < tol && abs(a.y - b.y) < tol }

    let transforms = [0, 90, 180, 270].flatMap { r in [false, true].flatMap { s in [false, true].flatMap { fx in [false, true].map { fy in
        PanelTransform(rotation: r, swap: s, flipX: fx, flipY: fy) } } } }
    let points = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.35), CGPoint(x: 0.5, y: 0.75)]

    // toPanel undoes toDisplay, for every rotation and axis fix.
    for t in transforms {
        for p in points { expect(near(t.toPanel(t.toDisplay(p)), p), "toPanel(toDisplay(\(p))) with \(t)") }
    }
    // The panel turns with the picture: where the panel's top-left corner ends up on the display.
    let corners = [0: CGPoint(x: 0, y: 0), 90: CGPoint(x: 1, y: 0), 180: CGPoint(x: 1, y: 1), 270: CGPoint(x: 0, y: 1)]
    for (r, c) in corners { expect(near(PanelTransform(rotation: r).toDisplay(.zero), c), "rotation \(r): panel top-left at \(c)") }

    // A calibration from 3.1.0 or older (display fractions) and its panel-fraction rewrite map every
    // touch to the same display point.
    let oldCal = [0.95, 0.03, 1.04, -0.02]
    for t in transforms {
        let newCal = t.calibrationToPanel(oldCal)
        for p in points {
            let before = applyCal(t.toDisplay(p), oldCal), after = t.toDisplay(applyCal(p, newCal))
            expect(near(before, after), "calibration rewrite at \(p) with \(t): \(before) vs \(after)")
        }
    }

    // Edge values: an edge reading maps to its target, the edge zones join the line, every axis keeps
    // rising, and edge values that would fold an axis back are dropped.
    let (a, b) = (0.87, 0.006), line = { (t: Double) in a * t + b }
    let edged = [a, b, a, b, line(calEdge) + 0.012, line(1 - calEdge) - 0.01, line(calEdge) + 0.008, line(1 - calEdge) - 0.015]
    for (axis, lo, hi) in [(\CGPoint.x, edged[4], edged[5]), (\CGPoint.y, edged[6], edged[7])] {
        func mapped(_ u: Double) -> Double { Double(applyCal(CGPoint(x: u, y: u), edged)[keyPath: axis]) }
        expect(abs(mapped(lo) - calEdge) < 1e-9 && abs(mapped(hi) - (1 - calEdge)) < 1e-9, "edge readings map to their targets")
        for t in [calInner, 1 - calInner, 0.5] { expect(abs(mapped(line(t)) - t) < 1e-9, "edge zone joins the line at \(t)") }
        let sweep = stride(from: 0.0, through: 1.0, by: 0.001).map(mapped)
        expect(zip(sweep, sweep.dropFirst()).allSatisfy { $0 <= $1 }, "calibrated axis keeps rising")
        expect(sweep.first == 0 && sweep.last == 1, "both edges reachable")
    }
    expect(validCal(edged)?.count == 8, "plausible edge values kept")
    expect(validCal(Array(edged.prefix(4)) + [line(0.2), edged[5], edged[6], edged[7]])?.count == 4, "folding edge value dropped")
    expect(validCal([a, b, a]) == nil, "three numbers are no calibration")

    // Taps: a move counts only when the next report confirms it, and a tap rests at its median.
    unconfirmedMove = false
    expect([true, true].map(confirmedMove) == [false, true], "a move confirmed by the next report counts")
    unconfirmedMove = false
    expect([true, false, true].map(confirmedMove) == [false, false, false], "a one-report jump is not a move")
    unconfirmedMove = false
    let rest = [CGPoint(x: 10, y: 20), CGPoint(x: 11, y: 21), CGPoint(x: 12, y: 19), CGPoint(x: 25, y: 33)]
    expect(near(median(rest), CGPoint(x: 11.5, y: 20.5)), "a tap rests at its median, not at a stray report")

    // Report layouts against their recorded samples.
    for k in knownControllers {
        guard let raw = k.raw else { continue }
        let l = raw.layout
        expect(!raw.samples.isEmpty, "\(k.name): has recorded samples")
        for (n, s) in raw.samples.enumerated() {
            guard let bytes = s.bytes(for: l) else { expect(false, "\(k.name) sample \(n + 1): start is longer than length"); continue }
            guard let got = l.contacts(in: bytes) else { expect(false, "\(k.name) sample \(n + 1): not read as a touch report"); continue }
            let want = s.contacts.mapValues { CGPoint(x: Double($0.x) / l.maxX, y: Double($0.y) / l.maxY) }
            expect(Set(got.keys) == Set(want.keys), "\(k.name) sample \(n + 1): contacts \(got.keys.sorted()), expected \(want.keys.sorted())")
            for (id, p) in want { if let g = got[id] { expect(near(g, p), "\(k.name) sample \(n + 1) contact \(id): \(g), expected \(p)") } }
        }
        var other = raw.samples.first?.bytes(for: l) ?? [0, 0, 0]
        other[0] = l.reportID &+ 1
        expect(l.contacts(in: other) == nil, "\(k.name): a report with another ID is not a touch report")
        expect(l.contacts(in: [l.reportID, 0x03, 0x01]) == nil, "\(k.name): a report too short for one contact is not a touch report")
        // A contact count larger than the records the report holds must not read the count byte as data.
        let tight = [l.reportID] + [UInt8](repeating: 0x55, count: l.firstContact + l.contactSize - 1) + [UInt8(l.maxContacts)]
        expect((l.contacts(in: tight)?.count ?? 0) <= 1, "\(k.name): records stop before the count byte")
    }

    print(failures == 0 ? "self-test passed (\(checks) checks)" : "self-test: \(failures) of \(checks) checks failed")
    exit(failures == 0 ? 0 : 1)
}
