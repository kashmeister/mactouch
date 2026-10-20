import AppKit

// MARK: whiteboard and drawing on screen

// Finger drawing, one stroke per finger. The whiteboard is a full-screen board (dark or light) that
// can be saved as a PNG; drawing on screen is a transparent layer over everything, with a floating
// bar. In its Use mode, touches outside the bar work the Mac as usual while the drawing stays visible.
let penColors: [(name: String, spec: String)] = [
    ("Black", "#1C1C1E"), ("White", "#FFFFFF"), ("Red", "#FF3B30"), ("Orange", "ring"),
    ("Yellow", "#FFD60A"), ("Green", "#34C759"), ("Blue", "#0A84FF"),
]
let penWidths: [CGFloat] = [3, 7, 14]

struct Stroke {
    var id: Int, points: [CGPoint], color: NSColor, width: CGFloat
    var bounds: CGRect   // everything the stroke covers, for redrawing only what changed
    init(id: Int, at p: CGPoint, color: NSColor, width: CGFloat) {
        self.id = id; points = [p]; self.color = color; self.width = width; bounds = Stroke.around(p, p, width)
    }
    mutating func add(_ p: CGPoint) -> CGRect {
        let r = Stroke.around(points[points.count - 1], p, width)
        points.append(p); bounds = bounds.union(r); return r
    }
    static func around(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -width / 2 - 2, dy: -width / 2 - 2)
    }
}
enum SketchTool: Equatable { case pen(Int), size, eraser, undo, board, use, clear, save, done }

final class SketchView: NSView {
    weak var owner: Sketch?
    var hideBar = false   // while rendering the PNG
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { owner?.close() } }   // Esc

    func items() -> [(rect: NSRect, tool: SketchTool, title: String, on: Bool, swatch: NSColor?)] {
        guard let o = owner else { return [] }
        var list: [(NSRect, SketchTool, String, Bool, NSColor?)] = []
        var x: CGFloat = 0
        func add(_ w: CGFloat, _ t: SketchTool, _ title: String, on: Bool = false, swatch: NSColor? = nil) {
            list.append((NSRect(x: x, y: 4, width: w, height: 36), t, title, on, swatch)); x += w + 8
        }
        for i in penColors.indices { add(44, .pen(i), "", on: o.pen == i && !o.eraser, swatch: o.penColor(i)) }
        x += 8
        add(96, .size, ["Thin", "Medium", "Thick"][o.size])
        add(96, .eraser, "Eraser", on: o.eraser)
        add(80, .undo, "Undo")
        if o.overlay { add(96, .use, o.drawing ? "Drawing" : "Using Mac", on: o.drawing) } else { add(96, .board, o.light ? "Light" : "Dark") }
        add(140, .clear, o.clearHint > now() ? "Hold to clear" : "Clear")
        if !o.overlay { add(110, .save, o.savedUntil > now() ? "Saved ✓" : "Save PNG") }
        add(90, .done, "Done")
        // The whiteboard's bar spans the top; the overlay's floats, centred, at the top.
        let width = x - 8, left = o.overlay ? (bounds.width - width) / 2 : 8
        return list.map { (NSRect(x: $0.0.minX + left, y: $0.0.minY + (o.overlay ? 8 : 0), width: $0.0.width, height: $0.0.height), $0.1, $0.2, $0.3, $0.4) }
    }

    var barRect: NSRect {
        let it = items()
        guard let first = it.first, let last = it.last else { return .zero }
        return owner?.overlay == true ? NSRect(x: first.rect.minX - 10, y: 2, width: last.rect.maxX - first.rect.minX + 20, height: 52)
                                      : NSRect(x: 0, y: 0, width: bounds.width, height: 44)
    }

    // Only the strokes that cross the changed area are drawn, and AppKit clips to it: repainting the
    // whole 5K-backed board for every touch report was the slow part.
    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }
        let t0 = now()
        if o.overlay { NSColor.clear.setFill(); dirtyRect.fill(using: .copy) }
        else { (o.light ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.1, alpha: 1)).setFill(); dirtyRect.fill() }
        for s in o.strokes where needsToDraw(s.bounds) || o.predicted[s.id].map({ needsToDraw(Stroke.around(s.points[s.points.count - 1], $0, s.width)) }) == true {
            s.color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = s.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: s.points[0])
            if s.points.count == 1 { path.line(to: CGPoint(x: s.points[0].x + 0.1, y: s.points[0].y)) }
            for p in s.points.dropFirst() { path.line(to: p) }
            if let tip = o.predicted[s.id] { path.line(to: tip) }   // where the finger probably is by now
            path.stroke()
        }
        defer { o.drawTime += now() - t0; o.draws += 1 }
        for p in o.eraserPoints.values {
            NSColor(white: 0.5, alpha: 0.8).setStroke()
            let c = NSBezierPath(ovalIn: NSRect(x: p.x - o.eraserRadius, y: p.y - o.eraserRadius, width: 2 * o.eraserRadius, height: 2 * o.eraserRadius))
            c.lineWidth = 2; c.stroke()
        }
        guard !hideBar, needsToDraw(barRect) else { return }
        NSColor(white: 0.12, alpha: o.overlay ? 0.88 : 1).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: o.overlay ? 14 : 0, yRadius: o.overlay ? 14 : 0).fill()
        for it in items() {
            if let sw = it.swatch {
                sw.setFill(); NSBezierPath(ovalIn: it.rect.insetBy(dx: 6, dy: 2)).fill()
                if it.on { color(cfg.ringColor).setStroke(); let r = NSBezierPath(ovalIn: it.rect.insetBy(dx: 2, dy: -2)); r.lineWidth = 3; r.stroke() }
                continue
            }
            (it.on ? color(cfg.ringColor) : NSColor(white: 0.26, alpha: 1)).setFill()
            NSBezierPath(roundedRect: it.rect, xRadius: 8, yRadius: 8).fill()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                                                        .foregroundColor: it.on ? NSColor.black : NSColor.white, .paragraphStyle: para]
            let h = (it.title as NSString).size(withAttributes: attrs).height
            (it.title as NSString).draw(in: NSRect(x: it.rect.minX, y: it.rect.midY - h / 2, width: it.rect.width, height: h), withAttributes: attrs)
        }
    }
}

final class Sketch: NSObject {
    var window: NSWindow?, view: SketchView?, redraw: Timer?
    var active: Bool { window != nil }
    var overlay = false, drawing = true, light = false, capturing = false
    var pen = 1, size = 1, eraser = false
    var strokes: [Stroke] = [], nextID = 0
    var fingers: [Int: Int] = [:]          // finger -> stroke id; -1 on the bar, -2 erasing
    var eraserPoints: [Int: CGPoint] = [:]
    var predicted: [Int: CGPoint] = [:]    // stroke id -> predicted tip, drawn but not kept
    var velocity: [Int: (v: CGVector, t: Double)] = [:]   // stroke id -> smoothed points per second
    var draws = 0, drawTime = 0.0
    var clearFinger: Int?, clearHint = 0.0, savedUntil = 0.0
    let eraserRadius: CGFloat = 26
    var hasFingers: Bool { !fingers.isEmpty }

    func penColor(_ i: Int) -> NSColor { penColors[i].spec == "ring" ? color(cfg.ringColor) : color(penColors[i].spec) }

    func open(overlay o: Bool) {
        guard window == nil, let s = screen(for: targetDisplay()) ?? NSScreen.main else { return }
        endGesture()
        overlay = o; drawing = true; eraser = false; strokes = []; fingers = [:]; eraserPoints = [:]
        predicted = [:]; velocity = [:]; draws = 0; drawTime = 0
        pen = o ? 2 : (light ? 0 : 1)   // red over the screen; black or white on the board
        let w = CalibrationWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = !o
        w.backgroundColor = o ? .clear : .black
        w.ignoresMouseEvents = o   // Use mode: clicks go to the apps underneath
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = SketchView(frame: NSRect(origin: .zero, size: s.frame.size))
        v.owner = self
        v.wantsLayer = true; v.layerContentsRedrawPolicy = .onSetNeedsDisplay
        w.contentView = v
        w.setFrame(s.frame, display: true)
        window = w; view = v
        if o { w.orderFrontRegardless() } else {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        }
        redraw = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.clearHint > now() - 0.5 || self.savedUntil > now() - 0.5 { self.view?.needsDisplay = true }
        }
        log(o ? "drawing on screen" : "whiteboard open")
    }

    func close() {
        redraw?.invalidate(); redraw = nil
        window?.orderOut(nil)
        window = nil; view = nil; fingers = [:]; capturing = false
        log("drawing closed" + (draws > 0 ? String(format: " (%d redraws, %.1f ms average)", draws, drawTime / Double(draws) * 1000) : ""))
    }

    func local(_ g: CGPoint) -> CGPoint {
        guard let w = window else { return g }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: g.x - w.frame.minX, y: g.y - (primaryHeight - w.frame.minY - w.frame.height))
    }
    func onBar(_ g: CGPoint) -> Bool { view?.barRect.contains(local(g)) ?? false }

    // Called once per HID report while capturing, with every touching finger: slot -> global point.
    func feed(_ touches: [Int: CGPoint]) {
        guard let v = view else { return }
        var dirty = CGRect.null, all = false
        func mark(_ r: CGRect) { dirty = dirty.union(r) }
        func unpredict(_ id: Int) {
            if let tip = predicted.removeValue(forKey: id), let s = strokes.last(where: { $0.id == id }) { mark(Stroke.around(s.points[s.points.count - 1], tip, s.width)) }
        }
        for (f, g) in touches {
            let p = local(g)
            if let id = fingers[f] {
                if id == -2 {
                    if let old = eraserPoints[f] { mark(eraserRing(old)) }
                    mark(erase(at: p)); mark(eraserRing(p)); eraserPoints[f] = p
                } else if id >= 0, let i = strokes.lastIndex(where: { $0.id == id }) {
                    unpredict(id)
                    let last = strokes[i].points[strokes[i].points.count - 1]
                    guard p != last else { continue }
                    mark(strokes[i].add(p))
                    predict(i, from: last, to: p)
                    if let tip = predicted[id] { mark(Stroke.around(p, tip, strokes[i].width)) }
                }
                continue
            }
            declareUserActivity()
            if v.barRect.contains(p) {
                fingers[f] = -1; all = true
                if let it = v.items().first(where: { $0.rect.contains(p) }) { if !barTool(it.tool, f) { return } }
            } else if eraser {
                fingers[f] = -2; eraserPoints[f] = p; mark(erase(at: p)); mark(eraserRing(p))
            } else {
                let s = Stroke(id: nextID, at: p, color: penColor(pen), width: penWidths[size])
                strokes.append(s); mark(s.bounds)
                fingers[f] = nextID; velocity[nextID] = (CGVector.zero, now()); nextID += 1
            }
        }
        for f in fingers.keys where touches[f] == nil {
            if let id = fingers[f], id >= 0 { unpredict(id); velocity[id] = nil }
            if let old = eraserPoints[f] { mark(eraserRing(old)) }
            fingers[f] = nil; eraserPoints[f] = nil
            if clearFinger == f { clearFinger = nil; clearHint = now() + 1.5; all = true }   // lifted before the hold finished
        }
        if all { v.needsDisplay = true } else if !dirty.isNull { v.setNeedsDisplay(dirty) }
    }

    // Extend the stroke to where the finger should be about inkPredict ms from now, from its smoothed
    // velocity. It hides part of the digitizer's and the screen's delay; the guess is replaced by the
    // real point on the next report. It stays short, and is skipped while the finger slows down or
    // turns, where a guess would overshoot.
    func predict(_ i: Int, from a: CGPoint, to b: CGPoint) {
        let id = strokes[i].id, t = now()
        let (old, t0) = velocity[id] ?? (CGVector.zero, t)
        let dt = max(t - t0, 0.002)
        let raw = CGVector(dx: (b.x - a.x) / dt, dy: (b.y - a.y) / dt)
        let k = old == .zero ? 1 : 0.5
        let v = CGVector(dx: old.dx + k * (raw.dx - old.dx), dy: old.dy + k * (raw.dy - old.dy))
        velocity[id] = (v, t)
        guard cfg.inkPredict > 0, dt < 0.1, old != .zero else { return }
        let speed = hypot(raw.dx, raw.dy), smooth = hypot(v.dx, v.dy)
        let turn = (raw.dx * v.dx + raw.dy * v.dy) / max(speed * smooth, 1e-6)   // cosine of the turn
        guard speed > 0.8 * smooth, turn > 0.9 else { return }
        var d = CGVector(dx: v.dx * cfg.inkPredict / 1000, dy: v.dy * cfg.inkPredict / 1000)
        let len = hypot(d.dx, d.dy), cap: CGFloat = 12
        if len < 1 { return }
        if len > cap { d = CGVector(dx: d.dx * cap / len, dy: d.dy * cap / len) }
        predicted[id] = CGPoint(x: b.x + d.dx, y: b.y + d.dy)
    }

    func eraserRing(_ p: CGPoint) -> CGRect { CGRect(x: p.x, y: p.y, width: 0, height: 0).insetBy(dx: -eraserRadius - 3, dy: -eraserRadius - 3) }

    // Removes the strokes under the eraser; returns the area they covered.
    func erase(at p: CGPoint) -> CGRect {
        let r2 = eraserRadius * eraserRadius
        var gone = CGRect.null
        strokes.removeAll { s in
            guard s.bounds.insetBy(dx: -eraserRadius, dy: -eraserRadius).contains(p),
                  s.points.contains(where: { ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) < r2 }) else { return false }
            gone = gone.union(s.bounds); return true
        }
        return gone
    }

    func barTool(_ t: SketchTool, _ finger: Int) -> Bool {
        switch t {
        case .pen(let i): pen = i; eraser = false
        case .size: size = (size + 1) % penWidths.count
        case .eraser: eraser.toggle()
        case .undo:
            let drawingIDs = Set(fingers.values)
            if let i = strokes.lastIndex(where: { !drawingIDs.contains($0.id) }) { strokes.remove(at: i) }
        case .board: light.toggle(); if pen <= 1 { pen = light ? 0 : 1 }
        case .use: drawing.toggle()
        case .clear:   // hold 0.7 s, so a stray touch can't wipe the drawing
            clearFinger = finger
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.clearFinger == finger else { return }
                self.clearFinger = nil; self.strokes.removeAll(); self.view?.needsDisplay = true
            }
        case .save: savePNG()
        case .done: close(); mode = .done; return false   // ignore the fingers still down
        }
        return true
    }

    // The board without its bar, to ~/Pictures/MacTouch and the clipboard.
    func savePNG() {
        guard let v = view else { return }
        v.hideBar = true
        defer { v.hideBar = false; v.needsDisplay = true }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/MacTouch")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("Whiteboard \(f.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: url)
            let image = NSImage(size: v.bounds.size); image.addRepresentation(rep)
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
            savedUntil = now() + 2
            log("whiteboard saved to \(url.path) and copied")
        } catch { log("saving whiteboard failed: \(error)") }
    }
}
let sketch = Sketch()
