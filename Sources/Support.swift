import Foundation

// MARK: helpers

let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
func log(_ s: String) { print(stamp.string(from: Date()) + " " + s) }
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
func hex(_ v: UInt32) -> String { "0x" + String(v, radix: 16) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
let logPath = NSHomeDirectory() + "/Library/Logs/MacTouch.log"
let repoURL = "https://github.com/kashmeister/mactouch"

/// A notification banner, through AppleScript (MacTouch has no notification entitlement).
func notify(_ title: String, _ body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run", title, body]
    try? p.run()
}
