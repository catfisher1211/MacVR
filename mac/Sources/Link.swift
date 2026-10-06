import Foundation
import Network

/// TCP link to the Quest app (wire protocol in common/vr4mac.h). USB: adb reverse to loopback. Wi-Fi: the Mac never
/// broadcasts; the Quest sends "VR4MAC?" to UDP 9944 every second, we answer that one sender, and it connects. A Wi-Fi
/// headset must present the pairing token it was given over USB before it can stream or send input.
final class Link {
    var onHello: ([String: Any]) -> Void = { _ in }
    /// Tracking + each hand's 26 OpenXR joints while it is hand-tracked (nil = holding a controller / not seen).
    var onTracking: (VR4Tracking, [[VR4Pose]?]) -> Void = { _, _ in }
    var onRequestIDR: () -> Void = {}
    var onMic: (Data) -> Void = { _ in }
    /// VR4_STATUS: headset battery and its decoder stats (JSON, about once a second).
    var onStatus: ([String: Any]) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    var onIssue: (String) -> Void = { _ in }
    private(set) var connected = false
    private(set) var peer = ""
    /// USB: the Quest reaches us through adb reverse, so the peer is loopback.
    var wired: Bool { Link.isLoopback(peer) }
    private var conn: NWConnection?
    private var inFlight = 0
    private var audioInFlight = 0
    private var audioPackets: [Data] = [], otherPackets: [Data] = []
    private var sending = false
    private let q = DispatchQueue(label: "vr4.link", qos: .userInteractive)
    private var listener: NWListener?
    private let usbQueue = DispatchQueue(label: "vr4.usb", qos: .utility)
    private var usbPending = false
    /// Accept headsets on the local network (Settings > Wi-Fi play). Off: loopback (USB) only.
    private(set) var wifi = false
    private var probe: DispatchSourceRead?
    static var pairToken: String {
        if let t = UserDefaults.standard.string(forKey: "link.pair_token"), t.count == 32 { return t }
        let t = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        UserDefaults.standard.set(t, forKey: "link.pair_token"); return t
    }
    static func isLoopback(_ host: String) -> Bool { host.contains("127.0.0.1") || host == "::1" }
    /// A Wi-Fi headset's first packet: a HELLO carrying this Mac's pairing token (handed over on USB).
    static func paired(_ type: UInt8, _ body: Data) -> Bool {
        guard Int(type) == VR4_HELLO, let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let t = j["token"] as? String else { return false }
        return t == pairToken
    }
    private let port: UInt16

    init(port: UInt16 = UInt16(VR4_PORT_TCP)) { self.port = port }

    func start(discovery: Bool = true, wifi: Bool = false) {
        self.wifi = wifi
        listen()
        guard discovery else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1)
        var n = 0
        t.setEventHandler { [weak self] in
            if n % 5 == 0, self?.connected == false { self?.retryUSB() }
            n += 1
        }
        t.resume()
        timer = t
    }
    /// Turn Wi-Fi play on or off while running: restarts the listener (a USB session stays connected).
    func setWiFi(_ on: Bool) { q.async { [self] in guard on != wifi else { return }; wifi = on; listener?.cancel(); listen() } }
    private func listen() {
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.disableAckStretching = true   // prompt ACKs: lower latency for tracking/video
        probe?.cancel(); probe = nil
        do {
            let params = NWParameters(tls: nil, tcp: tcp)
            params.serviceClass = .interactiveVideo
            if wifi { answerProbes(); listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) }   // every interface
            else {   // USB only
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                listener = try NWListener(using: params)
            }
        } catch {
            onIssue("Cannot listen for a headset: \(error.localizedDescription). Close other MacVR instances and reopen the app.")
            return
        }
        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onIssue("")
            case .failed(let error): self?.onIssue("Headset connection unavailable: \(error.localizedDescription). Close other MacVR instances and reopen the app.")
            default: break
            }
        }
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.start(queue: q)
    }
    /// Answers a Quest's "VR4MAC?" probe (UDP 9944) with "VR4MAC 9945", to that sender only.
    private func answerProbes() {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return }
        var yes: Int32 = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = UInt16(VR4_PORT_DISCOVERY).bigEndian; a.sin_addr.s_addr = INADDR_ANY
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else {
            close(s); onIssue("Wi-Fi play: UDP port \(VR4_PORT_DISCOVERY) is busy. Close other MacVR instances."); return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: q)
        src.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 64), from = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &buf, buf.count, 0, $0, &len) } }
            guard n > 0, String(decoding: buf[0..<n], as: UTF8.self) == "VR4MAC?" else { return }
            let reply = "VR4MAC \(VR4_PORT_TCP)"
            _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, reply, reply.utf8.count, 0, $0, len) } }
        }
        src.setCancelHandler { close(s) }
        src.resume(); probe = src
    }
    private var timer: DispatchSourceTimer?

    /// adb can block on USB authorization; keep it off the packet/connection queue.
    func retryUSB() {
        q.async { [weak self] in
            guard let self, !self.usbPending else { return }
            self.usbPending = true
            self.usbQueue.async { [weak self] in
                _ = adbReverse()
                self?.q.async { self?.usbPending = false }
            }
        }
    }

    private func accept(_ c: NWConnection) {
        var host = ""
        if case .hostPort(let h, _) = c.endpoint { host = "\(h)" }
if Link.isLoopback(host) { promote(c); return }
        guard wifi else { NSLog("VR4Mac: Wi-Fi play is off; refused %@", host); c.cancel(); return }
        // Wi-Fi: the first packet must be a HELLO carrying the USB pairing token, before it can replace anything
        c.stateUpdateHandler = { s in if case .failed(let e) = s { NSLog("VR4Mac: Wi-Fi headset at %@ failed: %@", host, "\(e)") } }
        c.start(queue: q)
        let timeout = DispatchWorkItem { [weak c] in c?.cancel() }
        q.asyncAfter(deadline: .now() + 5, execute: timeout)
        readOne(c) { [weak self] type, body in
            timeout.cancel()
            guard let self, Link.paired(type, body) else {
                NSLog("VR4Mac: refused a Wi-Fi headset at %@ (not paired over USB)", host)
                self?.onIssue("A headset on Wi-Fi tried to connect but isn't paired. Connect it once with USB to pair it.")
                c.cancel(); return
            }
            self.promote(c, started: true)
            self.handle(type, body)
            self.readPacket(c)
        }
    }
    private func promote(_ c: NWConnection, started: Bool = false) {
        if let previous = conn {
            previous.cancel()
            onDisconnect()
        }
        connected = false
        conn = c; resetSends()
        if case .hostPort(let h, _) = c.endpoint { peer = "\(h)" }
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c, c === self.conn else { return }
            switch s {
            case .ready: self.connected = true; self.onIssue("")
            case .failed, .cancelled: self.connected = false; self.conn = nil; self.resetSends(); self.peer = ""; self.onDisconnect()
            default: break
            }
        }
        if started { connected = true; onIssue("") } else { c.start(queue: q); readPacket(c) }
    }

    private func readPacket(_ c: NWConnection) {
        readOne(c) { [weak self] type, body in
            guard let self, c === self.conn else { return }   // stale connection replaced by a newer one
            self.handle(type, body)
            self.readPacket(c)
        }
    }
    /// One packet: 1-byte type, little-endian u32 length, payload. Any error or close cancels the connection.
    private func readOne(_ c: NWConnection, _ got: @escaping (UInt8, Data) -> Void) {
        c.receive(minimumIncompleteLength: 5, maximumLength: 5) { h, _, done, err in
            guard let h, h.count == 5, err == nil, !done else { c.cancel(); return }
            let type = h[h.startIndex], len = Int(h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self) })
            guard len <= Int(VR4_MAX_PAYLOAD) else { c.cancel(); return }
            if len == 0 { got(type, Data()); return }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { b, _, _, err in
                guard let b, b.count == len, err == nil else { c.cancel(); return }
                got(type, b)
            }
        }
    }

    private func handle(_ type: UInt8, _ b: Data) {
        switch Int(type) {
        case VR4_HELLO: if let j = try? JSONSerialization.jsonObject(with: b) as? [String: Any] { onHello(j) }
        case VR4_TRACKING where b.count == MemoryLayout<VR4Tracking>.size || b.count == MemoryLayout<VR4Tracking>.size + 2 * MemoryLayout<VR4HandJoints>.size:
            var joints: [[VR4Pose]?] = [nil, nil]
            b.withUnsafeBytes { raw in
                guard raw.count > MemoryLayout<VR4Tracking>.size else { return }
                for h in 0..<2 {
                    let o = MemoryLayout<VR4Tracking>.size + h * MemoryLayout<VR4HandJoints>.size
                    guard raw.loadUnaligned(fromByteOffset: o, as: UInt32.self) != 0 else { continue }
                    joints[h] = (0..<Int(VR4_HAND_JOINTS)).map { raw.loadUnaligned(fromByteOffset: o + 4 + $0 * MemoryLayout<VR4Pose>.size, as: VR4Pose.self) }
                }
            }
            onTracking(b.withUnsafeBytes { $0.loadUnaligned(as: VR4Tracking.self) }, joints)
        case VR4_REQUEST_IDR: onRequestIDR()
        case VR4_MIC: onMic(b)
        case VR4_STATUS: if let j = try? JSONSerialization.jsonObject(with: b) as? [String: Any] { onStatus(j) }
        default: break
        }
    }

    /// Packets queued but not yet handed to the kernel; used to limit video latency.
    var backlog: Int { q.sync { inFlight } }
    /// Count 10 ms PCM chunks separately: a few large video sends must not discard audio.
    /// Keep these included in total backlog so congestion slows video submissions first.
    var audioBacklog: Int { q.sync { audioInFlight } }

    func send(_ type: Int32, _ payload: Data) {
        var d = Data([UInt8(type)])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(payload)
        q.async { [self] in
            guard conn != nil else { return }
            inFlight += 1
            if type == VR4_AUDIO { audioInFlight += 1; audioPackets.append(d) }
            else { otherPackets.append(d) }
            drainSends()
        }
    }

    private func resetSends() {
        inFlight = 0; audioInFlight = 0; sending = false
        audioPackets.removeAll(); otherPackets.removeAll()
    }

    /// Submit one complete wire packet at a time. When the socket is congested,
    /// newly captured audio can precede waiting video instead of sitting behind it.
    /// Video/config order is preserved and encoded frames are never discarded here.
    private func drainSends() {
        guard !sending, let c = conn else { return }
        let isAudio = !audioPackets.isEmpty
        guard isAudio || !otherPackets.isEmpty else { return }
        let packet = isAudio ? audioPackets.removeFirst() : otherPackets.removeFirst()
        sending = true
        c.send(content: packet, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, c === self.conn else { return }
            self.inFlight = max(0, self.inFlight - 1)
            if isAudio { self.audioInFlight = max(0, self.audioInFlight - 1) }
            if error != nil { c.cancel(); return }
            self.sending = false
            self.drainSends()
        })
    }

    func sendJSON(_ type: Int32, _ obj: [String: Any]) { send(type, (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()) }
}

let adbPath = ["/opt/homebrew/bin/adb", NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb", "/usr/local/bin/adb"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// Wired mode: makes the Quest's 127.0.0.1:9945 reach this Mac over USB.
@discardableResult func adbReverse() -> Bool {
    guard let adb = adbPath else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: adb)
    p.arguments = ["reverse", "tcp:\(VR4_PORT_TCP)", "tcp:\(VR4_PORT_TCP)"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    if done.wait(timeout: .now() + 8) == .timedOut { p.terminate(); return false }   // unauthorized/hung adb: don't block Retry USB forever
    return p.terminationStatus == 0
}
