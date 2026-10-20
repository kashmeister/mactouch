import AppKit
import AVFoundation
import CoreMIDI

// MARK: music mode

// A full-screen instrument on the touch display: piano, drum pads, strum (Omnichord-style chord
// buttons and a strum plate) or theremin. While it is open, touches bypass mouse emulation and every
// finger plays on its own. Sounds come from the General MIDI bank that ships with macOS; piano, drum
// and strum notes also go out on a virtual MIDI source. Four loop slots record and replay piano, drum
// and strum playing, kept in step with each other.
let pianoSounds: [(name: String, program: Int)] = [
    ("Grand Piano", 0), ("Electric Piano", 4), ("Harpsichord", 6), ("Vibraphone", 11),
    ("Organ", 16), ("Strings", 48), ("Choir", 52),
]
let strumSounds: [(name: String, program: Int)] = [
    ("Harp", 46), ("Nylon Guitar", 24), ("Steel Guitar", 25), ("Music Box", 10), ("Kalimba", 108),
]
let drumPads: [(name: String, note: Int)] = [
    ("Kick", 36), ("Snare", 38), ("Clap", 39), ("Rim", 37), ("Closed Hat", 42), ("Open Hat", 46), ("Pedal Hat", 44), ("Crash", 49),
    ("Low Tom", 45), ("Mid Tom", 47), ("High Tom", 50), ("Ride", 51), ("Ride Bell", 53), ("Tambourine", 54), ("Cowbell", 56), ("Shaker", 70),
]
let fifths = [3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1, 8]   // chord roots E♭ B♭ F C G D A E B F♯ D♭ A♭, as on an Omnichord
let chordTypes: [(suffix: String, steps: [Int])] = [("", [0, 4, 7]), ("m", [0, 3, 7]), ("7", [0, 4, 7, 10])]
let rootNames = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
let musicModes = ["piano", "drums", "strum", "theremin"]
let waves = ["Sine", "Triangle", "Saw"]
let metronomeTempos = [0, 80, 100, 120, 140]
let stringCount = 12
let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
let whiteSteps = [0, 2, 4, 5, 7, 9, 11]   // semitones of C D E F G A B
let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
func noteName(_ n: Int) -> String { noteNames[n % 12] + "\(n / 12 - 1)" }

enum Inst: Int { case piano, drums, strum }
enum Tool: Equatable { case mode(Int), down, up, octaves, dynamics, sound, sustain, wave, snap, slot(Int), metronome, save, done }
enum MusicHit: Equatable { case note(Int), pad(Int), chord(Int, Int), string(Int), theremin, tool(Tool), none }

struct LoopEvent { var t: Double, inst: Inst, note: Int, velocity: UInt8 }
enum SlotState { case empty, armed, recording, playing, stopped }
struct LoopSlot {
    var state = SlotState.empty, events: [LoopEvent] = []
    var origin = 0.0, originCycle = 0   // recording start (uptime) and the loop cycle it fell in
    var cycles = 1, startCycle = 0      // length in loop units; plays on cycles startCycle, +cycles, ...
}
struct ToolItem { var rect: NSRect, tool: Tool?, title: String, on = false, fill: NSColor? = nil }

// Sine/triangle/saw voices for the theremin. Targets are written on the main thread, the voice
// state is owned by the audio thread, which glides towards the targets.
final class Synth {
    let targetFreq = UnsafeMutablePointer<Double>.allocate(capacity: 10)
    let targetAmp = UnsafeMutablePointer<Double>.allocate(capacity: 10)
    let jump = UnsafeMutablePointer<Int>.allocate(capacity: 10)   // 1: start at the target, no glide
    var freq = [Double](repeating: 0, count: 10), amp = [Double](repeating: 0, count: 10), phase = [Double](repeating: 0, count: 10)
    var wave = 0

    init() {
        targetFreq.initialize(repeating: 0, count: 10); targetAmp.initialize(repeating: 0, count: 10)
        jump.initialize(repeating: 0, count: 10)
    }

    func set(_ v: Int, _ f: Double, _ a: Double, start: Bool = false) {
        targetFreq[v] = f; targetAmp[v] = a
        if start { jump[v] = 1 }
    }
    func stop(_ v: Int) { targetAmp[v] = 0 }
    func silence() { for v in 0..<10 { targetAmp[v] = 0 } }

    func makeNode(sampleRate sr: Double) -> AVAudioSourceNode {
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        return AVAudioSourceNode(format: format) { [unowned self] _, _, frames, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let wave = self.wave
            for f in 0..<Int(frames) {
                var s = 0.0
                for v in 0..<10 {
                    if self.jump[v] == 1 { self.freq[v] = self.targetFreq[v]; self.jump[v] = 0 }
                    if self.amp[v] < 0.0001 && self.targetAmp[v] == 0 { continue }
                    self.freq[v] += (self.targetFreq[v] - self.freq[v]) * 0.0015
                    self.amp[v] += (self.targetAmp[v] - self.amp[v]) * 0.002
                    self.phase[v] += 2 * .pi * self.freq[v] / sr
                    if self.phase[v] > 2 * .pi { self.phase[v] -= 2 * .pi }
                    let p = self.phase[v]
                    s += self.amp[v] * (wave == 1 ? 2 / .pi * asin(sin(p)) : wave == 2 ? (p / .pi - 1) * 0.6 : sin(p))
                }
                let out = Float(tanh(s * 0.35))
                for b in buffers { b.mData!.assumingMemoryBound(to: Float.self)[f] = out }
            }
            return noErr
        }
    }
}

final class MusicView: NSView {
    weak var owner: Piano?
    let toolbar: CGFloat = 44
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { owner?.close() } }   // Esc

    var modeIndex: Int { musicModes.firstIndex(of: cfg.musicMode) ?? 0 }
    var area: NSRect { NSRect(x: 0, y: toolbar, width: bounds.width, height: bounds.height - toolbar) }

    // Piano
    var whiteCount: Int { 7 * cfg.pianoOctaves + 1 }   // ends on a C
    var whiteWidth: CGFloat { bounds.width / CGFloat(whiteCount) }
    var blackHeight: CGFloat { area.height * 0.62 }
    func whiteNote(_ i: Int) -> Int { (owner?.start ?? 48) + 12 * (i / 7) + whiteSteps[i % 7] }
    func hasBlack(_ i: Int) -> Bool { [0, 1, 3, 4, 5].contains(i % 7) && i < whiteCount - 1 }
    func blackRect(_ i: Int) -> NSRect {
        let w = whiteWidth * 0.6
        return NSRect(x: CGFloat(i + 1) * whiteWidth - w / 2, y: area.minY, width: w, height: blackHeight)
    }
    // Drums: 2 rows of 8 pads
    func padRect(_ i: Int) -> NSRect {
        let w = area.width / 8, h = area.height / 2
        return NSRect(x: CGFloat(i % 8) * w, y: area.minY + CGFloat(i / 8) * h, width: w, height: h).insetBy(dx: 6, dy: 6)
    }
    // Strum: chord buttons on the left, strum plate on the right
    var chordArea: NSRect { NSRect(x: 0, y: area.minY, width: area.width * 0.62, height: area.height) }
    var plateArea: NSRect { NSRect(x: chordArea.maxX, y: area.minY, width: area.width - chordArea.width, height: area.height) }
    func chordRect(_ col: Int, _ row: Int) -> NSRect {
        let w = chordArea.width / 12, h = chordArea.height / 3
        return NSRect(x: CGFloat(col) * w, y: area.minY + CGFloat(row) * h, width: w, height: h).insetBy(dx: 4, dy: 4)
    }
    func stringX(_ i: Int) -> CGFloat { plateArea.minX + plateArea.width * (CGFloat(i) + 0.5) / CGFloat(stringCount) }
    func stringIndex(_ x: CGFloat) -> Int { min(max(Int((x - plateArea.minX) / plateArea.width * CGFloat(stringCount)), 0), stringCount - 1) }

    func toolbarItems() -> [ToolItem] {
        guard let o = owner else { return [] }
        var items: [ToolItem] = [], x: CGFloat = 8
        func add(_ w: CGFloat, _ tool: Tool?, _ title: String, on: Bool = false) {
            items.append(ToolItem(rect: NSRect(x: x, y: 4, width: w, height: toolbar - 8), tool: tool, title: title, on: on)); x += w + 8
        }
        for (i, m) in ["Piano", "Drums", "Strum", "Theremin"].enumerated() { add(112, .mode(i), m, on: i == modeIndex) }
        x += 16
        switch modeIndex {
        case 0:
            add(56, .down, "◀"); add(56, .up, "▶")
            add(150, nil, "\(noteName(o.start)) – \(noteName(o.start + 12 * cfg.pianoOctaves))")
            add(140, .octaves, "\(cfg.pianoOctaves) octave\(cfg.pianoOctaves == 1 ? "" : "s")")
            add(130, .dynamics, "Dynamics", on: cfg.pianoDynamics)
            add(230, .sound, "♪ " + (pianoSounds.first { $0.program == cfg.pianoSound }?.name ?? "Program \(cfg.pianoSound)"))
            add(110, .sustain, "Sustain", on: o.sustain)
        case 1:
            add(130, .dynamics, "Dynamics", on: cfg.pianoDynamics)
        case 2:
            add(230, .sound, "♪ " + (strumSounds.first { $0.program == cfg.strumSound }?.name ?? "Program \(cfg.strumSound)"))
        default:
            add(160, .wave, "∿ " + waves[min(max(cfg.thereminWave, 0), waves.count - 1)])
            add(150, .snap, "Snap to notes", on: cfg.thereminSnap)
        }
        var r = bounds.maxX - 8   // the rest, from the right edge
        func addRight(_ w: CGFloat, _ tool: Tool, _ title: String, on: Bool = false, fill: NSColor? = nil) {
            r -= w; items.append(ToolItem(rect: NSRect(x: r, y: 4, width: w, height: toolbar - 8), tool: tool, title: title, on: on, fill: fill)); r -= 8
        }
        addRight(100, .done, "Done")
        addRight(110, .save, o.savedUntil > now() ? "Saved ✓" : "Save MIDI")
        addRight(150, .metronome, cfg.metronomeBPM > 0 ? "♩ \(cfg.metronomeBPM) bpm" : "♩ Metronome", on: cfg.metronomeBPM > 0)
        for i in (0..<4).reversed() {
            switch o.slots[i].state {
            case .empty: addRight(72, .slot(i), "○ \(i + 1)")
            case .armed: addRight(72, .slot(i), "● \(i + 1)", fill: .systemRed.blended(withFraction: 0.4, of: .black))
            case .recording: addRight(72, .slot(i), "● \(i + 1)", fill: .systemRed)
            case .playing: addRight(72, .slot(i), "▶ \(i + 1)", on: true)
            case .stopped: addRight(72, .slot(i), "‖ \(i + 1)", fill: NSColor(white: 0.38, alpha: 1))
            }
        }
        return items
    }

    func hit(_ p: CGPoint) -> MusicHit {
        if p.y < toolbar {
            for it in toolbarItems() where it.tool != nil && it.rect.contains(p) { return .tool(it.tool!) }
            return .none
        }
        switch modeIndex {
        case 0:
            let i = min(max(Int(p.x / whiteWidth), 0), whiteCount - 1)
            if p.y < area.minY + blackHeight {   // black keys sit on top of the whites
                for j in [i - 1, i] where j >= 0 && hasBlack(j) && blackRect(j).contains(p) { return .note(whiteNote(j) + 1) }
            }
            return .note(whiteNote(i))
        case 1:
            for i in drumPads.indices where padRect(i).contains(p) { return .pad(i) }
            return .none
        case 2:
            if p.x < chordArea.maxX {
                return .chord(min(Int(p.x / (chordArea.width / 12)), 11), min(max(Int((p.y - area.minY) / (chordArea.height / 3)), 0), 2))
            }
            return .string(stringIndex(p.x))
        default:
            return .theremin
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 1).setFill(); bounds.fill()
        guard let o = owner else { return }
        let lit = color(cfg.ringColor)
        switch modeIndex {
        case 0: drawPiano(o, lit)
        case 1: drawDrums(o, lit)
        case 2: drawStrum(o, lit)
        default: drawTheremin(o, lit)
        }
        for it in toolbarItems() {
            if it.tool == nil { label(it.title, in: it.rect, size: 17, color: .white) } else { button(it.title, it.rect, on: it.on, fill: it.fill) }
        }
    }

    func drawPiano(_ o: Piano, _ lit: NSColor) {
        for i in 0..<whiteCount {
            let r = NSRect(x: CGFloat(i) * whiteWidth, y: area.minY, width: whiteWidth, height: area.height).insetBy(dx: 1, dy: 0)
            let level = o.sounding(whiteNote(i))
            (level == 2 ? lit : level == 1 ? lit.blended(withFraction: 0.55, of: .white)! : NSColor(white: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            if whiteNote(i) % 12 == 0 {
                label(noteName(whiteNote(i)), in: NSRect(x: r.minX, y: r.maxY - 30, width: r.width, height: 20), size: 13, color: NSColor(white: 0.45, alpha: 1))
            }
        }
        for i in 0..<whiteCount where hasBlack(i) {
            let level = o.sounding(whiteNote(i) + 1)
            (level == 2 ? lit.blended(withFraction: 0.35, of: .black)! : level == 1 ? lit.blended(withFraction: 0.65, of: .black)!
                : NSColor(white: 0.12, alpha: 1)).setFill()
            NSBezierPath(roundedRect: blackRect(i), xRadius: 3, yRadius: 3).fill()
        }
    }

    func drawDrums(_ o: Piano, _ lit: NSColor) {
        for (i, pad) in drumPads.enumerated() {
            let r = padRect(i), f = o.flash(o.padFlash[i])
            NSColor(white: 0.2, alpha: 1).blended(withFraction: f, of: lit)!.setFill()
            NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
            label(pad.name, in: r, size: 20, color: f > 0.5 ? .black : NSColor(white: 0.85, alpha: 1))
        }
    }

    func drawStrum(_ o: Piano, _ lit: NSColor) {
        for col in 0..<12 {
            for row in 0..<3 {
                let r = chordRect(col, row), on = o.chordCol == col && o.chordRow == row
                (on ? lit : NSColor(white: row == 0 ? 0.24 : row == 1 ? 0.19 : 0.15, alpha: 1)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
                label(rootNames[fifths[col]] + chordTypes[row].suffix, in: r, size: 18, color: on ? .black : .white)
            }
        }
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: plateArea.insetBy(dx: 6, dy: 6), xRadius: 14, yRadius: 14).fill()
        let notes = o.stringNotes
        for i in 0..<stringCount {
            let x = stringX(i), f = o.flash(o.stringFlash[i])
            NSColor(white: 0.55, alpha: 1).blended(withFraction: f, of: lit)!.setFill()
            NSRect(x: x - 1.5 - f * 1.5, y: plateArea.minY + 14, width: 3 + f * 3, height: plateArea.height - 52).fill()
            if i < notes.count {
                label(noteName(notes[i]), in: NSRect(x: x - 30, y: plateArea.maxY - 34, width: 60, height: 20), size: 12, color: NSColor(white: 0.5, alpha: 1))
            }
        }
    }

    func drawTheremin(_ o: Piano, _ lit: NSColor) {
        for n in 0...36 {   // a line per semitone, brighter for C
            let x = bounds.width * CGFloat(n) / 36, isC = n % 12 == 0
            NSColor(white: isC ? 0.35 : 0.16, alpha: 1).setFill()
            NSRect(x: x - 0.5, y: area.minY, width: isC ? 2 : 1, height: area.height).fill()
            if isC { label("C\(3 + n / 12)", in: NSRect(x: x + 6, y: area.maxY - 30, width: 40, height: 20), size: 13, color: NSColor(white: 0.5, alpha: 1), align: .left) }
        }
        label("left–right: pitch    up–down: volume", in: NSRect(x: 0, y: area.minY + 16, width: bounds.width, height: 24), size: 15, color: NSColor(white: 0.4, alpha: 1))
        lit.setStroke()
        for p in o.thereminPoints.values {
            let c = NSBezierPath(ovalIn: NSRect(x: p.x - 42, y: p.y - 42, width: 84, height: 84))
            c.lineWidth = 5; c.stroke()
        }
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
    var window: NSWindow?, view: MusicView?, redraw: Timer?
    var active: Bool { window != nil }
    let engine = AVAudioEngine()
    let samplers = [AVAudioUnitSampler(), AVAudioUnitSampler(), AVAudioUnitSampler()]   // by Inst
    let synth = Synth()
    var audioReady = false, loaded = [-1, -1, -1]
    var midiClient = MIDIClientRef(), midiSource = MIDIEndpointRef()
    var fingers: [Int: MusicHit] = [:]   // HID slot -> what that finger is on
    var counts: [Int: Int] = [:]         // piano note -> fingers holding it
    var sustain = false
    var padFlash = [Double](repeating: 0, count: 16), stringFlash = [Double](repeating: 0, count: 12)
    var chordCol = 3, chordRow = 0       // C major
    var strumTokens: [Int: Int] = [:]    // strum note -> latest pluck, so an older release doesn't cut a newer pluck
    var thereminVoices: [Int: Int] = [:], thereminPoints: [Int: CGPoint] = [:]
    var slots = [LoopSlot](repeating: LoopSlot(), count: 4)
    var slotFingers: [Int: (slot: Int, held: Bool)] = [:]
    var unit = 0.0                       // length of one loop cycle; 0 until the first loop is recorded
    var conducting = false, conductorGen = 0, cycleIndex = 0, cycleStart = DispatchTime.now(), cycleStartUp = 0.0
    var loopSounding: Set<Int> = []      // inst * 1000 + note
    var metroGen = 0, savedUntil = 0.0

    var base: Int { 60 - 12 * (cfg.pianoOctaves / 2) }   // middle C near the centre
    func startFor(shift: Int) -> Int { base + 12 * shift }
    func shiftAllowed(_ shift: Int) -> Bool { (12...(108 - 12 * cfg.pianoOctaves)).contains(startFor(shift: shift)) }
    var start: Int { min(max(startFor(shift: cfg.pianoShift), 12), 108 - 12 * cfg.pianoOctaves) }

    func sounding(_ n: Int) -> Int { (counts[n] ?? 0) > 0 ? 2 : loopSounding.contains(n) ? 1 : 0 }   // 2 you, 1 loop
    func flash(_ t: Double) -> CGFloat { CGFloat(max(0, 1 - (now() - t) / 0.35)) }
    var stringNotes: [Int] {
        let root = fifths[chordCol], steps = chordTypes[chordRow].steps
        let low = 43 + (root - 7 + 12) % 12   // lowest root between G2 and F♯3
        var notes: [Int] = [], octave = 0
        while notes.count < stringCount {
            for s in steps where notes.count < stringCount { notes.append(low + 12 * octave + s) }
            octave += 1
        }
        return notes
    }

    // MARK: window

    func open() {
        guard window == nil, let s = screen(for: targetDisplay()) ?? NSScreen.main else { return }
        endGesture()
        setUpAudio()
        let w = CalibrationWindow(contentRect: s.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = MusicView(frame: NSRect(origin: .zero, size: s.frame.size))
        v.owner = self
        w.contentView = v
        w.setFrame(s.frame, display: true)
        window = w; view = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        redraw = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let v = self.view else { return }
            let t = now() - 0.4
            if self.padFlash.contains(where: { $0 > t }) || self.stringFlash.contains(where: { $0 > t }) || self.savedUntil > t {
                v.needsDisplay = true
            }
        }
        if cfg.metronomeBPM > 0 { startMetronome() }
        log("music open: \(cfg.musicMode)")
    }

    func close() {
        allOff()
        if sustain { setSustain(false) }
        for i in slots.indices {
            switch slots[i].state {
            case .playing: slots[i].state = .stopped
            case .armed, .recording: slots[i] = LoopSlot()
            default: break
            }
        }
        conducting = false; conductorGen += 1; metroGen += 1
        releaseLoopNotes()
        redraw?.invalidate(); redraw = nil
        // A running engine renders silence ~100 times a second and keeps the audio device busy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.active else { return }
            self.engine.stop()
        }
        window?.orderOut(nil)
        window = nil; view = nil
        log("music closed")
    }

    // MARK: sound

    func setUpAudio() {
        if !audioReady {
            for s in samplers { engine.attach(s); engine.connect(s, to: engine.mainMixerNode, format: nil) }
            let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let node = synth.makeNode(sampleRate: sr > 0 ? sr : 48000)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: node.outputFormat(forBus: 0))
            MIDIClientCreate("MacTouch" as CFString, nil, nil, &midiClient)
            MIDISourceCreateWithProtocol(midiClient, "MacTouch Piano" as CFString, ._1_0, &midiSource)
            audioReady = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { log("music audio failed to start: \(error)") }
        }
        load(.piano, cfg.pianoSound, bank: kAUSampler_DefaultMelodicBankMSB)
        load(.strum, cfg.strumSound, bank: kAUSampler_DefaultMelodicBankMSB)
        load(.drums, 0, bank: kAUSampler_DefaultPercussionBankMSB)
        synth.wave = cfg.thereminWave
    }

    func load(_ i: Inst, _ program: Int, bank: Int) {
        guard loaded[i.rawValue] != program else { return }
        do {
            try samplers[i.rawValue].loadSoundBankInstrument(at: soundBank, program: UInt8(program), bankMSB: UInt8(bank),
                                                             bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            loaded[i.rawValue] = program
        } catch { log("music sound \(program) failed to load: \(error)") }
    }

    func settingsChanged() {
        guard active else { return }
        allOff(); setUpAudio(); view?.needsDisplay = true
    }

    // MIDI 1.0 channel voice message on the virtual source.
    func midi(_ status: UInt8, _ a: UInt8, _ b: UInt8) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = UInt32(0x2) << 28 | UInt32(status) << 16 | UInt32(a) << 8 | UInt32(b)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(midiSource, &list)
    }

    func channel(_ i: Inst) -> UInt8 { [0, 9, 1][i.rawValue] }   // piano 1, strum 2, drums 10

    func play(_ i: Inst, _ n: Int, _ v: UInt8, record: Bool = true) {
        if record { recordEvent(i, n, v) }
        samplers[i.rawValue].startNote(UInt8(n), withVelocity: v, onChannel: 0)
        midi(0x90 | channel(i), UInt8(n), v)
    }

    func release(_ i: Inst, _ n: Int, record: Bool = true) {
        if record { recordEvent(i, n, 0) }
        samplers[i.rawValue].stopNote(UInt8(n), onChannel: 0)
        midi(0x80 | channel(i), UInt8(n), 0)
    }

    func noteOn(_ n: Int, velocity: UInt8) {
        counts[n, default: 0] += 1
        if counts[n] == 1 { play(.piano, n, velocity) }
    }

    func noteOff(_ n: Int) {
        guard let c = counts[n], c > 0 else { return }
        counts[n] = c - 1
        if c == 1 { release(.piano, n) }
    }

    func hitPad(_ i: Int, velocity: UInt8) {
        let n = drumPads[i].note
        play(.drums, n, velocity); padFlash[i] = now()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.release(.drums, n) }
    }

    func pluck(_ i: Int) {
        let notes = stringNotes
        guard i < notes.count else { return }
        let n = notes[i], token = (strumTokens[n] ?? 0) + 1
        strumTokens[n] = token
        play(.strum, n, 100); stringFlash[i] = now()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.strumTokens[n] == token else { return }
            self.release(.strum, n)
        }
    }

    func allOff() {
        for (n, c) in counts where c > 0 { counts[n] = 1; noteOff(n) }
        fingers.removeAll(); slotFingers.removeAll()
        thereminVoices.removeAll(); thereminPoints.removeAll(); synth.silence()
    }

    func setSustain(_ on: Bool) {
        sustain = on
        samplers[Inst.piano.rawValue].sendController(64, withValue: on ? 127 : 0, onChannel: 0)
        midi(0xB0, 64, on ? 127 : 0)
    }

    // With Dynamics on, the front of a key or pad (lower on the screen) plays louder.
    func velocity(_ p: CGPoint, in r: NSRect? = nil) -> UInt8 {
        guard cfg.pianoDynamics, let v = view else { return 100 }
        let r = r ?? v.area
        return UInt8(45 + 82 * min(max((p.y - r.minY) / max(r.height, 1), 0), 1))
    }

    // MARK: theremin

    func theremin(_ p: CGPoint) -> (freq: Double, amp: Double) {
        guard let v = view else { return (0, 0) }
        var semis = Double(p.x / v.bounds.width) * 36
        if cfg.thereminSnap { semis = semis.rounded() }
        let y = Double(min(max((p.y - v.area.minY) / v.area.height, 0), 1))
        return (130.81 * pow(2, semis / 12), 0.15 + 0.85 * y)
    }

    func thereminDown(_ finger: Int, _ p: CGPoint) {
        guard let voice = (0..<10).first(where: { !thereminVoices.values.contains($0) }) else { return }
        thereminVoices[finger] = voice; thereminPoints[finger] = p
        let s = theremin(p)
        synth.set(voice, s.freq, s.amp, start: true)
    }

    func thereminMove(_ finger: Int, _ p: CGPoint) {
        guard let voice = thereminVoices[finger] else { return }
        thereminPoints[finger] = p
        let s = theremin(p)
        synth.set(voice, s.freq, s.amp)
    }

    func thereminUp(_ finger: Int) {
        if let voice = thereminVoices.removeValue(forKey: finger) { synth.stop(voice) }
        thereminPoints[finger] = nil
    }

    // MARK: loops

    // One loop cycle is the first loop's length (snapped to whole beats when the metronome runs). Later
    // loops start on the cycle they were begun in and last a whole number of cycles, so all stay in step.
    func recordEvent(_ i: Inst, _ n: Int, _ v: UInt8) {
        guard let s = slots.firstIndex(where: { $0.state == .armed || $0.state == .recording }) else { return }
        if slots[s].state == .armed {
            if v == 0 { return }   // a release left over from before the first note
            beginRecording(s)
        }
        slots[s].events.append(LoopEvent(t: max(0, now() - slots[s].origin), inst: i, note: n, velocity: v))
    }

    func beginRecording(_ s: Int) {
        if unit > 0 && !conducting { cycleIndex = 0; startConductor(.now(), up: now()) }
        if conducting {
            slots[s].origin = cycleStartUp - unit; slots[s].originCycle = cycleIndex - 1
        } else if cfg.metronomeBPM > 0 {   // first loop: start on the nearest beat
            let beat = 60 / Double(cfg.metronomeBPM)
            slots[s].origin = metroStart + ((now() - metroStart) / beat).rounded() * beat
        } else {
            slots[s].origin = now()
        }
        slots[s].state = .recording
        view?.needsDisplay = true
    }

    func finishRecording(_ s: Int) {
        var slot = slots[s]
        let elapsed = now() - slot.origin
        guard !slot.events.isEmpty else { slots[s] = LoopSlot(); return }
        if conducting {
            slot.cycles = max(1, Int((elapsed / unit).rounded(.up)))
            slot.startCycle = slot.originCycle
        } else {
            var length = elapsed
            if cfg.metronomeBPM > 0 {
                let beat = 60 / Double(cfg.metronomeBPM)
                length = max(1, (elapsed / beat).rounded()) * beat
            }
            guard length > 0.2 else { slots[s] = LoopSlot(); return }
            unit = length; slot.cycles = 1; slot.startCycle = 0; cycleIndex = 0
            startConductor(.now() + max(0, slot.origin + length - now()), up: max(now(), slot.origin + length))
        }
        let length = Double(slot.cycles) * unit
        slot.events = slot.events.map { var e = $0; e.t = e.t.truncatingRemainder(dividingBy: length); return e }
        var open: [Int: LoopEvent] = [:]   // close notes still held at the loop point
        for e in slot.events { let k = e.inst.rawValue * 1000 + e.note; if e.velocity > 0 { open[k] = e } else { open[k] = nil } }
        for e in open.values { slot.events.append(LoopEvent(t: length - 0.005, inst: e.inst, note: e.note, velocity: 0)) }
        slot.events.sort { $0.t < $1.t }
        slot.state = .playing
        slots[s] = slot
        log(String(format: "loop %d recorded: %.2f s, %d notes", s + 1, length, slot.events.filter { $0.velocity > 0 }.count))
        if conducting && cycleIndex > slot.startCycle + slot.cycles { slots[s].startCycle = cycleIndex }   // safety: play next cycle
    }

    func slotTapped(_ i: Int) {
        switch slots[i].state {
        case .empty:
            if let r = slots.firstIndex(where: { $0.state == .armed || $0.state == .recording }) {
                if slots[r].state == .recording { finishRecording(r) } else { slots[r].state = .empty }
            }
            slots[i].state = .armed
        case .armed: slots[i].state = .empty
        case .recording: finishRecording(i)
        case .playing: slots[i].state = .stopped; releaseLoopNotes()
        case .stopped:
            if !conducting { cycleIndex = 0; slots[i].startCycle = 0; slots[i].state = .playing; startConductor(.now(), up: now()) }
            else { slots[i].startCycle = cycleIndex; slots[i].state = .playing }
        }
        view?.needsDisplay = true
    }

    func clearSlot(_ i: Int) {
        slots[i] = LoopSlot()
        releaseLoopNotes()
        if slots.allSatisfy({ $0.state == .empty }) { unit = 0; conducting = false; conductorGen += 1 }
        log("loop \(i + 1) cleared")
        view?.needsDisplay = true
    }

    func startConductor(_ at: DispatchTime, up: Double) {
        conducting = true; conductorGen += 1
        cycleStart = at; cycleStartUp = up
        let gen = conductorGen
        if up <= now() { boundary(gen) } else { DispatchQueue.main.asyncAfter(deadline: at) { [weak self] in self?.boundary(gen) } }
    }

    // At each cycle boundary, schedule the passes of the loops due in this cycle, then the next boundary.
    // Times are taken from the previous boundary, not the clock, so the loops do not drift.
    func boundary(_ gen: Int) {
        guard gen == conductorGen else { return }
        let start = cycleStart, idx = cycleIndex
        for s in slots.indices where slots[s].state == .playing && idx >= slots[s].startCycle && (idx - slots[s].startCycle) % slots[s].cycles == 0 {
            for e in slots[s].events {
                DispatchQueue.main.asyncAfter(deadline: start + e.t) { [weak self] in
                    guard let self, gen == self.conductorGen, self.slots[s].state == .playing else { return }
                    self.loopEvent(e)
                }
            }
        }
        cycleIndex += 1; cycleStart = start + unit; cycleStartUp += unit
        DispatchQueue.main.asyncAfter(deadline: cycleStart) { [weak self] in self?.boundary(gen) }
    }

    func loopEvent(_ e: LoopEvent) {
        let k = e.inst.rawValue * 1000 + e.note
        if e.velocity > 0 {
            play(e.inst, e.note, e.velocity, record: false); loopSounding.insert(k)
            if e.inst == .drums, let i = drumPads.firstIndex(where: { $0.note == e.note }) { padFlash[i] = now() }
        } else {
            if e.inst != .piano || (counts[e.note] ?? 0) == 0 { release(e.inst, e.note, record: false) }   // unless you hold it
            loopSounding.remove(k)
        }
        view?.needsDisplay = true
    }

    func releaseLoopNotes() {
        for k in loopSounding { release(Inst(rawValue: k / 1000) ?? .piano, k % 1000, record: false) }
        loopSounding.removeAll()
    }

    // MARK: metronome

    var metroStart = 0.0
    func startMetronome() {
        guard cfg.metronomeBPM > 0 else { return }
        metroGen += 1
        let gen = metroGen, beat = 60 / Double(cfg.metronomeBPM)
        let base = conducting ? cycleStartUp - unit : now()   // line up with the loops if they run
        metroStart = base
        let first = ((now() - base) / beat).rounded(.up)
        tick(gen, Int(first), at: .now() + max(0, base + first * beat - now()), beat)
    }

    func tick(_ gen: Int, _ n: Int, at: DispatchTime, _ beat: Double) {
        DispatchQueue.main.asyncAfter(deadline: at) { [weak self] in
            guard let self, gen == self.metroGen else { return }
            let note: UInt8 = n % 4 == 0 ? 76 : 77   // high wood block on the bar, low on the other beats
            self.samplers[Inst.drums.rawValue].startNote(note, withVelocity: n % 4 == 0 ? 110 : 80, onChannel: 0)
            self.tick(gen, n + 1, at: at + beat, beat)
        }
    }

    // MARK: MIDI file

    // Every loop as its own track of a type 1 standard MIDI file in ~/Music/MacTouch.
    func saveMIDI() {
        let used = slots.filter { $0.state == .playing || $0.state == .stopped }
        guard !used.isEmpty else { log("nothing to save: no loops"); return }
        let bpm = Double(cfg.metronomeBPM > 0 ? cfg.metronomeBPM : 120), ppq = 480.0
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).reversed().map { UInt8(v >> (8 * $0) & 0xFF) } }
        func vlq(_ v: Int) -> [UInt8] {
            var v = max(v, 0), b = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { b.insert(UInt8(v & 0x7F | 0x80), at: 0); v >>= 7 }
            return b
        }
        func track(_ body: [UInt8]) -> [UInt8] { let d = body + [0x00, 0xFF, 0x2F, 0x00]; return Array("MTrk".utf8) + be(d.count, 4) + d }
        var tracks = [track([0x00, 0xFF, 0x51, 0x03] + be(Int(60_000_000 / bpm), 3))]
        for slot in used {
            var body: [UInt8] = [0x00, 0xC0, UInt8(cfg.pianoSound), 0x00, 0xC1, UInt8(cfg.strumSound)]
            var last = 0
            for e in slot.events {
                let tick = Int(e.t * bpm / 60 * ppq)
                let status: UInt8 = (e.velocity > 0 ? 0x90 : 0x80) | channel(e.inst)
                body += vlq(tick - last); body += [status, UInt8(e.note), e.velocity]
                last = tick
            }
            let end = Int(Double(slot.cycles) * unit * bpm / 60 * ppq)
            body += vlq(end - last) + [0xFF, 0x01, 0x00]   // empty text event marks the loop length
            tracks.append(track(body))
        }
        var file: [UInt8] = Array("MThd".utf8)
        file += be(6, 4); file += be(1, 2); file += be(tracks.count, 2); file += be(Int(ppq), 2)
        for t in tracks { file += t }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/MacTouch")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("MacTouch \(f.string(from: Date())).mid")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(file).write(to: url)
            savedUntil = now() + 2; view?.needsDisplay = true
            log("saved \(used.count) loop(s) to \(url.path)")
        } catch { log("saving MIDI failed: \(error)") }
    }

    // MARK: touches

    // Called once per HID report with every touching finger: slot -> global screen point.
    func feed(_ touches: [Int: CGPoint]) {
        guard let v = view, let w = window else { return }
        let origin = w.frame.origin, primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var changed = false
        for (finger, g) in touches {
            let p = CGPoint(x: g.x - origin.x, y: g.y - (primaryHeight - origin.y - w.frame.height))   // view coords
            let h = v.hit(p)
            if let old = fingers[finger] { changed = moved(finger, from: old, to: h, at: p) || changed; continue }
            declareUserActivity()
            fingers[finger] = h; changed = true
            if !pressed(finger, h, at: p) { return }   // closed
        }
        for (finger, h) in fingers where touches[finger] == nil {   // lifted
            lifted(finger, h)
            fingers[finger] = nil; changed = true
        }
        if changed { v.needsDisplay = true }
    }

    func pressed(_ finger: Int, _ h: MusicHit, at p: CGPoint) -> Bool {
        switch h {
        case .note(let n): noteOn(n, velocity: velocity(p))
        case .pad(let i): hitPad(i, velocity: velocity(p, in: view?.padRect(i)))
        case .chord(let c, let r): chordCol = c; chordRow = r
        case .string(let i): pluck(i)
        case .theremin: thereminDown(finger, p)
        case .tool(let t): return tool(t, finger)
        case .none: break
        }
        return true
    }

    func moved(_ finger: Int, from old: MusicHit, to h: MusicHit, at p: CGPoint) -> Bool {
        switch (old, h) {
        case (.note(let a), .note(let b)) where a != b:   // slide onto another key
            noteOff(a); noteOn(b, velocity: velocity(p)); fingers[finger] = h
        case (.string(let a), .string(let b)) where a != b:   // every string crossed sounds
            let step = b > a ? 1 : -1
            for i in stride(from: a + step, through: b, by: step) { pluck(i) }
            fingers[finger] = h
        case (.chord, .chord(let c, let r)) where c != chordCol || r != chordRow:
            chordCol = c; chordRow = r; fingers[finger] = h
        case (.theremin, _):
            thereminMove(finger, p)
        default:
            return false
        }
        return true
    }

    func lifted(_ finger: Int, _ h: MusicHit) {
        switch h {
        case .note(let n): noteOff(n)
        case .theremin: thereminUp(finger)
        case .tool(.slot(let i)):
            if slotFingers[finger]?.held != true { slotTapped(i) }
            slotFingers[finger] = nil
        default: break
        }
    }

    // Toolbar buttons act on touch-down, except loop slots: tap on lift, hold 0.7 s to clear.
    func tool(_ t: Tool, _ finger: Int) -> Bool {
        switch t {
        case .mode(let i):
            allOff(); setSetting("musicMode", musicModes[i]); settingsChanged()
        case .down, .up:
            let shift = cfg.pianoShift + (t == .up ? 1 : -1)
            if shiftAllowed(shift) { allOff(); setSetting("pianoShift", shift) }
        case .octaves:
            allOff()
            setSetting("pianoOctaves", cfg.pianoOctaves % 6 + 1)
            if !shiftAllowed(cfg.pianoShift) { setSetting("pianoShift", 0) }
        case .dynamics: setSetting("pianoDynamics", !cfg.pianoDynamics)
        case .sound:
            let list = cfg.musicMode == "strum" ? strumSounds : pianoSounds
            let key = cfg.musicMode == "strum" ? "strumSound" : "pianoSound"
            let current = cfg.musicMode == "strum" ? cfg.strumSound : cfg.pianoSound
            let i = list.firstIndex { $0.program == current } ?? -1
            setSetting(key, list[(i + 1) % list.count].program)
            settingsChanged()
        case .sustain: setSustain(!sustain)
        case .wave: setSetting("thereminWave", (cfg.thereminWave + 1) % waves.count); synth.wave = cfg.thereminWave
        case .snap: setSetting("thereminSnap", !cfg.thereminSnap)
        case .slot(let i):
            slotFingers[finger] = (i, false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, let f = self.slotFingers[finger], f.slot == i, !f.held else { return }
                self.slotFingers[finger] = (i, true)
                self.clearSlot(i)
            }
        case .metronome:
            let i = metronomeTempos.firstIndex(of: cfg.metronomeBPM) ?? 0
            setSetting("metronomeBPM", metronomeTempos[(i + 1) % metronomeTempos.count])
            metroGen += 1
            startMetronome()
        case .save: saveMIDI()
        case .done: close(); mode = .done; return false   // ignore the fingers still down
        }
        return true
    }
}
let piano = Piano()
