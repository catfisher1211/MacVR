import Foundation
import Darwin

@main struct LinkLifecycle {
    static func wait(_ signal: DispatchSemaphore, _ label: String) {
        precondition(signal.wait(timeout: .now() + 5) == .success, "Timed out: \(label)")
    }
    static func client(_ port: UInt16, host: String = "127.0.0.1", hello: String = "{\"device\":\"Lifecycle test\"}") -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var size: Int32 = 4096
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(result == 0, "connect failed")
        send(fd, VR4_HELLO, hello)
        return fd
    }
    static func send(_ fd: Int32, _ type: Int, _ json: String) {
        let body = Data(json.utf8)
        var packet = Data([UInt8(type)])
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(body)
        packet.withUnsafeBytes { precondition(Darwin.write(fd, $0.baseAddress, $0.count) == $0.count) }
    }
    static func main() {
        let port: UInt16 = 19985
        let ready = DispatchSemaphore(value: 0), hello = DispatchSemaphore(value: 0)
        let disconnected = DispatchSemaphore(value: 0), conflict = DispatchSemaphore(value: 0)
        let link = Link(port: port)
        link.onIssue = { if $0.isEmpty { ready.signal() } }
        link.onHello = { _ in hello.signal() }
        link.onDisconnect = { disconnected.signal() }
        link.start(discovery: false)
        wait(ready, "listener ready")
        let first = client(port); wait(hello, "first HELLO")
        let status = DispatchSemaphore(value: 0)
        link.onStatus = { if $0["battery"] as? Int == 83, $0["charging"] as? Bool == true { status.signal() } }
        send(first, 42, "{}")   // unknown packet types are skipped, the link stays up
        send(first, VR4_STATUS, "{\"battery\":83,\"charging\":true,\"latency_ms\":31.5}")
        wait(status, "STATUS parsed")
        for _ in 0..<160 { link.send(Int32(VR4_VIDEO), Data(count: 65536)) }
        precondition(link.backlog > 0, "Must exercise pending sends")
        precondition(link.audioBacklog == 0, "Video congestion must not consume the audio allowance")
        for _ in 0..<12 { link.send(Int32(VR4_AUDIO), Data(count: 1928)) }
        precondition(link.audioBacklog > 0, "Must exercise pending audio behind congested video")
        // Read real wire packets from the previously stalled receiver. Audio must
        // jump ahead of waiting video without corrupting either packet's framing.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(first, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        func readExactly(_ count: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count), offset = 0
            while offset < count {
                let n = bytes.withUnsafeMutableBytes { Darwin.read(first, $0.baseAddress!.advanced(by: offset), count - offset) }
                precondition(n > 0, "Timed out or truncated wire packet")
                offset += n
            }
            return bytes
        }
        var precedingVideo = 0
        while true {
            let h = readExactly(5)
            let length = h.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian) }
            precondition(length == (h[0] == VR4_AUDIO ? 1928 : 65536), "Intact packet boundary")
            _ = readExactly(length)
            if h[0] == VR4_AUDIO { break }
            precondition(h[0] == VR4_VIDEO, "Expected audio/video")
            precedingVideo += 1
            precondition(precedingVideo < 160, "Audio must precede queued video under congestion")
        }
        print("PASS: audio priority over stalled video with intact wire framing (\(precedingVideo) video packets already submitted)")
        let second = client(port); wait(disconnected, "replacement cleanup"); wait(hello, "replacement HELLO")
        close(first)
        Thread.sleep(forTimeInterval: 0.2)
        precondition(link.backlog == 0, "Old completions must not corrupt new connection backlog")
        precondition(link.audioBacklog == 0, "Replacement must reset audio accounting")
        close(second); wait(disconnected, "EOF cleanup")
        precondition(link.backlog == 0, "Disconnected backlog must reset")
        precondition(link.audioBacklog == 0, "Disconnected audio backlog must reset")
        let other = Link(port: port)
        other.onIssue = { if !$0.isEmpty { conflict.signal() } }
        other.start(discovery: false)
        wait(conflict, "port conflict surfaced")
        print("PASS: pending-send replacement, HELLO reconnect, STATUS, EOF cleanup, listener failure")
        wifi()
    }
    /// This Mac's first non-loopback IPv4 address (a stand-in for the Quest's view of it on Wi-Fi).
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?; guard getifaddrs(&list) == 0 else { return nil }; defer { freeifaddrs(list) }
        var p = list
        while let a = p { defer { p = a.pointee.ifa_next }
            guard let sa = a.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var b = [CChar](repeating: 0, count: 64)
            _ = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var x = $0.pointee.sin_addr; return inet_ntop(AF_INET, &x, &b, 64) }
            let ip = String(cString: b); if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
    /// Wi-Fi play: unpaired headsets are refused, a paired one connects, the "VR4MAC?" probe is answered.
    static func wifi() {
        let hello = { (t: String) in Data("{\"device\":\"Quest\",\"token\":\"\(t)\"}".utf8) }
        precondition(Link.paired(UInt8(VR4_HELLO), hello(Link.pairToken)), "paired HELLO admitted")
        precondition(!Link.paired(UInt8(VR4_HELLO), hello("nope")) && !Link.paired(UInt8(VR4_HELLO), Data("{}".utf8)), "unpaired refused")
        precondition(!Link.paired(UInt8(VR4_TRACKING), hello(Link.pairToken)), "only a HELLO can open a Wi-Fi session")
        precondition(Link.isLoopback("127.0.0.1") && !Link.isLoopback("192.168.1.4"), "USB is loopback")
        print("PASS: Wi-Fi pairing rules")
        // Live LAN sockets need macOS Local Network permission for this binary: opt in with VR4_TEST_LAN=1.
        guard ProcessInfo.processInfo.environment["VR4_TEST_LAN"] == "1", let ip = lanAddress() else { return }
        let port: UInt16 = 19987
        let ready = DispatchSemaphore(value: 0), helloed = DispatchSemaphore(value: 0), refused = DispatchSemaphore(value: 0)
        let link = Link(port: port)
        link.onIssue = { if $0.isEmpty { ready.signal() } else if $0.contains("isn't paired") { refused.signal() } }
        link.onHello = { _ in helloed.signal() }
        link.start(discovery: false, wifi: true)
        wait(ready, "Wi-Fi listener ready")
        let bad = client(port, host: ip, hello: "{\"device\":\"Stranger\",\"token\":\"nope\"}"); wait(refused, "unpaired refused")
        precondition(helloed.wait(timeout: .now() + 0.3) == .timedOut, "unpaired must not reach HELLO"); close(bad)
        let good = client(port, host: ip, hello: "{\"device\":\"Quest\",\"token\":\"\(Link.pairToken)\"}"); wait(helloed, "paired HELLO over Wi-Fi")
        precondition(!link.wired, "LAN peer is not USB"); close(good)
        print("PASS: Wi-Fi pairing over the LAN")
    }
}
