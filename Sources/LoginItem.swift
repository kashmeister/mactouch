import AppKit
import ServiceManagement

// MARK: start at login

// A downloaded MacTouch.app starts itself at login through a launch agent inside its bundle
// (Contents/Library/LaunchAgents, written by build.sh), registered with SMAppService: launchd restarts
// it if it exits with an error, as MacTouch does to pick up Input Monitoring. install.sh and Homebrew
// run MacTouch from launch agents of their own instead. launchd names the job a process runs as in
// XPC_SERVICE_NAME; LaunchServices sets "0" or "application.…" for an app opened by hand.
let loginAgentLabel = "local.mactouch.agent"
let loginAgent = SMAppService.agent(plistName: loginAgentLabel + ".plist")
let launchJob: String? = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
    .flatMap { $0 == "0" || $0.hasPrefix("application.") ? nil : $0 }

/// What starts MacTouch at login when that is not its own login item, for the menu; nil if nothing.
var startedByOther: String? {
    guard let job = launchJob, job != loginAgentLabel else { return nil }
    return job == "local.mactouch" ? "install.sh" : job.contains("brew") ? "brew services" : job
}

func setStartAtLogin(_ on: Bool) {
    do {
        if on {
            // launchd starts the login item's copy right away, and that copy replaces this one.
            try loginAgent.register()
            log("start at login: on (\(loginAgent.status == .requiresApproval ? "waiting for approval" : "enabled"))")
            if loginAgent.status == .requiresApproval {
                notify("MacTouch", "Allow MacTouch under Login Items in System Settings to start it at login.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } else if launchJob == loginAgentLabel {
            // Unregistering stops this copy: open a plain one first, which waits for it and then takes
            // over the touch screens.
            let open = NSWorkspace.OpenConfiguration()
            open.createsNewApplicationInstance = true
            open.arguments = ["--takeover"]
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: open) { _, error in
                if let error { log("start at login: cannot reopen MacTouch: \(error.localizedDescription)") }
            }
            // Unregister as soon as the new copy's process is there (it finishes launching only after
            // this one has stopped); without one within 5 s, leave Start at Login on.
            func unregisterOnceReopened(_ tries: Int) {
                let reopened = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                    .contains { $0.processIdentifier != getpid() }
                guard reopened else {
                    if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { unregisterOnceReopened(tries - 1) } }
                    else { log("start at login: left on, as MacTouch could not be reopened") }
                    return
                }
                log("start at login: off")
                try? loginAgent.unregister()
            }
            unregisterOnceReopened(50)
        } else {
            try loginAgent.unregister()
            log("start at login: off")
        }
    } catch {
        log("start at login: \(error.localizedDescription)")
        notify("MacTouch", "Could not change Start at Login: \(error.localizedDescription)")
    }
}

/// Starts a fresh MacTouch process in place of this one. Under launchd that is an error exit, which
/// the launch agent's KeepAlive restarts; a copy opened by hand reopens itself.
func restartProcess() {
    guard launchJob == nil else { exit(75) }
    let open = NSWorkspace.OpenConfiguration()
    open.createsNewApplicationInstance = true
    open.arguments = ["--takeover"]
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: open) { _, error in
        if let error { log("cannot reopen MacTouch: \(error.localizedDescription)") }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}

/// One MacTouch at a time. A copy started by launchd (login item, install.sh, Homebrew) replaces any
/// other; one opened to take over from the login item waits for it to stop; one opened by hand while
/// another runs just quits.
func ensureSingleInstance() {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != getpid() }
    guard !others.isEmpty else { return }
    let takeover = args.contains("--takeover")
    guard launchJob != nil || takeover else { log("MacTouch is already running; quitting"); exit(0) }
    log("\(takeover ? "taking over from" : "replacing") the MacTouch already running (pid \(others.map { String($0.processIdentifier) }.joined(separator: ", ")))")
    if !takeover { others.forEach { $0.terminate() } }
    // Wait for it to let go of the touch screens it took.
    let deadline = Date().addingTimeInterval(takeover ? 10 : 3)
    while others.contains(where: { !$0.isTerminated }) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
}
