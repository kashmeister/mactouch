import AppKit
import IOKit.hid

// MARK: --check

/// Prints what MacTouch sees, without driving anything, and exits.
func printCheck() -> Never {
    for d in (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? [] { attached(d) }
    func cal(_ v: Any?) -> String { validCal(v).map { $0.map { String(format: "%.4f", $0) }.joined(separator: ",") } ?? "none" }

    print("displays:")
    for d in onlineDisplays() {
        let b = CGDisplayBounds(d), users = touchDevices().filter { $0.display == d }.map(\.name)
        print("  \(d): \(spec(of: d)) rotation \(Int(CGDisplayRotation(d))) bounds \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))"
              + (CGDisplayIsBuiltin(d) != 0 ? " built-in" : "") + (users.isEmpty ? "" : " <- touch: " + users.joined(separator: ", ")))
    }
    print("touchscreens (HID):")
    for t in touchDevices() {
        print("  \(t.label): \(t.role.label), profile \(t.profile ?? "-"), display "
              + (t.display.map { "\(displayName($0)) (\($0))" } ?? "not paired or not connected"))
    }
    if touchDevices().isEmpty { print("  none") }
    // Known controllers, also those whose interfaces have no driver (not visible to the HID manager).
    var connectedIDs = Set<USBID>(), it: io_iterator_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it)
    while case let s = IOIteratorNext(it), s != 0 {
        if let id = usbID(s) {
            connectedIDs.insert(id)
            if let k = knownController(for: id) {
                let raw = k.raw.map { $0.id == id ? " (multi-touch interface \($0.interface), read directly while MacTouch runs)" : " (mouse mode)" } ?? ""
                print("known controller connected: \(k.name) \(id)\(raw)")
            }
        }
        IOObjectRelease(s)
    }
    IOObjectRelease(it)
    print("profiles:")
    for (id, p) in screens.sorted(by: { $0.key < $1.key }) {
        let usb = (p["vid"] as? Int).map { USBID($0, p["pid"] as? Int ?? 0) }
        let connected = touchDevices().contains { $0.profile == id } || usb.map { u in connectedIDs.contains { $0.vid == u.vid && (u.pid == 0 || $0.pid == u.pid) } } == true
        print("  \(id) \(p["name"] ?? "?"): mode \(profileMode(id).rawValue), display \(p["display"] as? String ?? "-"), cal \(cal(p["cal"]))"
              + (connected ? "" : " (not connected)"))
    }
    let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    print("Input Monitoring: \(im == kIOHIDAccessTypeGranted ? "granted" : im == kIOHIDAccessTypeDenied ? "denied" : "not decided")")
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
    print("(run from a terminal, permissions are the terminal's; the log is authoritative)")
    print("settings: \(cfg)")
    exit(0)
}
