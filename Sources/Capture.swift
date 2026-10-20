import Foundation
import IOKit
import IOUSBHost

// MARK: --capture

// A tool for adding a controller (see CONTRIBUTING.md): `MacTouch --capture=VID:PID[:INTERFACE]`
// takes the USB device from macOS, prints its descriptors, prints every input report that differs
// from the one before (decoded too if the controller is in KnownDevices.swift), and at the end asks
// for the interface's HID report descriptor, saved to a file if the controller answers. Quit the
// MacTouch menu bar app first, or it may take the device itself.

/// The `--capture=` argument as (USB ID, interface), if given.
func captureTarget(_ args: [String]) -> (USBID, Int)? {
    guard let a = args.first(where: { $0.hasPrefix("--capture=") }) else { return nil }
    // IDs in hex, with or without 0x, as --check prints them; the interface number in decimal.
    let p = a.dropFirst("--capture=".count).split(separator: ":")
    func hexID(_ s: Substring) -> Int? { Int(s.hasPrefix("0x") ? s.dropFirst(2) : s, radix: 16) }
    guard p.count >= 2, let v = hexID(p[0]), let pid = hexID(p[1]), p.count < 3 || Int(p[2]) != nil else {
        fail("usage: --capture=VID:PID[:INTERFACE] in hex as --check prints them, e.g. --capture=eeef:2828:0")
    }
    return (USBID(v, pid), p.count > 2 ? Int(p[2])! : 0)
}

func runCapture(_ id: USBID, interface n: Int, seconds: Double) -> Never {
    func hexs<S: Sequence>(_ b: S) -> String where S.Element == UInt8 { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
    var it: io_iterator_t = 0, service: io_service_t = 0
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it)
    while case let s = IOIteratorNext(it), s != 0 { if usbID(s) == id && service == 0 { service = s } else { IOObjectRelease(s) } }
    guard service != 0 else { fail("no USB device \(id) connected") }

    // Take the device and configure it without drivers on its interfaces, so the interface is free.
    let dev: IOUSBHostDevice
    do { dev = try IOUSBHostDevice(__ioService: service, options: .deviceSeize, queue: nil, interestHandler: nil) }
    catch { fail("could not take \(id) from macOS: \(error.localizedDescription) (is the MacTouch app running?)") }
    guard let cfg = dev.configurationDescriptor else { fail("\(id) has no configuration") }
    let desc = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(cfg), count: Int(cfg.pointee.wTotalLength)))
    print("device \(id) \(usbString(service, "kUSBProductString")), configuration descriptor (\(desc.count) bytes):\n  \(hexs(desc))")
    var k = 0, current = -1, inEP: UInt8 = 0, packet = 64, reportLength = 0
    while k + 1 < desc.count, desc[k] > 0 {
        let len = Int(desc[k]), type = desc[k + 1]
        if type == 4, k + 7 < desc.count {
            current = Int(desc[k + 2])
            print("  interface \(current): class \(desc[k + 5]) subclass \(desc[k + 6]) protocol \(desc[k + 7]), \(desc[k + 4]) endpoint(s)")
        } else if type == 0x21, k + 8 < desc.count {
            if current == n { reportLength = Int(desc[k + 7]) | Int(desc[k + 8]) << 8 }
            print("    HID descriptor: report descriptor \(Int(desc[k + 7]) | Int(desc[k + 8]) << 8) bytes")
        } else if type == 5, k + 6 < desc.count {
            let addr = desc[k + 2], size = Int(desc[k + 4]) | Int(desc[k + 5]) << 8
            print(String(format: "    endpoint 0x%02x %@ %d bytes every %d ms", addr, desc[k + 3] & 3 == 3 ? "interrupt" : "other", size, desc[k + 6]))
            if current == n, addr & 0x80 != 0, desc[k + 3] & 3 == 3, inEP == 0 { inEP = addr; packet = size }
        }
        k += len
    }
    try? dev.__configure(withValue: 0, matchInterfaces: false)
    do { try dev.__configure(withValue: Int(cfg.pointee.bConfigurationValue), matchInterfaces: false) }
    catch { fail("could not configure \(id): \(error.localizedDescription)") }

    var ifService: io_service_t = 0
    for _ in 0..<20 where ifService == 0 {
        var child: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &child) == KERN_SUCCESS {
            while case let c = IOIteratorNext(child), c != 0 {
                if ifService == 0, IOObjectConformsTo(c, "IOUSBHostInterface") != 0, usbProp(c, "bInterfaceNumber") == n { ifService = c } else { IOObjectRelease(c) }
            }
            IOObjectRelease(child)
        }
        if ifService == 0 { Thread.sleep(forTimeInterval: 0.05) }
    }
    guard ifService != 0, inEP != 0 else { fail("interface \(n) of \(id) has no interrupt IN endpoint") }
    let iface: IOUSBHostInterface
    do { iface = try IOUSBHostInterface(__ioService: ifService, options: [], queue: .main, interestHandler: nil) }
    catch { fail("could not open interface \(n): \(error.localizedDescription)") }

    // The report descriptor, if the controller gives it: decode it with a HID descriptor parser. Asked
    // for only after the capture, since some controllers change mode once it has been read.
    func requestReportDescriptor() {
        guard reportLength > 0, let buf = try? iface.ioData(withCapacity: reportLength) else { return }
        var got = 0
        let req = IOUSBDeviceRequest(bmRequestType: 0x81, bRequest: 6, wValue: 0x2200, wIndex: UInt16(n), wLength: UInt16(reportLength))
        if (try? iface.__send(req, data: buf, bytesTransferred: &got, completionTimeout: 1)) != nil {
            let file = "report-descriptor-\(id.description.replacingOccurrences(of: ":", with: "-"))-if\(n).bin"
            try? (buf as Data).prefix(got).write(to: URL(fileURLWithPath: file))
            print("report descriptor (\(got) bytes), saved to \(file):\n  \(hexs((buf as Data).prefix(got)))")
        } else {
            print("report descriptor: the controller refused the request (common for interfaces macOS has no driver for)")
        }
    }

    let layout = rawInterfaces.first { $0.id == id && $0.interface == n }?.layout
    print("reading endpoint \(String(format: "0x%02x", inEP)) for \(Int(seconds)) s; touch the screen (one finger, then two, then the corners)")
    let start = now()
    var last: [UInt8] = [], repeats = 0
    guard let pipe = try? iface.copyPipe(withAddress: Int(inEP)) else { fail("could not open endpoint") }
    func read() {
        guard let buf = try? iface.ioData(withCapacity: packet) else { return }
        try? pipe.enqueueIORequest(with: buf, completionTimeout: 0) { status, got in
            guard status == kIOReturnSuccess else { return }
            let r = [UInt8]((buf as Data).prefix(got))
            if r == last { repeats += 1 } else {
                if repeats > 0 { print("        (same report \(repeats) more times)") }
                repeats = 0; last = r
                var line = String(format: "%7.3f  %2d bytes  ", now() - start, r.count) + hexs(r)
                if let contacts = layout?.contacts(in: r) {
                    line += "\n         contacts: " + (contacts.isEmpty ? "none" : contacts.sorted { $0.key < $1.key }
                        .map { String(format: "%d at %.3f,%.3f", $0.key, $0.value.x, $0.value.y) }.joined(separator: "  "))
                }
                print(line)
            }
            read()
        }
    }
    for _ in 0..<4 { read() }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        requestReportDescriptor()
        print("done; unplug and replug the device, or start MacTouch again (./install.sh), to hand it back")
        exit(0)
    }
    dispatchMain()
}
