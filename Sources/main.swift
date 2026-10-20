// MacTouch: drive USB touchscreens as mouse, scroll and pinch-zoom input on macOS, which has no
// touchscreen driver of its own. Three kinds are handled, told apart when they attach: HID multi-touch
// digitizers (e.g. the ILITEK controller in Wisecoco displays, USB 222a:0001), single-touch screens that
// macOS drives as an absolute mouse (e.g. the CX158 in mouse mode, 0416:c169), and multi-touch
// interfaces macOS attaches no driver to, read directly over USB (the CX158 in digitizer mode,
// eeef:2828). Each touchscreen keeps a profile: its display, calibration and screen settings.
// Runs as a menu bar app; settings live in the defaults domain local.mactouch.
//
// Gestures
//   tap / double-tap        click / double click
//   tap, then touch + move  select by word (double-click drag); twice, then touch + move: by line
//   1 finger, move          drag            (one-finger scroll: scroll)
//   1 finger, hold          right click     (one-finger scroll: hold+move = drag; hold+lift, or keep
//                                            holding still another 0.5 s, = right click)
//   2 fingers, move         scroll
//   2 fingers, pinch        zoom (trackpad magnify, or Cmd+/Cmd- per app)
//   2 fingers, tap          right click     (only with two-finger tap)
//   3-4 fingers, swipe      left/right: switch Space, up: Mission Control, down: App Exposé
//   window edge, move       resize the window (a touch near an edge is moved onto it)
//
// Command line: MacTouch --help, and README.md. Adding a touch controller: CONTRIBUTING.md.
import AppKit
import IOKit.hid

// Startup: settings from the command line, then either a command-line action or the menu bar app.
setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }   // Finder may add -psn_... etc.
if args.contains("--help") { print(usage); exit(0) }
// Developer tools (see CONTRIBUTING.md), before any settings are read.
if args.contains("--self-test") { runSelfTest() }
if let (id, n) = captureTarget(Array(args)) {
    let secs = args.first { $0.hasPrefix("--seconds=") }.flatMap { Double($0.dropFirst("--seconds=".count)) } ?? 30
    runCapture(id, interface: n, seconds: secs)
}
var overrides: [String: Any] = [:]
for a in args where !actionFlags.contains(a) {
    let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts[0] != "--seconds", let o = options.first(where: { $0.flag == parts[0] }) else { fail("unknown option \(a); see MacTouch --help") }
    guard let v = parse(parts.count > 1 ? parts[1] : "", o.kind) else { fail("invalid value in \(a)") }
    overrides[o.key] = v
}
let checkOnly = args.contains("--check"), probe = args.contains("--probe"), logValues = args.contains("--raw")

if args.contains("--reset") { resetSettings() }
migrateLegacySettings()
if args.contains("--save") { saveOptions(overrides) }
defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
var cfg = loadConfig()

watchDisplayChanges()
configureMatching()
if checkOnly { printCheck() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
