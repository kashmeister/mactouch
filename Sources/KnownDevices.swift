import CoreGraphics

// MARK: known touch controllers

// Most touch screens need no entry here: a standard HID multi-touch digitizer or an absolute-position
// mouse is recognised from its HID descriptor (see Touchscreens.swift). This table is for controllers
// that need more, and is the place to add one; CONTRIBUTING.md explains how to work out an entry.

/// A USB vendor and product ID.
struct USBID: Hashable, CustomStringConvertible {
    let vid: Int, pid: Int
    init(_ vid: Int, _ pid: Int) { self.vid = vid; self.pid = pid }
    var description: String { String(format: "%04x:%04x", vid, pid) }
}

/// A controller that needs more than standard HID handling.
struct KnownController {
    let name: String
    /// The USB IDs it shows up under in its different modes. Profiles for them share a display.
    let modes: [USBID]
    /// A multi-touch interface macOS attaches no driver to, which MacTouch reads itself.
    let raw: RawInterface?
}

/// A driverless multi-touch interface and the layout of its touch reports.
struct RawInterface {
    let id: USBID
    let interface: Int
    let layout: ReportLayout
    /// Take the whole USB device from macOS as soon as it appears, and configure it without drivers
    /// for its interfaces: for controllers that change mode once macOS's HID driver reads them.
    var takeDevice = false
    /// Recorded reports with the contacts they hold, checked by `MacTouch --self-test`.
    var samples: [RawSample] = []
}

/// A recorded report: its first bytes as hex (the rest zeros), its length and contact count byte, and
/// the touching contacts it holds as raw coordinates by contact ID.
struct RawSample {
    let start: String, length: Int, count: UInt8
    let contacts: [Int: (x: Int, y: Int)]
    /// The whole report, with the count byte where the layout keeps it; nil if start and length disagree.
    func bytes(for l: ReportLayout) -> [UInt8]? {
        var b = start.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard length > 0, b.count <= length else { return nil }
        b += [UInt8](repeating: 0, count: length - b.count)
        let at = l.countOffset ?? length - 1
        guard at < length else { return nil }
        b[at] = count
        return b
    }
}

/// How a driverless digitizer lays out an input report, in the common Windows style: a report ID,
/// a run of fixed-size contact records, and a contact count. Offsets are bytes from the start of the
/// report, counting its report ID byte. A record starts with a status byte holding the tip bit and the
/// contact ID; X and Y are 16-bit little-endian.
struct ReportLayout {
    var reportID: UInt8
    var firstContact = 1
    var contactSize = 5
    var maxContacts = 10
    var tipMask: UInt8 = 0x01     // in the status byte: set while the finger touches
    var idShift = 1               // contact ID = status >> idShift; 8 or more: no ID, the record's index is used
    var xOffset = 1, yOffset = 3  // within a record
    var countOffset: Int? = nil   // where the contact count is; nil: the report's last byte
    var maxX: Double, maxY: Double

    /// The touching contacts in a report, by contact ID, as fractions of the panel (0...1), or nil if
    /// the report is not a touch report. A lifted finger is usually listed once more without its tip
    /// bit; it is left out, which ends that contact.
    func contacts(in r: [UInt8]) -> [Int: CGPoint]? {
        // A report too short for one contact (and a trailing count byte) is not a touch report.
        guard r.first == reportID, r.count >= firstContact + contactSize + (countOffset == nil ? 1 : 0) else { return nil }
        let countAt = countOffset ?? r.count - 1
        guard countAt > 0, countAt < r.count else { return nil }
        var out: [Int: CGPoint] = [:]
        for k in 0..<min(Int(r[countAt]), maxContacts) {
            let c = firstContact + k * contactSize, end = c + contactSize   // the record is r[c..<end]
            guard end <= r.count, countOffset != nil || end <= countAt else { break }   // not into the count byte
            let status = r[c]
            guard status & tipMask != 0 else { continue }
            func value(_ o: Int) -> Double { Double(Int(r[c + o]) | Int(r[c + o + 1]) << 8) }
            out[idShift < 8 ? Int(status >> idShift) : k] =
                CGPoint(x: min(max(value(xOffset) / maxX, 0), 1), y: min(max(value(yOffset) / maxY, 0), 1))
        }
        return out
    }
}

let knownControllers = [
    // CX158 portable monitor (also sold as the UPERFECT 14" OLED 3K). Its controller powers up in
    // digitizer mode, eeef:2828, whose multi-touch interface stalls the request for its HID report
    // descriptor, and switches for good to mouse mode, 0416:c169 (single touch), once macOS's HID
    // driver reads that interface. Reports: ID 1, ten 5-byte contacts (status, X 0...32767,
    // Y 0...20479), contact count in the last byte.
    KnownController(name: "CX158", modes: [USBID(0x0416, 0xC169), USBID(0xEEEF, 0x2828)],
                    raw: RawInterface(id: USBID(0xEEEF, 0x2828), interface: 0,
                                      layout: ReportLayout(reportID: 1, maxX: 32767, maxY: 20479), takeDevice: true, samples: [
                                          // one finger (contact 76), with a stale lifted record after it
                                          RawSample(start: "01 99 38 19 de 1d 96 6a 35 04 38", length: 56, count: 1, contacts: [76: (6456, 7646)]),
                                          // two fingers, contacts 89 and 90
                                          RawSample(start: "01 b3 c3 1d 54 28 b5 14 16 c2 31", length: 56, count: 2,
                                                    contacts: [89: (7619, 10324), 90: (5652, 12738)]),
                                          // contact 76 lifting: listed once more without its tip bit
                                          RawSample(start: "01 98 4f 4f 2f 14 96 6a 35 04 38", length: 56, count: 1, contacts: [:]),
                                          // nothing touching
                                          RawSample(start: "01 98 4f 4f 2f 14 96 6a 35 04 38", length: 56, count: 0, contacts: [:]),
                                      ])),
]

func knownController(for id: USBID) -> KnownController? { knownControllers.first { $0.modes.contains(id) } }
let rawInterfaces = knownControllers.compactMap(\.raw)
