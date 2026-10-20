import Foundation
import IOKit
import IOUSBHost

// MARK: raw USB digitizers

// Some touch controllers have a multi-touch interface that macOS attaches no driver to, typically
// because the interface refuses the request for its HID report descriptor. MacTouch opens such an
// interface itself with IOUSBHost (an interface nobody has claimed needs no driver or entitlement)
// and decodes its reports with the layout from KnownDevices.swift.
//
// Some of these controllers also change mode once macOS's HID driver reads the interface (the CX158
// falls back to mouse mode). For those (takeDevice) MacTouch takes the whole USB device from macOS
// as soon as it appears, sets its configuration again without matching drivers to its interfaces,
// and opens the interface under the device. macOS's composite driver refuses while it is still
// starting, and its HID driver can read the descriptor as early as 10 ms in, so the takeover is
// retried every 2 ms on its own queue: opening a device blocks while its owner is asked to let go.

let ioServiceTerminated: UInt32 = 0xE000_0010   // kIOMessageServiceIsTerminated

func usbProp(_ s: io_service_t, _ key: String) -> Int? {
    (IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, nil,
                                     IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? NSNumber)?.intValue
}
func usbID(_ s: io_service_t) -> USBID? {
    guard let v = usbProp(s, "idVendor"), let p = usbProp(s, "idProduct") else { return nil }
    return USBID(v, p)
}
func entryID(_ s: io_service_t) -> UInt64 { var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(s, &id); return id }

/// The known raw interface a service is, if any.
func rawInterface(for s: io_service_t) -> RawInterface? {
    guard let id = usbID(s), let n = usbProp(s, "bInterfaceNumber") else { return nil }
    return rawInterfaces.first { $0.id == id && $0.interface == n }
}

var rawDigitizers: [RawDigitizer] = []

/// Reads one driverless multi-touch interface and feeds its contacts to the gesture engine.
final class RawDigitizer {
    let service: io_service_t, interface: RawInterface, entry: UInt64
    private var iface: IOUSBHostInterface?, pipe: IOUSBHostPipe?, packet = 64, failures = 0
    private(set) var closed = false
    private var device: TouchDevice?
    var label: String { "\(knownController(for: interface.id)?.name ?? "raw digitizer") \(interface.id)" }

    init(_ s: io_service_t, _ i: RawInterface) { service = s; interface = i; entry = entryID(s) }

    /// Opens the interface, taking it from a driver if one has it (which macOS's HID driver may refuse),
    /// retried for 10 s.
    func open(attempt: Int = 0) {
        guard !closed else { return }
        guard IORegistryEntryInPlane(service, kIOServicePlane) != 0 else { finish(); return }   // replaced meanwhile
        do {
            let handler: IOUSBHostInterestHandler = { [weak self] _, type, _ in
                if type == ioServiceTerminated { DispatchQueue.main.async { self?.close("disconnected") } }
            }
            let i: IOUSBHostInterface
            do { i = try IOUSBHostInterface(__ioService: service, options: .deviceSeize, queue: .main, interestHandler: handler) }
            catch { i = try IOUSBHostInterface(__ioService: service, options: [], queue: .main, interestHandler: handler) }
            guard let ep = inEndpoint(i), let p = try? i.copyPipe(withAddress: Int(ep)) else {
                i.destroy(); log("\(label): no interrupt IN endpoint on interface \(interface.interface)"); finish(); return
            }
            iface = i; pipe = p
            let t = TouchDevice(raw: self)
            device = t
            devices[ObjectIdentifier(self)] = t
            log("\(label): reading its multi-touch interface directly (macOS has no driver for it)")
            register(t)
            for _ in 0..<4 { read() }   // keep reads queued, so no report waits for the next request
            refreshStatusIcon()
        } catch {
            if attempt < 10 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.open(attempt: attempt + 1) } }
            else { log("\(label): could not open its interface (\(error.localizedDescription)); a HID driver may have it"); finish() }
        }
    }

    /// The interface's interrupt IN endpoint, from the configuration descriptor (which lists each
    /// interface's endpoints after its interface descriptor).
    private func inEndpoint(_ i: IOUSBHostInterface) -> UInt8? {
        let cfg = i.configurationDescriptor
        let d = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(cfg), count: Int(cfg.pointee.wTotalLength)))
        var k = 0, current = -1
        while k + 5 < d.count, d[k] > 0 {
            if d[k + 1] == 4 { current = Int(d[k + 2]) }   // interface descriptor
            if d[k + 1] == 5, current == interface.interface, d[k + 2] & 0x80 != 0, d[k + 3] & 3 == 3 {   // interrupt IN endpoint
                packet = Int(d[k + 4]) | Int(d[k + 5]) << 8
                return d[k + 2]
            }
            k += Int(d[k])
        }
        return nil
    }

    private func read() {
        guard !closed, let i = iface, let p = pipe, let buf = try? i.ioData(withCapacity: packet) else { return }
        do {
            try p.enqueueIORequest(with: buf, completionTimeout: 0) { [weak self] status, n in
                guard let self, !self.closed else { return }
                if status == kIOReturnSuccess {
                    self.failures = 0
                    self.report([UInt8]((buf as Data).prefix(n)))
                    self.read()
                } else if status != kIOReturnAborted {
                    self.failures += 1
                    if self.failures > 40 { self.close("reads keep failing (\(hex(UInt32(bitPattern: status))))"); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.read() }
                }
            }
        } catch { failures += 1; if failures > 40 { close("reads cannot be queued") } }
    }

    private func report(_ r: [UInt8]) {
        if logValues { log("\(label) report " + r.map { String(format: "%02x", $0) }.joined(separator: " ")) }
        guard let t = device, let contacts = interface.layout.contacts(in: r) else { return }
        t.slots = contacts.mapValues { Slot(tip: true, x: Axis(v: $0.x), y: Axis(v: $0.y)) }
        t.lastReport = now(); t.touching = !contacts.isEmpty
        if t.driven { deliver(t) }
    }

    func close(_ why: String) {
        guard !closed else { return }
        log("\(label): stopped reading (\(why))")
        if let t = device { devices[ObjectIdentifier(self)] = nil; gone(t) }
        iface?.destroy(); iface = nil; pipe = nil
        finish()
    }
    private func finish() { closed = true; IOObjectRelease(service); rawDigitizers.removeAll { $0 === self } }
}

/// Starts reading an interface unless it is already being read. Takes over the reference to s.
func readRawInterface(_ s: io_service_t, _ i: RawInterface) {
    let id = entryID(s)
    guard !rawDigitizers.contains(where: { $0.entry == id && !$0.closed }) else { IOObjectRelease(s); return }
    let r = RawDigitizer(s, i)
    rawDigitizers.append(r)
    r.open()
}

// MARK: taking a USB device from macOS

let rawQueue = DispatchQueue(label: "local.mactouch.rawusb")
var takenDevices: [IOUSBHostDevice] = []

/// Takes the USB device s for interface i, retrying every 2 ms for 0.6 s; on rawQueue. Takes over
/// the reference to s.
func takeDevice(_ s: io_service_t, for i: RawInterface, attempt: Int = 0) {
    let label = "\(knownController(for: i.id)?.name ?? "raw digitizer") \(i.id)"
    guard IORegistryEntryInPlane(s, kIOServicePlane) != 0 else { IOObjectRelease(s); return }   // gone already
    var dev: IOUSBHostDevice?
    do {
        dev = try IOUSBHostDevice(__ioService: s, options: .deviceSeize, queue: rawQueue) { _, type, _ in
            guard type == ioServiceTerminated else { return }
            DispatchQueue.main.async { takenDevices.removeAll { $0 === dev }; dev?.destroy(); dev = nil }
        }
        guard let d = dev else { IOObjectRelease(s); return }
        // macOS's composite driver may already have configured the device and let go, leaving its HID
        // driver on the interfaces: unconfiguring removes them, and the new ones get no driver.
        let value = Int(d.configurationDescriptor?.pointee.bConfigurationValue ?? 1)
        try? d.__configure(withValue: 0, matchInterfaces: false)
        try d.__configure(withValue: value, matchInterfaces: false)
        DispatchQueue.main.async {
            takenDevices.append(d)
            log("\(label): took its USB device from macOS after \(attempt * 2) ms, so macOS's HID driver leaves the digitizer alone")
            openInterface(under: s, i)
        }
    } catch {
        let tookIt = dev != nil
        dev?.destroy()
        if tookIt {   // taken, but it would not configure: do not keep reconfiguring the device
            DispatchQueue.main.async { log("\(label): took its USB device but could not configure it (\(error.localizedDescription)); trying the interface instead") }
            IOObjectRelease(s)
        } else if attempt < 300 {
            rawQueue.asyncAfter(deadline: .now() + 0.002) { takeDevice(s, for: i, attempt: attempt + 1) }
        } else {
            DispatchQueue.main.async { log("\(label): macOS would not give up its USB device (\(error.localizedDescription)); trying the interface instead") }
            IOObjectRelease(s)
        }
    }
}

/// Interfaces configured without driver matching are not announced, so the interface is looked up
/// under the device, for up to a second. Takes over the reference to the device.
func openInterface(under device: io_service_t, _ i: RawInterface, attempt: Int = 0) {
    var it: io_iterator_t = 0, found = false
    if IORegistryEntryGetChildIterator(device, kIOServicePlane, &it) == KERN_SUCCESS {
        while case let c = IOIteratorNext(it), c != 0 {
            if !found, IOObjectConformsTo(c, "IOUSBHostInterface") != 0, usbProp(c, "bInterfaceNumber") == i.interface {
                found = true
                readRawInterface(c, i)
            } else {
                IOObjectRelease(c)
            }
        }
        IOObjectRelease(it)
    }
    if found || attempt >= 20 {
        if !found { log("\(i.id): interface \(i.interface) did not appear after configuring") }
        IOObjectRelease(device)
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { openInterface(under: device, i, attempt: attempt + 1) }
    }
}

// MARK: watching for them

private var interfaceIterator: io_iterator_t = 0, deviceIterator: io_iterator_t = 0

func watchRawDigitizers() {
    guard !rawInterfaces.isEmpty else { return }
    // Interfaces, on the main thread: publish comes before drivers are matched.
    let port = IONotificationPortCreate(kIOMainPortDefault)
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
    let interfacesArrived: IOServiceMatchingCallback = { _, it in
        while case let s = IOIteratorNext(it), s != 0 {
            guard let i = rawInterface(for: s) else { IOObjectRelease(s); continue }
            log("\(i.id): multi-touch interface \(i.interface) appeared")
            readRawInterface(s, i)
        }
    }
    if IOServiceAddMatchingNotification(port, kIOPublishNotification, IOServiceMatching("IOUSBHostInterface"),
                                        interfacesArrived, nil, &interfaceIterator) == KERN_SUCCESS { interfacesArrived(nil, interfaceIterator) }

    // Devices to take, on rawQueue, so the takeover starts within a millisecond of the device appearing.
    // One already connected at launch is taken too: when MacTouch quits, such a device is left in its
    // mode but without a configuration.
    guard rawInterfaces.contains(where: \.takeDevice) else { return }
    let devicePort = IONotificationPortCreate(kIOMainPortDefault)
    IONotificationPortSetDispatchQueue(devicePort, rawQueue)
    let devicesArrived: IOServiceMatchingCallback = { _, it in
        while case let s = IOIteratorNext(it), s != 0 {
            guard let id = usbID(s), let i = rawInterfaces.first(where: { $0.id == id && $0.takeDevice }) else { IOObjectRelease(s); continue }
            takeDevice(s, for: i)
        }
    }
    rawQueue.sync {
        if IOServiceAddMatchingNotification(devicePort, kIOPublishNotification, IOServiceMatching("IOUSBHostDevice"),
                                            devicesArrived, nil, &deviceIterator) == KERN_SUCCESS { devicesArrived(nil, deviceIterator) }
    }
}
