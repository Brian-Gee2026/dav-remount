// dav-remount — keep a WebDAV share mounted in Finder across sleep/wake,
// login, and VPN up/down.
//
// Why this exists: Apple's webdavfs has no reconnect (a mount that was alive
// before sleep is dead after it), and File-Provider "virtual drive" clients
// serve a stale cache. This agent does the one thing both get wrong: it
// notices the volume is gone or dead and mounts it again, quietly, after
// checking that the server is actually reachable (LAN or VPN).
//
// Nothing secret lives in this file or in the config. The credential is a
// personal access token stored in the login Keychain by `set-token`.
//
// Subcommands:
//   run            long-running agent (what the LaunchAgent starts)
//   once           mount now if needed, exit 0 when the volume is healthy
//   status         print config, reachability, token presence, mount state
//   set-token      store the access token in the Keychain (prompts, no echo) and mount
//   prompt-token   same, through a native macOS dialog (what the agent shows on a revoke)
//   forget-token   remove it
//   has-token      exit 0/1 (for scripts)
//   unmount [--pause MIN]   eject, optionally pause the agent for MIN minutes
//   --version / --help

import Foundation
import NetFS
import Security
import Network
import IOKit
import IOKit.pwr_mgt

let VERSION = "0.3.1"

// MARK: - Config -------------------------------------------------------------

struct Config {
    var url: URL
    var user: String
    var reachHost: String
    var reachPort: Int
    var reachTimeout: TimeInterval = 3
    var expectIPPrefix: String? = nil
    var retryWindow: TimeInterval = 120
    var pollInterval: TimeInterval = 300
    var unmountOnSleep = true
    var probeTimeout: TimeInterval = 8
    var logPath: String = NSHomeDirectory() + "/Library/Logs/dav-remount.log"
    /// Finder shows the volume under the mount directory's name, so a custom
    /// name means a custom mount point (default ~/Volumes/<name>; ~/Library is refused by macOS).
    var volumeName: String? = nil
    var mountDir: String? = nil
    /// On a credential rejection the agent asks for a new token in a macOS
    /// dialog (hidden input) — once per outage; "Later" leaves the CLI path.
    var promptOnAuthFailure = true

    static var dir: String { NSHomeDirectory() + "/.config/dav-remount" }
    /// DAV_REMOUNT_CONFIG overrides the path (tests, second shares).
    static var path: String { ProcessInfo.processInfo.environment["DAV_REMOUNT_CONFIG"] ?? dir + "/config" }
    static var pausePath: String { dir + "/paused-until" }

    var host: String { url.host ?? "" }
    var sharePath: String { url.path.isEmpty ? "/" : url.path }

    static func expand(_ s: String) -> String {
        s.hasPrefix("~/") ? NSHomeDirectory() + s.dropFirst(1) : s
    }

    static func load(from path: String = Config.path) throws -> Config {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CLIError("no config at \(path) — copy config.example there and edit it (install.sh does this)")
        }
        var kv: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            var v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            kv[k] = v
        }
        guard let u = kv["url"], let url = URL(string: u), let host = url.host,
              url.scheme == "https" || url.scheme == "http" else {
            throw CLIError("config: `url` must be an http(s) URL, e.g. https://dav.example.com/share")
        }
        guard let user = kv["user"], !user.isEmpty else {
            throw CLIError("config: `user` is required (the username the server expects)")
        }
        var c = Config(url: url, user: user, reachHost: kv["reach_host"] ?? host,
                       reachPort: Int(kv["reach_port"] ?? "") ?? (url.port ?? (url.scheme == "https" ? 443 : 80)))
        if let v = kv["reach_timeout"], let d = TimeInterval(v) { c.reachTimeout = d }
        if let v = kv["expect_ip_prefix"], !v.isEmpty { c.expectIPPrefix = v }
        if let v = kv["retry_window"], let d = TimeInterval(v) { c.retryWindow = d }
        if let v = kv["poll_interval"], let d = TimeInterval(v) { c.pollInterval = max(30, d) }
        if let v = kv["unmount_on_sleep"] { c.unmountOnSleep = !["0", "false", "no"].contains(v.lowercased()) }
        if let v = kv["probe_timeout"], let d = TimeInterval(v) { c.probeTimeout = d }
        if let v = kv["log"], !v.isEmpty { c.logPath = expand(v) }
        if let v = kv["volume_name"], !v.isEmpty {
            guard !v.contains("/") else { throw CLIError("config: `volume_name` may not contain /") }
            c.volumeName = v
        }
        if let v = kv["mount_dir"], !v.isEmpty { c.mountDir = expand(v) }
        if let v = kv["prompt_on_auth_failure"] { c.promptOnAuthFailure = !["0", "false", "no"].contains(v.lowercased()) }
        if c.mountDir == nil, let n = c.volumeName { c.mountDir = NSHomeDirectory() + "/Volumes/" + n }
        if let d = c.mountDir, d == "/" || d == NSHomeDirectory() { throw CLIError("config: `mount_dir` must be a dedicated empty directory") }
        return c
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Logging ------------------------------------------------------------

final class Log {
    static var path = NSHomeDirectory() + "/Library/Logs/dav-remount.log"
    static var echo = true           // also to stderr
    private static let q = DispatchQueue(label: "dav-remount.log")
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f
    }()
    private static var lastKey = ""

    static func line(_ tag: String, _ msg: String) {
        let s = "\(fmt.string(from: Date())) [\(tag)] \(msg)\n"
        q.sync {
            if echo { FileHandle.standardError.write(s.data(using: .utf8)!) }
            rotateIfNeeded()
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); h.closeFile()
            } else {
                try? s.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Log only when the state key changes — keeps "still unreachable" from
    /// filling the file every 30 s.
    static func state(_ key: String, _ tag: String, _ msg: String) {
        var changed = false
        q.sync { if lastKey != key { lastKey = key; changed = true } }
        if changed { line(tag, msg) }
    }

    private static func rotateIfNeeded() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let size = a[.size] as? Int, size > 2_000_000 else { return }
        try? FileManager.default.removeItem(atPath: path + ".1")
        try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
    }
}

// MARK: - Reachability (is the server there? LAN or VPN) ----------------------

enum Reach {
    case ok(ip: String)
    case dnsFailed(String)
    case unexpectedIP(String)
    case tcpFailed(ip: String, err: String)

    var isOK: Bool { if case .ok = self { return true } else { return false } }
    var text: String {
        switch self {
        case .ok(let ip): return "reachable (\(ip))"
        case .dnsFailed(let e): return "unreachable: DNS failed (\(e)) — not on LAN/VPN, or internal DNS not in use"
        case .unexpectedIP(let ip): return "unreachable: \(ip) is not an internal address — VPN down or split-horizon DNS not active"
        case .tcpFailed(let ip, let e): return "unreachable: tcp connect to \(ip) failed (\(e)) — VPN/LAN down?"
        }
    }
}

func resolve(_ host: String, port: Int) -> Result<[(ip: String, addr: sockaddr_storage, len: socklen_t)], CLIError> {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    hints.ai_family = AF_UNSPEC
    var res: UnsafeMutablePointer<addrinfo>? = nil
    let rc = getaddrinfo(host, String(port), &hints, &res)
    guard rc == 0, let first = res else { return .failure(CLIError(String(cString: gai_strerror(rc)))) }
    defer { freeaddrinfo(first) }
    var out: [(ip: String, addr: sockaddr_storage, len: socklen_t)] = []
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let ai = p {
        if let sa = ai.pointee.ai_addr {
            var ss = sockaddr_storage()
            memcpy(&ss, sa, Int(ai.pointee.ai_addrlen))
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            out.append((String(cString: buf), ss, ai.pointee.ai_addrlen))
        }
        p = ai.pointee.ai_next
    }
    return out.isEmpty ? .failure(CLIError("no addresses")) : .success(out)
}

/// Non-blocking TCP connect with timeout. Returns 0 on success, else errno.
func tcpConnect(_ addr: sockaddr_storage, len: socklen_t, timeout: TimeInterval) -> Int32 {
    var a = addr
    let fd = socket(Int32(a.ss_family), SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    let fl = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
    let rc = withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    if rc == 0 { return 0 }
    if errno != EINPROGRESS { return errno }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let pr = poll(&pfd, 1, Int32(timeout * 1000))
    if pr == 0 { return ETIMEDOUT }
    if pr < 0 { return errno }
    var err: Int32 = 0
    var elen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen)
    return err
}

func checkReach(_ cfg: Config) -> Reach {
    switch resolve(cfg.reachHost, port: cfg.reachPort) {
    case .failure(let e): return .dnsFailed(e.description)
    case .success(let addrs):
        let a = addrs[0]
        if let pfx = cfg.expectIPPrefix, !a.ip.hasPrefix(pfx) { return .unexpectedIP(a.ip) }
        let rc = tcpConnect(a.addr, len: a.len, timeout: cfg.reachTimeout)
        return rc == 0 ? .ok(ip: a.ip) : .tcpFailed(ip: a.ip, err: String(cString: strerror(rc)))
    }
}

// MARK: - Mount table ----------------------------------------------------------

struct MountInfo { let path: String; let from: String; let fstype: String }

func cString<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
    }
}

func currentMounts() -> [MountInfo] {
    var buf: UnsafeMutablePointer<statfs>? = nil
    let n = getmntinfo(&buf, MNT_NOWAIT)
    guard n > 0, let b = buf else { return [] }
    return (0..<Int(n)).map { i in
        var s = b[i]
        return MountInfo(path: cString(&s.f_mntonname), from: cString(&s.f_mntfromname), fstype: cString(&s.f_fstypename))
    }
}

func normalizeShare(_ s: String) -> String {
    var t = s.lowercased()
    for p in ["https://", "http://", "webdav://", "webdavs://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
    while t.hasSuffix("/") { t.removeLast() }
    return t
}

func findMount(_ cfg: Config) -> MountInfo? {
    let want = normalizeShare(cfg.host + cfg.sharePath)
    return currentMounts().first { m in
        m.fstype == "webdav" && normalizeShare(m.from).hasSuffix(want)
    }
}

/// Lists the volume root in a side thread. nil = hung past the timeout
/// (the dead-after-sleep case), false = error, true = alive.
func probe(_ path: String, timeout: TimeInterval) -> Bool? {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox()
    let t = Thread {
        box.value = (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        sem.signal()
    }
    t.start()
    return sem.wait(timeout: .now() + timeout) == .success ? box.value : nil
}
final class ResultBox { var value = false }

@discardableResult
func run(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func unmountVolume(_ path: String, force: Bool) -> Bool {
    if unmount(path, force ? MNT_FORCE : 0) == 0 { return true }
    let args = force ? ["unmount", "force", path] : ["unmount", path]
    return run("/usr/sbin/diskutil", args) == 0
}

// MARK: - Keychain -------------------------------------------------------------

enum Keychain {
    static let domain = "dav-remount"   // distinguishes our item from Finder's

    static func base(_ cfg: Config) -> [CFString: Any] {
        [kSecClass: kSecClassInternetPassword,
         kSecAttrServer: cfg.host,
         kSecAttrAccount: cfg.user,
         kSecAttrProtocol: cfg.url.scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
         kSecAttrSecurityDomain: domain]
    }

    static func exists(_ cfg: Config) -> Bool {
        var q = base(cfg)
        q[kSecReturnAttributes] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
    }

    static func read(_ cfg: Config) -> String? {
        var q = base(cfg)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func set(_ cfg: Config, token: String) -> OSStatus {
        let data = token.data(using: .utf8)!
        var q = base(cfg)
        q[kSecValueData] = data
        q[kSecAttrLabel] = "dav-remount (\(cfg.host))"
        q[kSecAttrDescription] = "WebDAV personal access token"
        let st = SecItemAdd(q as CFDictionary, nil)
        if st == errSecDuplicateItem {
            return SecItemUpdate(base(cfg) as CFDictionary, [kSecValueData: data] as CFDictionary)
        }
        return st
    }

    static func forget(_ cfg: Config) -> OSStatus { SecItemDelete(base(cfg) as CFDictionary) }
}

// MARK: - Mount ------------------------------------------------------------------

enum MountOutcome { case mounted(String), authFailed(Int32), failed(Int32) }

func mountShare(_ cfg: Config, token: String) -> MountOutcome {
    let open = NSMutableDictionary()
    open[kNAUIOptionKey] = kNAUIOptionNoUI          // never pop a dialog
    let mopts = NSMutableDictionary()
    mopts[kNetFSSoftMountKey] = true                 // fail fast instead of hanging
    var mountpath: CFURL? = nil
    if let dir = cfg.mountDir {
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            Log.line("mount", "cannot create mount dir \(dir): \(error.localizedDescription)")
            return .failed(EIO)
        }
        if let n = try? FileManager.default.contentsOfDirectory(atPath: dir), !n.filter({ $0 != ".DS_Store" }).isEmpty {
            Log.line("mount", "mount dir \(dir) is not empty — refusing to mount over local files")
            return .failed(ENOTEMPTY)
        }
        mountpath = URL(fileURLWithPath: dir) as CFURL
        mopts[kNetFSMountAtMountDirKey] = true       // mount AT the dir, not in a subdir of it
    }
    var mountpoints: Unmanaged<CFArray>? = nil
    let rc = NetFSMountURLSync(cfg.url as CFURL, mountpath, cfg.user as CFString, token as CFString,
                               open, mopts, &mountpoints)
    if rc == 0 || rc == EEXIST {
        let arr = mountpoints?.takeRetainedValue() as? [String]
        return .mounted(arr?.first ?? findMount(cfg)?.path ?? "?")
    }
    if rc == EACCES || rc == EAUTH { return .authFailed(rc) }
    if rc == EPERM {
        Log.line("mount", "mount refused (EPERM) — macOS will not mount at \(cfg.mountDir ?? "?"); use a mount_dir under your home such as ~/Volumes/<name>")
    }
    return .failed(rc)
}

// MARK: - Token dialog (native, hidden input) --------------------------------------

/// Asks for a new access token in a macOS dialog. Returns nil on Later/timeout.
/// The token travels only through osascript's stdout into this process; it is
/// never logged.
func promptForToken(_ cfg: Config, reason: String) -> String? {
    let msg = "\(reason)\n\nMint a new access token on your identity server, then paste it here. It is stored in your login Keychain and the share is mounted right away."
    // Values go in as argv, never into the script source (no AppleScript injection
    // from a hostile config file).
    let script = """
    on run argv
        tell application "System Events"
            activate
            set r to display dialog (item 1 of argv) default answer "" with hidden answer buttons {"Later", "Save"} default button "Save" with title (item 2 of argv) with icon caution giving up after 900
            if gave up of r then return ""
            if button returned of r is "Save" then return text returned of r
            return ""
        end tell
    end run
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script, msg, "\(cfg.host) — access token"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return t.isEmpty ? nil : t
}

// MARK: - Pause marker -------------------------------------------------------------

enum Pause {
    static func until() -> Date? {
        guard let s = try? String(contentsOfFile: Config.pausePath, encoding: .utf8),
              let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let d = Date(timeIntervalSince1970: t)
        if d < Date() { try? FileManager.default.removeItem(atPath: Config.pausePath); return nil }
        return d
    }
    static func set(minutes: Int) {
        let d = Date().addingTimeInterval(TimeInterval(minutes * 60))
        try? String(Int(d.timeIntervalSince1970)).write(toFile: Config.pausePath, atomically: true, encoding: .utf8)
    }
    static func clear() { try? FileManager.default.removeItem(atPath: Config.pausePath) }
}

// MARK: - Agent --------------------------------------------------------------------

final class Agent {
    let cfg: Config
    let q = DispatchQueue(label: "dav-remount.agent")
    private var timer: DispatchSourceTimer?
    private var rerun = false
    private var running = false
    /// true in `run`/`prompt-token`: a credential rejection may open the dialog
    var interactive = false
    private var promptDeclined = false

    init(_ cfg: Config, interactive: Bool = false) { self.cfg = cfg; self.interactive = interactive }

    /// Coalesce: if an ensure is in flight, run once more when it finishes.
    func schedule(_ reason: String, delay: TimeInterval = 0) {
        q.asyncAfter(deadline: .now() + delay) {
            if self.running { self.rerun = true; return }
            self.running = true
            self.ensure(reason)
            self.running = false
            if self.rerun { self.rerun = false; self.schedule("coalesced") }
        }
    }

    /// One pass: healthy mount → done; stale → force-unmount; unreachable →
    /// wait; else mount with retries inside the window. Returns true when the
    /// volume is mounted and alive at the end.
    @discardableResult
    func ensure(_ reason: String, retry: Bool = true) -> Bool {
        if let p = Pause.until() {
            Log.state("paused", reason, "paused until \(p) — skipping")
            armTimer(30)
            return false
        }
        if let m = findMount(cfg), let want = cfg.mountDir, m.path != want {
            Log.line(reason, "mounted at \(m.path) but config wants \(want) — moving")
            if !(unmountVolume(m.path, force: false) || unmountVolume(m.path, force: true)) {
                Log.line(reason, "could not unmount \(m.path) to move it — will retry next pass")
                armTimer(30)
                return false
            }
        }
        if let m = findMount(cfg) {
            switch probe(m.path, timeout: cfg.probeTimeout) {
            case .some(true):
                Log.state("healthy:\(m.path)", reason, "mounted and healthy at \(m.path)")
                armTimer(cfg.pollInterval)
                return true
            case .some(false):
                Log.line(reason, "mount at \(m.path) errors on read — remounting")
            case .none:
                Log.line(reason, "mount at \(m.path) hung \(Int(cfg.probeTimeout))s (stale after sleep?) — force-unmounting")
            }
            if !unmountVolume(m.path, force: true) {
                Log.line(reason, "force-unmount of \(m.path) failed — will retry next pass")
                armTimer(30)
                return false
            }
        }
        let start = Date()
        var delays: [TimeInterval] = [0, 3, 5, 10, 20, 30, 30, 30, 30]
        while true {
            let r = checkReach(cfg)
            if r.isOK {
                guard let token = Keychain.read(cfg) else {
                    Log.state("notoken", reason, "no access token in Keychain — run `dav-remount set-token`")
                    armTimer(cfg.pollInterval)
                    return false
                }
                switch mountShare(cfg, token: token) {
                case .mounted(let path):
                    Log.line(reason, "mounted \(cfg.host)\(cfg.sharePath) at \(path)")
                    Log.state("healthy:\(path)", reason, "mounted and healthy at \(path)")
                    promptDeclined = false
                    armTimer(cfg.pollInterval)
                    return true
                case .authFailed(let rc):
                    Log.state("auth", reason, "server rejected the credential (rc=\(rc)) — token revoked/expired? re-mint and `dav-remount set-token`")
                    if interactive, cfg.promptOnAuthFailure, !promptDeclined {
                        Log.line(reason, "asking for a new token in a dialog")
                        if let t = promptForToken(cfg, reason: "\(cfg.host) rejected the access token for \(cfg.user) (revoked or expired?).") {
                            let st = Keychain.set(cfg, token: t)
                            Log.line(reason, st == errSecSuccess ? "new token stored — retrying the mount" : "Keychain refused the new token (\(st))")
                            if st == errSecSuccess { continue }      // immediate retry, no delay
                        } else {
                            promptDeclined = true                     // ask again only after a success
                            Log.line(reason, "dialog dismissed — will keep trying quietly every 30 s; run `dav-remount set-token` when ready")
                        }
                    }
                    armTimer(30)                  // one try per poll, no hot loop
                    return false
                case .failed(let rc):
                    Log.line(reason, "mount failed rc=\(rc) (\(String(cString: strerror(rc))))")
                }
            } else {
                Log.state("unreach", reason, r.text)
            }
            guard retry, !delays.isEmpty, Date().timeIntervalSince(start) < cfg.retryWindow else { break }
            Thread.sleep(forTimeInterval: delays.removeFirst())
        }
        armTimer(30)                              // short poll while not mounted
        return false
    }

    private func armTimer(_ interval: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + interval)
        t.setEventHandler { [weak self] in self?.schedule("poll") }
        t.resume()
        timer = t
    }

    func onWillSleep() {
        guard cfg.unmountOnSleep else { return }
        q.sync {
            guard let m = findMount(cfg) else { return }
            if unmountVolume(m.path, force: false) {
                Log.line("sleep", "unmounted \(m.path) before sleep")
            } else {
                Log.line("sleep", "could not cleanly unmount \(m.path) (files open?) — will check after wake")
            }
        }
    }

    func onWake() { schedule("wake", delay: 2) }
    func onNetworkChange() { schedule("network", delay: 1) }
}

var agent: Agent!
var powerRootPort: io_connect_t = 0

// IOKit message ids (iokit_common_msg macros don't import into Swift).
let kMsgCanSystemSleep: UInt32 = 0xE000_0270
let kMsgSystemWillSleep: UInt32 = 0xE000_0280
let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

func installPowerHooks() {
    var notifyPort: IONotificationPortRef? = nil
    var notifier: io_object_t = 0
    let cb: IOServiceInterestCallback = { _, _, messageType, messageArgument in
        switch messageType {
        case kMsgCanSystemSleep:
            IOAllowPowerChange(powerRootPort, Int(bitPattern: messageArgument))
        case kMsgSystemWillSleep:
            agent.onWillSleep()
            IOAllowPowerChange(powerRootPort, Int(bitPattern: messageArgument))
        case kMsgSystemHasPoweredOn:
            agent.onWake()
        default: break
        }
    }
    powerRootPort = IORegisterForSystemPower(nil, &notifyPort, cb, &notifier)
    guard powerRootPort != 0, let np = notifyPort else {
        Log.line("run", "WARNING: IORegisterForSystemPower failed — wake detection off, polling only")
        return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(np).takeUnretainedValue(), .defaultMode)
}

var pathMonitor: NWPathMonitor? = nil

/// Any path change (Wi-Fi join, VPN tunnel up/down, cable) re-evaluates the mount.
func installNetworkHook() {
    let m = NWPathMonitor()
    m.pathUpdateHandler = { _ in agent.onNetworkChange() }
    m.start(queue: DispatchQueue(label: "dav-remount.net"))
    pathMonitor = m
}

// MARK: - CLI ------------------------------------------------------------------------

func readSecret(prompt: String) -> String? {
    if isatty(STDIN_FILENO) == 0 { return readLine() }
    var old = termios()
    tcgetattr(STDIN_FILENO, &old)
    var raw = old
    raw.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    FileHandle.standardError.write(prompt.data(using: .utf8)!)
    let s = readLine()
    tcsetattr(STDIN_FILENO, TCSANOW, &old)
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    return s
}

func out(_ s: String) { print(s) }

func usage() {
    out("""
    dav-remount \(VERSION) — keep a WebDAV share mounted across sleep/wake and VPN changes

    usage: dav-remount <command>
      run                    agent mode (LaunchAgent)
      once                   mount now if needed; exit 0 when healthy
      status                 config, reachability, token, mount state
      set-token              store the access token in the Keychain (no echo) and mount
      prompt-token           same, via a macOS dialog
      forget-token           remove the token
      has-token              exit 0 if a token is stored
      unmount [--pause MIN]  eject; optionally pause the agent for MIN minutes
      resume                 clear a pause
      --version, --help

    config: \(Config.path)
    """)
}

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else { usage(); return 2 }
    if cmd == "--version" || cmd == "-V" { out(VERSION); return 0 }
    if cmd == "--help" || cmd == "-h" || cmd == "help" { usage(); return 0 }

    let cfg: Config
    do { cfg = try Config.load() } catch {
        FileHandle.standardError.write("dav-remount: \(error)\n".data(using: .utf8)!)
        return 2
    }
    Log.path = cfg.logPath
    try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)

    switch cmd {
    case "run":
        agent = Agent(cfg, interactive: true)
        Log.line("run", "dav-remount \(VERSION) starting — \(cfg.host)\(cfg.sharePath) as \(cfg.user), poll \(Int(cfg.pollInterval))s, unmount_on_sleep=\(cfg.unmountOnSleep)")
        installPowerHooks()
        installNetworkHook()
        signal(SIGTERM) { _ in Log.line("run", "SIGTERM — exiting (mount left as is)"); exit(0) }
        agent.schedule("startup")
        CFRunLoopRun()
        return 0

    case "once":
        agent = Agent(cfg)
        let ok = agent.ensure("once")
        out(ok ? "OK: \(findMount(cfg)?.path ?? "mounted")" : "FAILED — see \(cfg.logPath)")
        return ok ? 0 : 1

    case "status":
        out("dav-remount \(VERSION)")
        out("config:    \(Config.path)")
        out("share:     \(cfg.url.absoluteString)")
        out("user:      \(cfg.user)")
        if let n = cfg.volumeName { out("volume:    \(n)  (mount dir \(cfg.mountDir ?? "-"))") }
        out("token:     \(Keychain.exists(cfg) ? "present in Keychain" : "MISSING — run `dav-remount set-token`")")
        out("reach:     \(checkReach(cfg).text)")
        if let p = Pause.until() { out("paused:    until \(p)") }
        if let m = findMount(cfg) {
            let h = probe(m.path, timeout: cfg.probeTimeout)
            out("mount:     \(m.path) ← \(m.from)  [\(h == true ? "healthy" : h == false ? "ERRORS" : "HUNG")]")
        } else {
            out("mount:     not mounted")
        }
        out("log:       \(cfg.logPath)")
        return 0

    case "set-token":
        guard let t = readSecret(prompt: "Access token for \(cfg.user) @ \(cfg.host): "),
              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            out("no token entered"); return 1
        }
        let st = Keychain.set(cfg, token: t.trimmingCharacters(in: .whitespacesAndNewlines))
        guard st == errSecSuccess else {
            out("Keychain error \(st): \(SecCopyErrorMessageString(st, nil).map { String($0) } ?? "")"); return 1
        }
        out("stored in login Keychain (item: dav-remount (\(cfg.host))) — mounting")
        let a = Agent(cfg)
        let ok = a.ensure("set-token", retry: false)
        out(ok ? "mounted: \(findMount(cfg)?.path ?? "")" : "stored, but the mount did not come up — see \(cfg.logPath)")
        return ok ? 0 : 1

    case "prompt-token":
        guard let t = promptForToken(cfg, reason: "Enter the access token for \(cfg.user) at \(cfg.host).") else { out("cancelled"); return 1 }
        let st = Keychain.set(cfg, token: t)
        guard st == errSecSuccess else { out("Keychain error \(st)"); return 1 }
        let a = Agent(cfg)
        let ok = a.ensure("prompt-token", retry: false)
        out(ok ? "stored and mounted: \(findMount(cfg)?.path ?? "")" : "stored, but the mount did not come up — see \(cfg.logPath)")
        return ok ? 0 : 1

    case "forget-token":
        let st = Keychain.forget(cfg)
        out(st == errSecSuccess ? "token removed" : "nothing removed (\(st))")
        return 0

    case "has-token":
        return Keychain.exists(cfg) ? 0 : 1

    case "unmount":
        var mins = 0
        if let i = args.firstIndex(of: "--pause"), i + 1 < args.count { mins = Int(args[i + 1]) ?? 0 }
        if mins > 0 { Pause.set(minutes: mins); out("agent paused for \(mins) min") }
        if let m = findMount(cfg) {
            let ok = unmountVolume(m.path, force: false) || unmountVolume(m.path, force: true)
            out(ok ? "unmounted \(m.path)" : "could not unmount \(m.path)")
            Log.line("cli", ok ? "unmounted \(m.path) by request" : "unmount of \(m.path) failed")
            return ok ? 0 : 1
        }
        out("not mounted"); return 0

    case "resume":
        Pause.clear(); out("pause cleared"); return 0

    default:
        usage(); return 2
    }
}

exit(main())
