import AppKit
import IOKit.hid

// MARK: touchscreens

// MacTouch reads three kinds of touchscreen, told apart when they attach:
//   multi-touch   a HID digitizer reporting each contact in its own Finger collection (0x0D/0x22) with
//                 Tip Switch (0x0D/0x42), X (0x01/0x30) and Y (0x01/0x31), e.g. the Wisecoco's ILITEK;
//                 or a driverless multi-touch interface read over USB (RawUSB.swift)
//   single touch  an absolute mouse: absolute X/Y plus button 1 (0x09/0x01), which macOS drives as a
//                 pointer on whichever display the cursor is on, e.g. the CX158 in mouse mode. MacTouch
//                 takes such a device from macOS while it drives it (see updateSeize).
// HID values arrive one by one; all values of a report are delivered in one run loop pass, so the
// gesture engine (commit) runs once per report.

/// What a device is to MacTouch.
enum TouchKind {
    case multiTouch, singleTouch, notTouch
    var label: String {
        switch self {
        case .multiTouch: "multi-touch"
        case .singleTouch: "single touch"
        case .notTouch: "not a touchscreen"
        }
    }
}

/// How a touchscreen's profile says to use it. Stored in the profile as the raw value.
enum ScreenMode: String {
    case auto      // as detected
    case multi     // a digitizer, used as such
    case single    // a digitizer, but only its first contact is used
    case ignore    // not a touchscreen: leave the device alone
}

final class TouchDevice {
    let id: USBID, serial: String, name: String, location: Int, kind: TouchKind
    let raw: RawDigitizer?
    var services: [IOHIDDevice]   // a controller can show up as several HID services
    var seized: IOHIDDevice?      // a single-touch screen MacTouch holds exclusively while driving it
    var seizeFailed = false
    var profile: String?
    var display: CGDirectDisplayID?   // its profile's display, while connected
    var slots: [Int: Slot] = [:]
    var lastReport = 0.0, touching = false

    init(_ d: IOHIDDevice) {
        func int(_ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ k: String) -> String { (IOHIDDeviceGetProperty(d, k as CFString) as? String ?? "").trimmingCharacters(in: .whitespaces) }
        id = USBID(int(kIOHIDVendorIDKey), int(kIOHIDProductIDKey))
        serial = str(kIOHIDSerialNumberKey); location = int(kIOHIDLocationIDKey)
        name = str(kIOHIDProductKey).isEmpty ? id.description : str(kIOHIDProductKey)
        kind = TouchDevice.classify(d, vendor: id.vid)
        services = [d]; raw = nil
    }

    init(raw r: RawDigitizer) {
        id = r.interface.id; kind = .multiTouch; services = []; raw = r
        serial = usbString(r.service, "kUSBSerialNumberString")
        let product = usbString(r.service, "kUSBProductString")
        name = product.isEmpty ? knownController(for: id)?.name ?? id.description : product
        location = usbProp(r.service, "locationID") ?? 0
    }

    static func classify(_ d: IOHIDDevice, vendor: Int) -> TouchKind {
        if vendor == 0x05AC { return .notTouch }   // Apple trackpads and mice
        let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        func collection(_ page: UInt32, _ usage: UInt32) -> Bool {
            els.contains { IOHIDElementGetType($0) == kIOHIDElementTypeCollection && IOHIDElementGetUsagePage($0) == page && IOHIDElementGetUsage($0) == usage }
        }
        func absolute(_ usage: UInt32) -> Bool {
            els.contains { IOHIDElementGetUsagePage($0) == 0x01 && IOHIDElementGetUsage($0) == usage && !IOHIDElementIsRelative($0) }
        }
        if collection(0x0D, 0x22) { return .multiTouch }                        // Finger
        if collection(0x0D, 0x20) || collection(0x0D, 0x02) { return .notTouch }   // Stylus, Pen
        let button = els.contains { IOHIDElementGetUsagePage($0) == 0x09 }
        return absolute(0x30) && absolute(0x31) && button ? .singleTouch : .notTouch
    }

    var label: String { "\(name) \(id)" }
    /// A single-touch screen whose controller also has a multi-touch mode MacTouch can read (the CX158).
    var couldBeMultiTouch: Bool { kind == .singleTouch && knownController(for: id)?.raw.map { $0.id != id } == true }
    var mode: ScreenMode { profile.map(profileMode) ?? .auto }

    /// What MacTouch uses it as.
    var role: TouchKind {
        if kind == .notTouch || mode == .ignore { return .notTouch }
        // A touchscreen's mouse-emulation interface beside its digitizer is left alone.
        let digitizerBeside = allDevices().contains {
            $0 !== self && $0.kind == .multiTouch && $0.id.vid == id.vid && $0.location == location && location != 0
        }
        return kind == .singleTouch && digitizerBeside ? .notTouch : kind
    }

    /// Whether MacTouch uses its input now. A digitizer always is (unpaired, it touches the main display);
    /// an absolute mouse only while paired with a connected display, or being paired.
    var driven: Bool {
        switch role {
        case .multiTouch: true
        case .singleTouch: pairing.device === self || (display != nil && profile != nil && !cfg.paused)
        case .notTouch: false
        }
    }
}

func usbString(_ s: io_service_t, _ key: String) -> String {
    (IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, nil,
                                     IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? String ?? "")
        .trimmingCharacters(in: .whitespaces)
}

// MARK: registry

/// Every device MacTouch has seen, by HID service (several can map to one device) or raw reader.
var devices: [ObjectIdentifier: TouchDevice] = [:]
var activeDevice: TouchDevice?   // the one whose touch drives the gestures

func allDevices() -> [TouchDevice] {
    var seen = Set<ObjectIdentifier>()
    return devices.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
}
func touchDevices() -> [TouchDevice] { allDevices().filter { $0.role != .notTouch }.sorted { $0.label < $1.label } }
func isConnected(_ t: TouchDevice) -> Bool { devices.values.contains { $0 === t } }

/// The profile that best matches a device: same vendor, then the same product (or any), then the same
/// serial (or any).
func findProfile(_ t: TouchDevice) -> String? {
    screens.compactMap { key, p -> (String, Int)? in
        guard p["vid"] as? Int == t.id.vid else { return nil }
        let pid = p["pid"] as? Int ?? 0, serial = p["serial"] as? String ?? ""
        guard pid == 0 || pid == t.id.pid, serial.isEmpty || t.serial.isEmpty || serial == t.serial else { return nil }
        return (key, (pid == t.id.pid ? 2 : 0) + (!serial.isEmpty && serial == t.serial ? 4 : 0))
    }.max { $0.1 < $1.1 }?.0
}

/// Gives a new touchscreen its profile: the one it matches, or a new one. A controller with several
/// modes (a known controller) gets one profile per mode, and a new one takes the display of the other.
func register(_ t: TouchDevice) {
    if let id = findProfile(t) {
        t.profile = id
        if profileName(id) == "Touch screen" && !checkOnly { setProfile(id, "name", t.name) }   // migrated from 3.0
    } else if checkOnly {
        return
    } else {
        t.profile = newProfile(for: t)
    }
    if t.kind == .multiTouch && !checkOnly { enableMultiTouchMode(t) }
    refreshDisplays()
    log("attached \(t.label): \(t.role == .notTouch ? "not used" : t.role.label), profile \(t.profile ?? "-")"
        + (t.display.map { " on \(displayName($0))" } ?? ""))
    if !checkOnly && t.role != .notTouch && (screens[t.profile!]?["display"] as? String ?? "").isEmpty { pairing.request(t) }
}

func newProfile(for t: TouchDevice) -> String {
    var key = t.id.description, n = 2
    while screens[key] != nil { key = "\(t.id)-\(n)"; n += 1 }
    let known = knownController(for: t.id)
    let sibling = known?.modes.first { $0 != t.id }
    let display = sibling.flatMap { s in screens.values.first { $0["vid"] as? Int == s.vid && $0["pid"] as? Int == s.pid }?["display"] } ?? ""
    let name = known == nil ? t.name : "\(t.name) (\(t.kind == .singleTouch ? "mouse mode" : "digitizer mode"))"
    setProfile(key, ["name": name, "mode": ScreenMode.auto.rawValue, "vid": t.id.vid, "pid": t.id.pid, "serial": t.serial,
                     "display": display, "oneFingerScroll": t.kind == .singleTouch])   // one finger is all it has to scroll with
    log("new touchscreen \(t.label): \(t.kind.label), profile \(key)")
    return key
}

/// Windows switches a digitizer to multi-touch when it attaches: Input Mode (0x0D/0x52) = 2, with
/// Surface Switch and Button Switch (0x0D/0x57, 0x58) on. Some controllers stay in mouse emulation
/// without that, so MacTouch does the same where those features exist.
func enableMultiTouchMode(_ t: TouchDevice) {
    guard let d = t.services.first else { return }
    let els = IOHIDDeviceCopyMatchingElements(d, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
    for e in els where IOHIDElementGetType(e) == kIOHIDElementTypeFeature && IOHIDElementGetUsagePage(e) == 0x0D {
        let value: CFIndex
        switch IOHIDElementGetUsage(e) {
        case 0x52: value = 2
        case 0x57, 0x58: value = 1
        default: continue
        }
        let r = IOHIDDeviceSetValue(d, e, IOHIDValueCreateWithIntegerValue(nil, e, mach_absolute_time(), value))
        log("\(t.label): set feature \(hex(IOHIDElementGetUsage(e))) = \(value)" + (r == kIOReturnSuccess ? "" : " failed (\(hex(UInt32(bitPattern: r))))"))
    }
}

/// Matches each device to its profile's display (if connected) and takes or releases single-touch
/// screens accordingly. Runs every 2 s and on display changes: a display can arrive after its
/// touchscreen, and the notice of it can be missed.
func refreshDisplays() {
    pruneDeadServices()
    for t in devices.values {
        let spec = t.profile.flatMap { screens[$0]?["display"] as? String } ?? ""
        t.display = spec == "main" ? CGMainDisplayID() : spec.isEmpty ? nil : display(for: spec)
    }
    if !pairing.active, let t = pairing.waiting.first(where: isConnected) { pairing.request(t) }
    updateSeizes()
}

/// Makes t the screen whose touches drive the gestures, with its profile's settings.
func activate(_ t: TouchDevice) {
    activeDevice = t
    guard activeProfile != t.profile else { return }
    activeProfile = t.profile
    cfg = loadConfig(); cachedDisplay = nil
    log("touch on \(t.label) (\(t.role.label)\(t.profile.map { ", profile \($0)" } ?? ""))")
    migrateCalibration(t)
}

/// A calibration from 3.1.0 or older is in display fractions; it is rewritten once into panel
/// fractions, in the rotation its display has now (the one it was most likely made in).
func migrateCalibration(_ t: TouchDevice) {
    guard let id = t.profile, let p = screens[id], p["calPanel"] as? Bool != true, let d = t.display else { return }
    for key in ["cal", "previousCal"] {
        if let c = validCal(p[key]) { setProfile(id, key, transform(on: d).calibrationToPanel(c)) }
    }
    setProfile(id, "calPanel", true)
    cfg = loadConfig()
    log("\(t.label): calibration rewritten for any rotation (made at \(Int(CGDisplayRotation(d)))°): \(cfg.cal)")
}

/// No gesture is in progress, so another screen may take over.
func engineIdle() -> Bool {
    if case .idle = mode, lastN == 0, !calibrator.active { return true }
    return false
}

/// One screen drives the gestures at a time: the one whose touch started while nothing was touched.
func deliver(_ t: TouchDevice) {
    if pairing.active && pairing.device !== t { return }
    if activeDevice !== t { guard engineIdle() else { return }; activate(t) }
    slots = t.slots
    if !dirty { dirty = true; DispatchQueue.main.async { commit() } }
}

func gone(_ t: TouchDevice) {
    pairing.waiting.removeAll { $0 === t }
    if pairing.device === t { pairing.close() }
    if activeDevice === t { endGesture(); slots.removeAll(); lastN = 0; activeDevice = nil }
    if t.kind != .notTouch { log("detached \(t.label)") }
    DispatchQueue.main.async { refreshStatusIcon() }
}

// MARK: HID devices

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
var hidOpen = false

/// Touchscreens, absolute and ordinary mice (sorted out on attach), and every profile's device.
func configureMatching() {
    var matching: [[String: Any]] = [[kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x04],   // touch screen
                                     [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02],   // mouse
                                     [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x01],   // pointer
                                     [kIOHIDVendorIDKey: cfg.vid]]
    for p in screens.values {   // a raw interface's vendor would only match its other (keyboard) interfaces
        if let v = p["vid"] as? Int, !rawInterfaces.contains(where: { $0.id.vid == v }) { matching.append([kIOHIDVendorIDKey: v]) }
    }
    IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)
}

func attached(_ d: IOHIDDevice) {
    pruneDeadServices()
    let t = TouchDevice(d)
    // A further HID service of a controller already known: its values count as the first one's.
    if t.kind != .notTouch, t.location != 0, let same = allDevices().first(where: {
        $0.raw == nil && $0.id == t.id && $0.location == t.location && $0.kind == t.kind && $0.serial == t.serial }) {
        devices[ObjectIdentifier(d)] = same
        same.services.append(d)
        return
    }
    devices[ObjectIdentifier(d)] = t
    if t.kind != .notTouch { register(t) }
}

func detached(_ d: IOHIDDevice) {
    guard let t = devices.removeValue(forKey: ObjectIdentifier(d)) else { return }
    t.services.removeAll { CFEqual($0, d) }
    guard t.services.isEmpty else { return }   // another of its services remains
    if let s = t.seized { release(t, s) }
    gone(t)
}

/// macOS does not always send a removal notice for every HID service of a controller that drops off
/// the bus or changes mode. Services that have left the registry are dropped here, so a replugged
/// screen starts afresh instead of carrying a dead service along.
func pruneDeadServices() {
    func alive(_ d: IOHIDDevice) -> Bool { IORegistryEntryInPlane(IOHIDDeviceGetService(d), kIOServicePlane) != 0 }
    for t in allDevices() where t.raw == nil {
        if let s = t.seized, !alive(s) { release(t, s) }
        let dead = t.services.filter { !alive($0) }
        guard !dead.isEmpty else { continue }
        for d in dead { devices[ObjectIdentifier(d)] = nil }
        t.services.removeAll { !alive($0) }
        if t.services.isEmpty {
            for (k, v) in devices where v === t { devices[k] = nil }
            gone(t)
        }
    }
}

let valueCB: IOHIDValueCallback = { _, _, _, value in
    let e = IOHIDValueGetElement(value)
    guard let t = devices[ObjectIdentifier(IOHIDElementGetDevice(e))], t.kind != .notTouch else { return }
    let page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e), v = IOHIDValueGetIntegerValue(value)
    let parent = IOHIDElementGetParent(e)
    if logValues {
        let p = parent.map { "\(hex(IOHIDElementGetUsagePage($0)))/\(hex(IOHIDElementGetUsage($0)))#\(IOHIDElementGetCookie($0))" } ?? "-"
        log("\(t.name) rid=\(IOHIDElementGetReportID(e)) page=\(hex(page)) usage=\(hex(usage)) v=\(v) parent=\(p)")
    }
    t.lastReport = now()
    guard t.driven else { return }
    let axis = Axis(v: Double(v), lo: Double(IOHIDElementGetLogicalMin(e)), hi: Double(IOHIDElementGetLogicalMax(e)))
    let key: Int
    switch t.kind {
    case .multiTouch:   // one slot per Finger collection
        guard let parent, IOHIDElementGetUsagePage(parent) == 0x0D, IOHIDElementGetUsage(parent) == 0x22 else { return }
        key = Int(IOHIDElementGetCookie(parent))
    case .singleTouch: key = 0
    case .notTouch: return
    }
    var s = t.slots[key] ?? Slot()
    switch (page, usage) {
    case (0x0D, 0x42) where t.kind == .multiTouch: s.tip = v != 0          // Tip Switch
    case (0x09, 0x01) where t.kind == .singleTouch: s.tip = v != 0; t.touching = s.tip   // button 1
    case (0x01, 0x30): s.x = axis
    case (0x01, 0x31): s.y = axis
    default: return
    }
    t.slots[key] = s
    deliver(t)
}

// MARK: single-touch screens

// macOS moves the cursor for an absolute mouse before any event tap sees the events, so while MacTouch
// drives a single-touch screen it takes the device from macOS: a separate reference opened with
// kIOHIDOptionsTypeSeizeDevice, whose values MacTouch reads instead. (Seizing through a reference the
// HID manager has already opened silently does nothing.) It is let go when MacTouch stops driving the
// screen (paused, not paired, display gone, or MacTouch quits), and macOS handles it again.
func updateSeize(_ t: TouchDevice) {
    let want = t.kind == .singleTouch && t.role == .singleTouch && t.driven && !probe && !checkOnly && isConnected(t)
    if want, t.seized == nil {
        let svc = t.services.map(IOHIDDeviceGetService).first { IOObjectConformsTo($0, "IOHIDDevice") != 0 }
        guard let svc, let d = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else { return }
        let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard r == kIOReturnSuccess else {   // retried with every display check; logged once
            if !t.seizeFailed { log("\(t.label): could not take it from macOS yet (\(hex(UInt32(bitPattern: r)))); filtering its events meanwhile") }
            t.seizeFailed = true
            return
        }
        t.seizeFailed = false
        IOHIDDeviceRegisterInputValueCallback(d, valueCB, nil)
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        devices[ObjectIdentifier(d)] = t
        t.seized = d
        log("\(t.label): taken from macOS while MacTouch drives it")
    } else if !want, let d = t.seized {
        release(t, d)
        log("\(t.label): handed back to macOS")
    }
}
func updateSeizes() { for t in allDevices() where t.kind == .singleTouch { updateSeize(t) } }

func release(_ t: TouchDevice, _ d: IOHIDDevice) {
    IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
    IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    devices[ObjectIdentifier(d)] = nil
    t.seized = nil
}

// The fallback when seizing fails: pointer events macOS makes from a single-touch screen MacTouch drives
// are dropped. That is a hardware event (no posting process), not from a trackpad, while the screen
// is touched or within 80 ms of its last report. MacTouch's own events carry its pid and pass. It
// stops the clicks, but not macOS moving the cursor.
// The tap also notices a mouse or trackpad moving the pointer, for the pointer return (Gestures.swift).
var eventTap: CFMachPort?
let tapCB: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.eventSourceUnixProcessID) == 0 else { return Unmanaged.passUnretained(event) }
    let t = now()
    let fromTouch = event.getIntegerValueField(.mouseEventSubtype) == 0 && devices.values.contains {
        $0.kind == .singleTouch && $0.seized == nil && ($0.touching || t - $0.lastReport < 0.08) && $0.driven
    }
    if fromTouch { return nil }
    if [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type),
       event.getIntegerValueField(.mouseEventDeltaX) != 0 || event.getIntegerValueField(.mouseEventDeltaY) != 0 { handMoved() }
    return Unmanaged.passUnretained(event)
}
func startEventTap() {
    guard eventTap == nil, AXIsProcessTrusted() else { return }
    let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
    let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
    guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: mask, callback: tapCB, userInfo: nil) else {
        log("event tap could not be created; single-touch screens stay with macOS"); return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    log("event tap active")
}
