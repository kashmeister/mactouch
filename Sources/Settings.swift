import Foundation
import CoreGraphics

// MARK: settings

struct Config {
    var vid = 0x222A, pid = 0, display = "0x2613:0x2023"
    var flipX = false, flipY = false, swap = false
    var cal: [Double] = [1, 0, 1, 0]
    var oneFingerScroll = false, twoFingerTap = false, invertScroll = false, paused = false, keepKeyboard = true, autoKeyboard = true
    var keyboardFollowsTouch = true
    var pianoOctaves = 3, pianoSound = 0, pianoShift = 0, pianoDynamics = false
    var musicMode = "piano", strumSound = 46, thereminWave = 0, thereminSnap = false, metronomeBPM = 0
    var hold = 0.6, scrollScale = 1.0, zoomScale = 1.0, titlebar = 44.0
    var zoom = "gesture", swipes = "3", edge = 12.0, ringColor = "#FF6A00", inkPredict = 8.0
    var dragApps = ["AssistiveControl"], zoomKeyApps: [String] = []
}

let identityCal: [Double] = [1, 0, 1, 0]

// MARK: command line

enum OptionKind { case bool, double, int, string, zoom, swipes, list, cal, color }
struct Option {
    let flag: String, key: String, kind: OptionKind, help: String
    var spelled: String { flag + (kind == .bool ? "" : "=") }
}

/// Settings options. Applied for one run, or stored with --save; the menu sets most of them too.
/// The first group are screen settings, kept in a touchscreen's profile.
let options = [
    Option(flag: "--vid", key: "vid", kind: .int, help: "USB vendor ID of the touchscreen whose profile --save changes"),
    Option(flag: "--pid", key: "pid", kind: .int, help: "and its product ID (0 or omitted: any)"),
    Option(flag: "--display", key: "display", kind: .string, help: "its display, as VENDOR:MODEL[:SERIAL] (see --check) or main; new screens are paired by touch"),
    Option(flag: "--flip-x", key: "flipX", kind: .bool, help: "mirror X, after the display's rotation"),
    Option(flag: "--flip-y", key: "flipY", kind: .bool, help: "mirror Y"),
    Option(flag: "--swap", key: "swap", kind: .bool, help: "swap X and Y"),
    Option(flag: "--cal", key: "cal", kind: .cal, help: "ax,bx,ay,by[,x0,x1,y0,y1]: calibration, touched = a*target + b in panel fractions, and touched values near the edges (set by the wizard)"),
    Option(flag: "--one-finger-scroll", key: "oneFingerScroll", kind: .bool, help: "one finger scrolls; hold, then move, drags"),
    Option(flag: "--hold", key: "hold", kind: .double, help: "long-press time in seconds (0.6)"),
    Option(flag: "--two-finger-tap", key: "twoFingerTap", kind: .bool, help: "a two-finger tap right-clicks"),
    Option(flag: "--scroll-scale", key: "scrollScale", kind: .double, help: "scroll speed (1.0)"),
    Option(flag: "--invert-scroll", key: "invertScroll", kind: .bool, help: "reverse scrolling"),
    Option(flag: "--zoom", key: "zoom", kind: .zoom, help: "pinch as gesture (trackpad zoom), keys (Cmd+/Cmd-) or off"),
    Option(flag: "--zoom-scale", key: "zoomScale", kind: .double, help: "pinch sensitivity (1.0)"),
    Option(flag: "--zoom-key-apps", key: "zoomKeyApps", kind: .list, help: "A,B: apps (window owner names) where pinch sends Cmd+/Cmd-"),
    Option(flag: "--drag-apps", key: "dragApps", kind: .list, help: "A,B: apps where one finger always drags (AssistiveControl, the Accessibility Keyboard)"),
    Option(flag: "--titlebar", key: "titlebar", kind: .double, help: "touches this many points below a window's top drag at once (44; 0 off)"),
    Option(flag: "--edge", key: "edge", kind: .double, help: "touches this close to a window edge resize it (12; 0 off)"),
    Option(flag: "--swipes", key: "swipes", kind: .swipes, help: "multi-finger swipes with 3 or 4 fingers (3), 4 only (4), or off"),
    Option(flag: "--auto-keyboard", key: "autoKeyboard", kind: .bool, help: "expand the Accessibility Keyboard when a touch focuses a text field (on)"),
    Option(flag: "--keyboard-follows-touch", key: "keyboardFollowsTouch", kind: .bool, help: "turn the Accessibility Keyboard off while no touchscreen is connected, and back on with one (on)"),
    Option(flag: "--keep-keyboard", key: "keepKeyboard", kind: .bool, help: "put the Accessibility Keyboard back after display sleep and unlock (on)"),
    Option(flag: "--ring-color", key: "ringColor", kind: .color, help: "hold ring colour, #RRGGBB or accent (#FF6A00)"),
    Option(flag: "--ink-predict", key: "inkPredict", kind: .double, help: "whiteboard lines run this many ms ahead of the finger (8; 0 to 50)"),
    Option(flag: "--piano-octaves", key: "pianoOctaves", kind: .int, help: "music piano size, 1 to 6 octaves (3)"),
    Option(flag: "--piano-sound", key: "pianoSound", kind: .int, help: "music piano General MIDI program (0)"),
]
let actionFlags: Set<String> = ["--check", "--save", "--reset", "--probe", "--raw", "--help"]

let usage = """
usage: MacTouch [settings]            run; normally started at login by its launch agent
       MacTouch --check               print displays, touchscreens, profiles, permissions and settings
       MacTouch --save [settings]     store settings and exit        MacTouch --reset   forget all settings
       MacTouch --probe [--raw]       log contacts without posting events (--raw: every HID value and report)
       MacTouch --self-test           check the coordinate maths and the known controllers' report layouts
       MacTouch --capture=VID:PID[:INTERFACE] [--seconds=30]
                                      take a USB device and print its reports (see CONTRIBUTING.md)
settings (numbers decimal or 0x hex; switches take =false to turn off):

""" + options.map { o in "  " + o.spelled.padding(toLength: options.map(\.spelled.count).max()! + 2, withPad: " ", startingAt: 0) + o.help }
    .joined(separator: "\n")

func num(_ s: Substring) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }
func parse(_ s: String, _ kind: OptionKind) -> Any? {
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
        return validCal(s.split(separator: ",").compactMap { Double($0) })
    }
}

let defaults = UserDefaults.standard

// --reset forgets every setting, every touchscreen profile and the remembered keyboard positions.
func resetSettings() -> Never {
    for o in options { defaults.removeObject(forKey: o.key) }
    for k in ["paused", "previousCal", "keyboardPositions", "screens"] { defaults.removeObject(forKey: k) }
    print("settings reset")
    exit(0)
}

// MARK: touchscreen profiles

// Each touchscreen MacTouch has met keeps a profile in the defaults key "screens", keyed by an id
// such as "222a:0001". A profile holds:
//   name, mode         its name in the menu, and a ScreenMode raw value (auto, multi, single, ignore)
//   vid, pid, serial   what it matches: a device with that vendor, product (0: any) and serial ("": any)
//   display            its display, "VENDOR:MODEL[:SERIAL]", "main", or "" until paired
//   cal, previousCal   calibration and the one before it (Undo); calPanel marks them as panel fractions
//   flipX, flipY, swap, oneFingerScroll, hold   its screen settings
// Everything else is global. cfg is the global settings overlaid with the active screen's profile.
let profileKeys: Set<String> = ["display", "cal", "previousCal", "flipX", "flipY", "swap", "oneFingerScroll", "hold"]
var screens: [String: [String: Any]] {
    get { defaults.dictionary(forKey: "screens") as? [String: [String: Any]] ?? [:] }
    set { defaults.set(newValue, forKey: "screens") }
}
func profileName(_ id: String) -> String { screens[id]?["name"] as? String ?? id }
func profileMode(_ id: String?) -> ScreenMode { ScreenMode(rawValue: id.flatMap { screens[$0]?["mode"] as? String } ?? "") ?? .auto }
func setProfile(_ id: String, _ profile: [String: Any]) { var all = screens; all[id] = profile; screens = all }
func setProfile(_ id: String, _ key: String, _ value: Any?) {
    var all = screens, p = all[id] ?? [:]
    p[key] = value
    all[id] = p; screens = all
}

// 3.0 and older kept one touchscreen's settings at the top level; they become its profile once. The
// old keys stay, so an older MacTouch still finds them.
func migrateLegacySettings() {
    guard defaults.object(forKey: "screens") == nil else { return }
    var p: [String: Any] = ["name": "Touch screen", "mode": ScreenMode.auto.rawValue, "vid": defaults.object(forKey: "vid") as? Int ?? 0x222A,
                            "pid": defaults.object(forKey: "pid") as? Int ?? 0, "serial": ""]
    for k in profileKeys { if let v = defaults.object(forKey: k) { p[k] = v } }
    if p["display"] == nil { p["display"] = Config().display }
    screens = [String(format: "%04x:%04x", p["vid"] as! Int, p["pid"] as! Int): p]
}

// --save with screen settings stores them in the profile for --vid/--pid (made if missing), or in the
// only profile when no vid is given.
func saveOptions(_ overrides: [String: Any]) -> Never {
    let deviceKeys = profileKeys.union(["vid", "pid"])
    let forScreen = overrides.filter { deviceKeys.contains($0.key) }
    if !forScreen.isEmpty {
        let vid = forScreen["vid"] as? Int, pid = forScreen["pid"] as? Int ?? 0
        var all = screens
        let id = vid.map { v in all.first { ($0.value["vid"] as? Int) == v && ($0.value["pid"] as? Int ?? 0) == pid }?.key
                                ?? String(format: "%04x:%04x", v, pid) }
            ?? (all.count == 1 ? all.keys.first! : nil)
        guard let id else { fail("several touchscreen profiles exist; say which with --vid (and --pid)") }
        var p = all[id] ?? ["name": "Touch screen", "mode": ScreenMode.auto.rawValue, "vid": vid ?? 0, "pid": pid, "serial": ""]
        if forScreen["cal"] != nil { p["calPanel"] = true; if let old = p["cal"] { p["previousCal"] = old } }
        for (k, v) in forScreen { p[k] = v }
        all[id] = p; screens = all
    }
    for (k, v) in overrides where !profileKeys.contains(k) && k != "vid" && k != "pid" { defaults.set(v, forKey: k) }
    print("saved: " + overrides.keys.sorted().joined(separator: ", "))
    exit(0)
}
var activeProfile: String?   // profile of the touchscreen that is being touched (or was last)

func loadConfig() -> Config {
    var c = Config()
    func rd<T>(_ k: String, _ p: WritableKeyPath<Config, T>) { if let v = defaults.object(forKey: k) as? T { c[keyPath: p] = v } }
    if let id = activeProfile, let p = screens[id] {   // the screen's own values; this run's options still win
        let run = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        func pr<T>(_ k: String, _ kp: WritableKeyPath<Config, T>) {
            if let v = (run[k] ?? p[k]) as? T { c[keyPath: kp] = v }
        }
        pr("vid", \.vid); pr("pid", \.pid); pr("display", \.display)
        pr("flipX", \.flipX); pr("flipY", \.flipY); pr("swap", \.swap); pr("cal", \.cal)
        pr("oneFingerScroll", \.oneFingerScroll); pr("hold", \.hold)
    } else {   // no touchscreen yet: the top-level values (as set by 3.0 and older)
        rd("vid", \.vid); rd("pid", \.pid); rd("display", \.display)
        rd("flipX", \.flipX); rd("flipY", \.flipY); rd("swap", \.swap); rd("cal", \.cal)
        rd("oneFingerScroll", \.oneFingerScroll); rd("hold", \.hold)
    }
    rd("twoFingerTap", \.twoFingerTap)
    rd("invertScroll", \.invertScroll); rd("paused", \.paused); rd("keepKeyboard", \.keepKeyboard)
    rd("scrollScale", \.scrollScale); rd("zoomScale", \.zoomScale); rd("titlebar", \.titlebar)
    rd("ringColor", \.ringColor); rd("zoom", \.zoom); rd("swipes", \.swipes); rd("edge", \.edge); rd("dragApps", \.dragApps); rd("zoomKeyApps", \.zoomKeyApps)
    rd("pianoOctaves", \.pianoOctaves); rd("pianoSound", \.pianoSound); rd("pianoShift", \.pianoShift); rd("pianoDynamics", \.pianoDynamics)
    rd("musicMode", \.musicMode); rd("strumSound", \.strumSound); rd("thereminWave", \.thereminWave)
    rd("thereminSnap", \.thereminSnap); rd("metronomeBPM", \.metronomeBPM); rd("autoKeyboard", \.autoKeyboard); rd("keyboardFollowsTouch", \.keyboardFollowsTouch)
    rd("inkPredict", \.inkPredict); c.inkPredict = min(max(c.inkPredict, 0), 50)
    c.pianoOctaves = min(max(c.pianoOctaves, 1), 6); c.pianoSound = min(max(c.pianoSound, 0), 127)
    c.cal = validCal(c.cal) ?? identityCal
    return c
}

// Store a setting from the menu; it also beats any command-line value for the rest of this run.
// Screen settings go to the given profile, else the active one.
func setSetting(_ key: String, _ value: Any, profile: String? = nil) {
    if profileKeys.contains(key), let id = profile ?? activeProfile, screens[id] != nil {
        setProfile(id, key, value)
        log("set \(key) = \(value) for \(profileName(id))")
    } else {
        defaults.set(value, forKey: key)
        log("set \(key) = \(value)")
    }
    var vol = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    vol.removeValue(forKey: key)
    defaults.setVolatileDomain(vol, forName: UserDefaults.argumentDomain)
    cfg = loadConfig()
}

// Every calibration change keeps the one it replaces, so Undo Calibration can switch back.
/// A usable calibration (see applyCal), or nil. Edge values that would not keep an axis rising are
/// dropped.
func validCal(_ v: Any?) -> [Double]? {
    guard let c = v as? [Double], c.count == 4 || c.count == 8, c[0] != 0, c[2] != 0 else { return nil }
    guard c.count == 8 else { return c }
    func rising(_ a: Double, _ b: Double, _ lo: Double, _ hi: Double) -> Bool {
        a > 0 && lo < a * calInner + b && hi > a * (1 - calInner) + b
    }
    return rising(c[0], c[1], c[4], c[5]) && rising(c[2], c[3], c[6], c[7]) ? c : Array(c.prefix(4))
}
func calibration(_ id: String?) -> [Double] {
    id.flatMap { validCal(screens[$0]?["cal"]) } ?? (id == nil ? cfg.cal : identityCal)
}
func previousCal(_ id: String?) -> [Double]? {
    validCal(id.flatMap { screens[$0]?["previousCal"] } ?? defaults.array(forKey: "previousCal"))
}
func setCalibration(_ new: [Double], profile: String? = nil) {
    let id = profile ?? activeProfile, old = calibration(id)
    if new != old {
        if let id, screens[id] != nil { setProfile(id, "previousCal", old) } else { defaults.set(old, forKey: "previousCal") }
    }
    if let id, screens[id] != nil { setProfile(id, "calPanel", true) }
    setSetting("cal", new, profile: id)
}
