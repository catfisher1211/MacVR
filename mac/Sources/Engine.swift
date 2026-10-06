import Foundation
import AppKit
import SceneKit

/// Shared memory with the Wine-side OpenXR runtime (layout in common/vr4mac.h).
final class Shm {
    let p: UnsafeMutablePointer<VR4Shm>
    /// `scratch`: a private, already-unlinked file (offline renders must not touch a running MacVR's game session).
    init(scratch: Bool = false) {
        mkdir("/tmp/vr4mac", 0o777)
        let path = scratch ? NSTemporaryDirectory() + "vr4mac-snapshot-\(getpid())" : VR4_SHM_PATH_MAC
        let fd = open(path, O_RDWR | O_CREAT, 0o666)
        ftruncate(fd, off_t(VR4_SHM_SIZE))
        p = mmap(nil, Int(VR4_SHM_SIZE), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)!.bindMemory(to: VR4Shm.self, capacity: 1)
        close(fd)
        if scratch { unlink(path) }
        if p.pointee.magic != VR4_SHM_MAGIC || p.pointee.version != VR4_SHM_VERSION {
            memset(p, 0, MemoryLayout<VR4Shm>.size)
            p.pointee.magic = VR4_SHM_MAGIC; p.pointee.version = VR4_SHM_VERSION
        }
    }
    func write(_ t: VR4Tracking, joints: [[VR4Pose]?] = [nil, nil]) {
        p.pointee.track_seq &+= 1; vr4_fence()
        p.pointee.track = t
        withUnsafeMutableBytes(of: &p.pointee.hand_joints) { raw in   // VR4HandJoints[2]: u32 tracked + 26 poses each
            let stride = MemoryLayout<VR4HandJoints>.size
            for h in 0..<2 {
                raw.storeBytes(of: UInt32(joints[h] == nil ? 0 : 1), toByteOffset: h * stride, as: UInt32.self)
                for (k, j) in (joints[h] ?? []).prefix(Int(VR4_HAND_JOINTS)).enumerated() { raw.storeBytes(of: j, toByteOffset: h * stride + 4 + k * MemoryLayout<VR4Pose>.size, as: VR4Pose.self) }
            }
        }
        vr4_fence()
        p.pointee.track_seq &+= 1
    }
    func frame(_ i: UInt32) -> UnsafeRawPointer { UnsafeRawPointer(vr4_frame(p, i)) }
}

/// Owns the headset session: link <-> compositor/game frames <-> encoder.
final class Engine: ObservableObject {
    /// `--snapshot`: an offline render. Private shared memory, no listeners, no Wine/Steam/mic/crash-marker side effects,
    /// so it can run next to the user's MacVR.
    static let offline = CommandLine.arguments.contains("--snapshot")
    /// Offline renders never capture the Mac screen unless asked (VR4_CAPTURE=1, e.g. README shots of the desktop view).
    static let captureInSnapshots = ProcessInfo.processInfo.environment["VR4_CAPTURE"] == "1"
    /// Snapshot stand-in for the Mac screen (VR4_TEST_SCREEN=1): a test card, so theater/desktop render without capture.
    private var testScreen: CVPixelBuffer?
    let settings = Settings(), games = Games(), link = Link(), encoder = Encoder(), shm = Shm(scratch: Engine.offline), desktop = DesktopCapture(), audio = AudioCapture()
    let dash: Dashboard
    #if MACVR_DEV
    private let tuner = HandTuner()
    #endif
    private let comp = Compositor()   // not lazy: touched from both the render and dashboard queues
    private let rq = DispatchQueue(label: "vr4.render", qos: .userInteractive)
    /// Dashboard state, CoreGraphics drawing and texture upload live here so the render queue never waits on them.
    private let dq = DispatchQueue(label: "vr4.dash", qos: .userInitiated)
    private var drawScheduled = false, lastMinute = -1   // dq only
    private var dashView = "home"                         // rq copy of dash.view
    private let viewLock = NSLock()
    private var _viewFrame: CVPixelBuffer?
    /// Latest side-by-side frame sent to the headset (for the VR View window).
    var viewFrame: CVPixelBuffer? { viewLock.lock(); defer { viewLock.unlock() }; return _viewFrame }
    private func setViewFrame(_ pb: CVPixelBuffer?) { viewLock.lock(); _viewFrame = pb; viewLock.unlock() }

    @Published var connected = false
    @Published var device = ""
    @Published var hands = (false, false)
    @Published var controllers = (false, false)
    @Published var nowPlaying = ""
    @Published var streamInfo = ""   // e.g. "USB · 2432x1344 @ 72 Hz" for the Mac window
    @Published var connectionIssue = ""
    private lazy var gameOverrides = GameOverrides { [weak self] render, world in
        self?.shm.p.pointee.render_scale = render
        self?.shm.p.pointee.world_scale = world
    }
    private var updatesObserver: NSObjectProtocol?
    private var overrideObserver: NSObjectProtocol?

    /// Settings > About on the Mac: show the welcome tour in the headset again.
    func replayTour() { dq.async { [self] in dash.startTutorial(); rq.async { self.setMenu(true) } } }

    private var eyeW = 0, eyeH = 0, fps = 72
    private var floorOffset: Float = 0
    private var useHEVC = false
    private var dashVisible = true, needPlace = true, windowShown = true
    private var menuDownAt: [CFTimeInterval] = [0, 0], menuHoldDone = [false, false]
    private var prevButtons: [UInt32] = [0, 0], prevTrigger: [Bool] = [false, false], prevGrip: [Bool] = [false, false], activeHand = 1
    /// Direct touch: the index fingertip is pressing a panel (tap = click, slide = drag); last fingertip depth.
    private var touchDown = [false, false], touchDepth: [Float] = [1, 1]
    private var directTouch = true
    private var grabHand: Int?                       // rq: hand dragging the window or dock by its grab bar
    private var desktopRect = CGRect.zero            // rq copy of dash.desktopRect
    private var detected: HeadsetModel = .quest2     // from HELLO
    private var backdropOn = false
    private var theaterOn = false, theaterPlace = false   // rq: flatscreen games / the Mac on a big screen
    private var tourFinal = false                         // rq: tour is on its "press your menu button" step
    private var lastTrack: VR4Tracking?
    private var pending: VR4Tracking?, scheduled = false, pendingJoints: [[VR4Pose]?] = [nil, nil]
    private let pendingLock = NSLock()
    private var frameId: UInt64 = 0
    private var gameSeq: UInt32 = 0, hapticSeq: UInt32 = 0, lastGameFrame = Date.distantPast, gameActive = false
    private var fpsCount = 0, fpsT = Date()
    /// 5 s pipeline counters (logged): game frames seen, handed to the encoder, encoded, skipped for link backlog.
    private var stat = (game: 0, encIn: 0, encoded: 0, backlogSkip: 0, t: Date())
    private var audioStat = (packets: 0, dropped: 0, peak: Int16(0))   // rq
    private var uiQueue: [Int32] = [], lastAudioChunk = Date.distantPast, uiTimer: DispatchSourceTimer?   // rq: UI sounds for the headset

    /// UI sounds -> 48 kHz stereo, summed into the pending headset mix (44.1 kHz WAVs from UISounds, linear resample).
    private func pullUISounds() {
        for wav in UISounds.shared.takePending() where wav.count >= 44 + 8 {   // at least 2 stereo frames (interpolation reads i+1)
            wav.withUnsafeBytes { b in
                let src = b.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self), n = (wav.count - 44) / 4
                let out = n * 48_000 / 44_100
                if uiQueue.count < out * 2 { uiQueue += [Int32](repeating: 0, count: out * 2 - uiQueue.count) }
                for j in 0..<out {
                    let pos = Double(j) * 44_100 / 48_000, i = min(Int(pos), n - 2), f = Int32((pos - Double(i)) * 256)
                    for c in 0..<2 { uiQueue[2 * j + c] += (Int32(src[2 * i + c]) * (256 - f) + Int32(src[2 * i + 2 + c]) * f) >> 8 }
                }
            }
        }
    }
    /// Adds the next 10 ms of UI sound into a VR4_AUDIO packet (8-byte time header + 480 stereo s16 frames).
    private func mixUI(into pkt: inout Data) {
        pkt.withUnsafeMutableBytes { b in UISounds.shared.mixMusic(into: b.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self), frames: (b.count - 8) / 4) }
        pullUISounds()
        guard !uiQueue.isEmpty else { return }
        let n = min(uiQueue.count, (pkt.count - 8) / 2)
        pkt.withUnsafeMutableBytes { b in
            let pcm = b.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self)
            for i in 0..<n { pcm[i] = Int16(max(-32768, min(32767, Int32(pcm[i]) + uiQueue[i]))) }
        }
        uiQueue.removeFirst(n)
    }
    private var audioEnabled = false // rq only

    init() {
        dash = Dashboard(settings: settings, games: games)
        if !Engine.offline { Updates.shared.start(settings, gameOpen: { [weak self] in
            guard let self else { return true }
            let busy = self.rq.sync { self.gameActive || self.loadingSince != nil || self.theaterOn }
            return busy || Games.isGameRunning()
        }) }
        updatesObserver = NotificationCenter.default.addObserver(forName: Updates.changed, object: nil, queue: nil) { [weak self] _ in
            self?.dq.async { [weak self] in self?.requestDraw() }
        }
        if !Engine.offline, MenuFallback.install(settings) {
            dash.note("The Quest menu crashed last time, so MacVR switched to the SteamVR menu. You can switch back in Settings > Universal Menu.", 12)
        }
        overrideObserver = NotificationCenter.default.addObserver(forName: Dashboard.overrideChanged, object: nil, queue: nil) { [weak self] note in
            guard let appid = note.userInfo?["appid"] as? String, let key = note.userInfo?["key"] as? String else { return }
            self?.rq.async { [weak self] in
                self?.gameOverrides.changed(appid, key: key)
            }
        }
        settings.onChange = { [weak self] in self?.rq.async { self?.applySettings() } }
        #if MACVR_DEV   // hand tuner web page: developer builds only
        tuner.rebuild = { [weak self] in self?.rq.async { self?.comp.rebuildHands() } }
        tuner.setPose = { [weak self] p in self?.rq.async { self?.comp.demoPose = p } }
        tuner.model = { [weak self] in self?.comp.shownControllerModel ?? .quest2 }
        if !Engine.offline { tuner.start() }
        #endif
        games.onUpdate = { [weak self] in self?.requestDraw() }
        dash.windowJump = { [weak self] in self?.rq.async { self?.comp.jump() } }
        dash.launch = { [weak self] g in
            guard let self else { return }
            // per-game overrides for the runtime (0 = default): render resolution and world scale
            let theater = Dashboard.override(g.appid, "theater") == 1
            rq.async { [self] in
                self.gameOverrides.start(g.appid)
                self.games.launch(g)
                // VR games: the menu closes and the home fades into a loading space with the game's card until its first frame
                if g.vr && !theater && !self.gameActive && !self.theaterOn, let head = self.lastTrack?.head {
                    self.comp.setLoading(g.name, art: self.games.image(g.appid, "header"), head: head); self.loadingSince = CACurrentMediaTime(); self.setMenu(false)
                }
            }
            dash.note("Launching \(g.name)…", 4)
        }
        dash.power = { [weak self] in self?.games.quitGame(); self?.dash.note("Quitting game", 3); self?.rq.async { self?.endLoading() } }
        dash.install = { [weak self] g in   // Steam asks to confirm on the Mac: show the desktop so it can be clicked in VR
            guard let self else { return }
            games.install(g)
            dq.asyncAfter(deadline: .now() + 1.5) { [self] in   // self is non-optional here
                self.dash.view = "desktop"; self.dash.note("Confirm the install in Steam's window", 5); self.requestDraw()
            }
        }
        dash.redraw = { [weak self] in self?.requestDraw() }
        link.onMic = { Mic.shared.receive($0) }
        Mic.shared.onChange = { [weak self] in self?.rq.async { self?.sendConfig() } }
        if !Engine.offline { Mic.shared.apply() }
        dash.recenter = { [weak self] in self?.rq.async { self?.needPlace = true } }
        dash.refreshStream = { [weak self] in self?.encoder.forceIDR = true }
        dash.close = { [weak self] in guard self?.dash.view != "welcome" else { return }; self?.rq.async { self?.setMenu(false) } }
        dash.onToast = { [weak self] text, secs in   // menu closed (in a game): show it head-locked on the stream instead
            self?.rq.async { [weak self] in
                guard let self, !self.dashVisible else { return }
                toastPanel = (Compositor.overlayPanel([(text, Engine.white, true)], ppm: ppm, textHeight: 0.022, image: toastThumb), CACurrentMediaTime() + secs); toastThumb = nil
            }
        }
        dash.uninstall = { [weak self] g in   // Steam confirms on the Mac: show the desktop so it can be clicked in VR
            guard let self else { return }
            games.uninstall(g)
            dq.asyncAfter(deadline: .now() + 1.5) { [self] in self.dash.view = "desktop"; self.dash.note("Confirm the uninstall in Steam's window", 5); self.requestDraw() }
        }
        dash.openSteam = { [weak self] in self?.games.openSteam() }
        dash.theater = { [weak self] on in self?.rq.async { self?.setTheater(on) } }
        dash.openMacWindows = { [weak self] in self?.rq.async { self?.openPicker() } }
        dash.screenshot = { [weak self] in   // from the menu: close it first, so the picture is of the world (or game)
            self?.rq.async { self?.setMenu(false); self?.rq.asyncAfter(deadline: .now() + 0.3) { self?.takeScreenshot() } }
        }
        dash.version = "MacVR OS " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        // desktop control (Accessibility-gated CGEvents)
        let input = DesktopInput.shared
        dash.desktopTrusted = input.trusted
        dash.requestTrust = { input.requestTrust() }
        dash.desktopPointer = { p, phase in
            if p.x >= 0 { input.move(toNormalized: p) }
            if phase == 1 { input.button(false, down: true) } else if phase == 3 { input.button(false, down: false) }
        }
        dash.desktopRightClick = { p in input.move(toNormalized: p); input.button(true, down: true); input.button(true, down: false) }
        dash.desktopScroll = { dy in input.scroll(dx: 0, dy: dy) }
        dash.typeText = { input.type($0) }
        dash.keyCode = { input.key(CGKeyCode($0)) }
        dash.setMacVolume = { v in DispatchQueue.global().async { Engine.appleScript("set volume output volume \(v)") } }
        link.onHello = { [weak self] j in self?.rq.async { self?.hello(j) } }
        link.onIssue = { [weak self] message in DispatchQueue.main.async { self?.connectionIssue = message } }
        link.onTracking = { [weak self] t, j in self?.tracking(t, joints: j) }
        link.onRequestIDR = { [weak self] in self?.encoder.forceIDR = true }
        link.onStatus = { [weak self] j in self?.rq.async { self?.status(j) } }
        audio.onChunk = { [weak self] pkt in
            self?.rq.async {
                guard let self, self.audioEnabled else { return }
                guard self.link.audioBacklog < 10 else { self.audioStat.dropped += 1; return }
                var out = Engine.mix(pkt)
                self.mixUI(into: &out); self.lastAudioChunk = Date()
                self.audioStat.packets += 1
                out.withUnsafeBytes { b in
                    let pcm = b.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self)
                    for i in stride(from: 0, to: (b.count - 8) / 2, by: 16) { self.audioStat.peak = max(self.audioStat.peak, pcm[i] == .min ? .max : abs(pcm[i])) }
                }
                self.link.send(Int32(VR4_AUDIO), out)
            }
        }
        audio.onError = { [weak self] message in
            self?.dq.async { self?.dash.say(message) }
        }
        link.onDisconnect = { [weak self] in
            DesktopInput.shared.releaseAll()
            self?.shm.p.pointee.client_connected = 0
            self?.rq.async { [weak self] in
                guard let self else { return }
                audioEnabled = false; audio.stop(); uiQueue = []
                prevButtons = [0, 0]; prevTrigger = [false, false]; prevGrip = [false, false]
                grabHand = nil; lastTrack = nil; headsetStatus = [:]
                desktop.stop(); setViewFrame(nil)
                dq.async { [weak self] in self?.dash.release(nil); self?.dash.grabbing = nil; self?.dash.headsetBattery = -1; self?.requestDraw() }
            }
            UISounds.shared.headsetOnly = false
            DispatchQueue.main.async { self?.connected = false; self?.hands = (false, false); self?.controllers = (false, false); self?.streamInfo = "" }
        }
        encoder.onFrame = { [weak self] data, idr, t in   // VideoToolbox thread: counters live on rq
            self?.rq.async { [weak self] in
                guard let self else { return }
                self.stat.encoded += 1; self.perf.videoBytes += data.count
                self.frameId += 1
                var h = VR4VideoHeader(frame_id: self.frameId, time_ns: t, flags: idr ? 1 : 0)
                var d = Data(bytes: &h, count: MemoryLayout<VR4VideoHeader>.size)
                d.append(data)
                self.link.send(Int32(VR4_VIDEO), d)
            }
        }
        gameSeq = shm.p.pointee.frame_seq   // frames left over from an earlier run are not a running game
        games.scan()
        if !Engine.offline { DispatchQueue.global(qos: .utility).async { [weak self] in   // install/refresh runtime, OpenComposite and game fixes at startup
            SiliconXR.install()   // VR for native Mac games (OpenXR + Vivecraft); independent of the Wine setup below
            do { try self?.games.setup() } catch {   // shown in the status window, not just the log
                NSLog("VR4Mac: setup failed: \(error)")
                DispatchQueue.main.async { self?.games.status = "Setup failed: \(error.localizedDescription)" }
            }
        } }
        if !Engine.offline { link.start(wifi: settings.bool("wifi_play")) }
        rq.async { self.applySettings() }

        // game frames + haptics from the Wine runtime; ponytail: 1 ms poll, swap for a semaphore if CPU matters
        let t = DispatchSource.makeTimerSource(queue: rq)
        t.schedule(deadline: .now(), repeating: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.pollRuntime() }
        t.resume(); pollTimer = t
        let clock = DispatchSource.makeTimerSource(queue: dq)
        clock.schedule(deadline: .now(), repeating: 1)
        clock.setEventHandler { [weak self] in   // clock needs a redraw once a minute; the fps counter every second
            guard let self else { return }
            let m = Calendar.current.component(.minute, from: Date())
            if m != self.lastMinute || self.settings.bool("show_fps") { self.lastMinute = m; self.requestDraw() }
        }
        clock.resume(); clockTimer = clock
    }
    private var pollTimer: DispatchSourceTimer?, clockTimer: DispatchSourceTimer?

    private var mbps: Int { settings["bitrate"] == "Auto" ? (link.wired ? 100 : 40) : settings.int("bitrate") }
    // Auto bitrate (rq): frames backing up on the link or dropped by the headset lower the encoder's rate; clean seconds
    // bring it back up to the ceiling.
    private var autoMbps = 0, linkSkips = 0, cleanSince = CACurrentMediaTime(), lastAdapt = CACurrentMediaTime()
    /// Best recent headset frame age (ms), creeping up 0.5 ms/s. On Wi-Fi a stall queues frames in the TCP send buffer
    /// where `link.backlog` can't see them and the headset drops nothing; only the frame age grows.
    private var latencyFloor = Double.infinity
    static func adaptBitrate(_ cur: Int, ceiling: Int, congested: Bool, cleanFor: Double) -> Int {
        if congested { return max(15, cur * 4 / 5) }                       // back off 20% (not below 15 Mbps)
        return cleanFor >= 8 ? min(ceiling, cur + max(2, cur / 10)) : cur   // after 8 s clean: +10% per second
    }
    private func adaptBitrate() {
        lastAdapt = CACurrentMediaTime()
        defer { linkSkips = 0 }
        guard settings["bitrate"] == "Auto" || !link.wired, eyeW > 0, link.connected else { autoMbps = mbps; return }
        if autoMbps == 0 { autoMbps = mbps }
        var lagging = false
        if let lat = headsetStatus["latency_ms"] as? Double, lat > 0 {
            latencyFloor = min(latencyFloor + 0.5, lat)
            lagging = lat > latencyFloor + 40
        }
        let congested = linkSkips > 1 || (headsetStatus["dropped"] as? Int ?? 0) > 2 || lagging
        if congested { cleanSince = CACurrentMediaTime() }
        let next = Engine.adaptBitrate(autoMbps, ceiling: mbps, congested: congested, cleanFor: CACurrentMediaTime() - cleanSince)
        if next != autoMbps { NSLog("VR4Mac: auto bitrate %d -> %d Mbps", autoMbps, next); autoMbps = next; encoder.setBitrate(next) }
    }

    /// Coalesced dashboard redraw on dq; the finished texture is handed to the render queue.
    private func requestDraw() {
        dq.async { [self] in
            guard !drawScheduled else { return }
            drawScheduled = true
            dq.async { [self] in
                drawScheduled = false
                dash.draw()
                let tex = comp.uploadDashboard(dash.context), v = dash.view, r = dash.desktopRect, kb = dash.keyboardOpen
                let sideTex = (0..<2).map { i in dash.sideContext(i).flatMap { comp.uploadSide(i, $0) } }
                let wo = dash.windowOpen, toastOn = dash.toastVisible
                let touring = v == "welcome", finalStep = dash.tourFinalStep, tourPart = dash.tourPart, hs = dash.headset
                dash.liveTourController = true
                if dash.animatingUntil > CACurrentMediaTime() { dq.asyncAfter(deadline: .now() + .milliseconds(16)) { self.requestDraw() } }
                rq.async { [self] in
                    comp.setDashboard(tex)
                    for i in 0..<2 { comp.setSide(i, sideTex[i]) }
                    if v != dashView && dashVisible && !(v == "keyboard" && dashView == "library") { comp.pop(dock: false) }   // new window pops up
                    if wo && !windowShown && dashVisible { comp.pop(dock: false) }   // reopened from the dock
                    windowShown = wo; comp.setWindowHidden(!wo && !toastOn)   // a toast keeps the (minimised) window's panel up
                    UISounds.shared.setMusic(touring)   // welcome-tour music, faded out when the tour ends
                    dashView = v; desktopRect = r; comp.setKeyboard(kb)
                    tourFinal = finalStep
                    comp.setDockHidden(touring)
                    comp.setSpace(touring && !finalStep)   // space during the tour; fades into the home on the last step
                    comp.setTourController(touring ? hs : nil, part: tourPart)
                }
            }
        }
    }

    /// Headset Audio level, balance and mono from Quick Settings, applied to the s16le stereo stream (8-byte time header).
    static func mix(_ pkt: Data) -> Data {
        let s = UISounds.shared, vol = Float(s.streamVolume) / 100, bal = Float(s.balance) / 50, mono = s.mono
        guard vol != 1 || bal != 0 || mono else { return pkt }
        var out = pkt
        let gl = vol * min(1, 1 - bal), gr = vol * min(1, 1 + bal)
        out.withUnsafeMutableBytes { raw in
            let pcm = raw.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Int16.self), n = (raw.count - 8) / 4
            for i in 0..<n {
                var l = Float(pcm[2 * i]), r = Float(pcm[2 * i + 1])
                if mono { let m = (l + r) / 2; l = m; r = m }
                pcm[2 * i] = Int16(max(-32768, min(32767, l * gl))); pcm[2 * i + 1] = Int16(max(-32768, min(32767, r * gr)))
            }
        }
        return out
    }

    @discardableResult static func appleScript(_ src: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        return NSAppleScript(source: src)?.executeAndReturnError(&err)
    }

    /// Open/close the menu while preserving its spatial anchor. Holding ≡ explicitly recenters it.
    private func setMenu(_ on: Bool) {
        guard on != dashVisible else { return }
        dashVisible = on; grabHand = nil
        UISounds.shared.play(on ? "menuOpen" : "menuClose")
        if on { comp.pop(dock: true) } else { DesktopInput.shared.releaseAll() }
        let trusted = DesktopInput.shared.trusted
        dq.async { [self] in
            if on { dash.opened(); dash.desktopTrusted = trusted } else { dash.release(nil); dash.grabbing = nil }
            requestDraw()
        }
        if on {   // current Mac volume for the Quick Settings slider
            DispatchQueue.global().async { [weak self] in
                let v = Engine.appleScript("output volume of (get volume settings)")?.int32Value ?? -1
                self?.dq.async { self?.dash.macVolume = Int(v); self?.requestDraw() }
            }
        }
    }

    private func setTheater(_ on: Bool) {
        guard on != theaterOn else { return }
        theaterOn = on; theaterPlace = on; comp.lasersAlways = on
        if on { setMenu(false) } else { DesktopInput.shared.releaseAll() }
        UISounds.shared.play(on ? "env" : "close")
        dq.async { [self] in dash.theaterOn = on; requestDraw() }
    }
    private var theaterPrev = (trigger: [false, false], grip: [false, false])
    /// Theater with the menu closed: either laser is the Mac's mouse (trigger click/drag, grip right-click, stick scroll).
    private func theaterInput(_ t: VR4Tracking, _ hs: [VR4Hand], _ valid: [Bool], _ trigs: [Bool]) {
        let input = DesktopInput.shared
        var rays: [Float?] = [nil, nil]
        for i in 0..<2 where valid[i] {
            let trig = trigs[i], grip = hs[i].squeeze > 0.7
            if let h = comp.theaterHit(hs[i].aim) {
                rays[i] = h.dist
                if i == activeHand || trig { input.move(toNormalized: h.uv) }
                if trig != theaterPrev.trigger[i] { activeHand = i; input.button(false, down: trig) }
                if grip && !theaterPrev.grip[i] { input.button(true, down: true); input.button(true, down: false) }
                if abs(hs[i].stick_y) > 0.2 { input.scroll(dx: 0, dy: Int32((hs[i].stick_y * 18).rounded())) }
            } else if theaterPrev.trigger[i] && !trig { input.button(false, down: false) }
            theaterPrev.trigger[i] = trig; theaterPrev.grip[i] = grip
        }
        comp.updateHands(t, rays: rays)
    }

    private func applyControllers() {
        let s = settings["controller_model"]
        let m = ["Quest 1": HeadsetModel.quest1, "Quest 2": .quest2, "Quest 3": .quest3][s] ?? detected
        comp.setControllerModel(m)
    }

    private func applySettings() {
        applyControllers()
        if !Engine.offline { link.setWiFi(settings.bool("wifi_play")) }
        let quest = settings["menu_style"] != "SteamVR"   // Quest: a small window at arm's length, dock down by the hands
        let touch = settings.bool("direct_touch"), compact = quest && touch
        directTouch = touch
        comp.setLayout(quest: quest, compact: compact)
        let radii: [String: Float] = compact ? ["NEAR": 0.7, "MIDDLE": 0.85, "FAR": 1.0] : quest ? ["NEAR": 1.5, "MIDDLE": 1.8, "FAR": 2.2] : ["NEAR": 1.3, "MIDDLE": 1.8, "FAR": 2.5]
        comp.setRadius(radii[settings["dashboard_position"]] ?? radii["NEAR"]!)
        #if MACVR_DEV
        comp.setEnvironment(ProcessInfo.processInfo.environment["VR4_ENV"] ?? settings["environment"])   // VR4_ENV: README renders
        #else
        comp.setEnvironment(settings["environment"])
        #endif
        comp.setHomeStyle(settings["home_style"])
        comp.setCurved(settings.bool("ui_curved"))
        comp.showArms = settings.bool("show_arms")
        let arms = settings.bool("show_arms")   // skin colour, body and mirror only apply with arms on
        comp.skinTone = arms ? settings["avatar_skin"] : "Original"
        comp.showBody = arms && settings.bool("show_body")
        comp.showMirror = arms && settings.bool("home_mirror")
        comp.reduceMotion = settings.bool("reduce_motion")
        comp.setTheaterStyle(Compositor.theaterStyle(screen: settings["theater_screen"], curved: settings.bool("theater_curved"), lights: settings["theater_lights"]))
        comp.setGrid(settings.bool("floor_grid"))
        if eyeW > 0 { encoder.configure(width: eyeW * 2, height: eyeH, fps: fps, mbps: mbps, maxQP: link.wired ? (useHEVC ? 18 : 23) : (useHEVC ? 34 : 30), hevc: useHEVC); autoMbps = mbps }
        requestDraw()
    }

    private var config: [String: Any] = [:], helloMic = false
    private let trackingCadence = TrackingCadence()
    /// CONFIG, also re-sent (same video params) when the microphone choice changes, to start/stop headset capture.
    private func sendConfig() {
        guard !config.isEmpty else { return }
        var c = config; c["mic"] = helloMic && Mic.shared.useHeadset
        if link.wired { c["pair"] = Link.pairToken }   // USB pairs the headset for Wi-Fi play
        link.sendJSON(Int32(VR4_CONFIG), c)
    }

    private func hello(_ j: [String: Any]) {
        trackingCadence.reset()
        let scale = Double(settings.int("render_scale")) / 100
        let rw = (j["eye_w"] as? Int).map { max(256, min(4096, $0)) } ?? 1440, rh = (j["eye_h"] as? Int).map { max(256, min(4096, $0)) } ?? 1584
        eyeW = max(128, min(2048, Int(Double(rw) * scale) / 32 * 32)); eyeH = max(128, min(2048, Int(Double(rh) * scale) / 32 * 32))
        latencyFloor = .infinity
        if !link.wired && eyeW > 1664 {   // ~40 Mbps can't feed 2048x2048 per eye at 90 Hz; a smaller, cleaner picture looks sharper
            eyeH = eyeH * 1664 / eyeW / 32 * 32; eyeW = 1664
        }
        floorOffset = j["reference_space"] as? String == "local" ? 1.6 : 0   // client has no STAGE space: assume standing height
        let rates = (j["refresh_rates"] as? [Double])?.map { Int($0.rounded()) } ?? [72]
        NSLog("VR4Mac: HELLO eye %dx%d, refresh %@, codecs %@, hevc max %@x%@", rw, rh, "\(rates)", (j["codecs"] as? [String])?.joined(separator: ",") ?? "none", "\(j["hevc_max_eye_w"] ?? "-")", "\(j["hevc_max_eye_h"] ?? "-")")
        fps = rates.contains(settings.int("refresh_rate")) ? settings.int("refresh_rate") : (rates.first ?? 72)
        useHEVC = settings["codec"] == "HEVC" && (j["codecs"] as? [String])?.contains("hevc") == true
        if useHEVC, let mw = j["hevc_max_eye_w"] as? Int, let mh = j["hevc_max_eye_h"] as? Int, mw > 0, mh > 0 {
            eyeW = min(eyeW, mw / 32 * 32); eyeH = min(eyeH, mh / 32 * 32)
        }
        // Preserve older headsets' decoder budget; the higher HEVC budget was tested only on Quest 3.
        let quest3 = (j["device"] as? String) == "Quest 3"
        let maxPixelsPerSecond = useHEVC ? (quest3 ? 1_050_000_000 : 480_000_000) : 983_040 * 256
        while eyeW * 2 * eyeH * fps > maxPixelsPerSecond && eyeW > 256 {
            eyeW = (eyeW * 15 / 16) / 32 * 32; eyeH = (eyeH * 15 / 16) / 32 * 32
        }
        helloMic = j["mic"] as? Bool == true
        // encoder first: CONFIG must name a codec that actually started (HEVC falls back to H.264), or the headset waits on a black stream
        if !encoder.configure(width: eyeW * 2, height: eyeH, fps: fps, mbps: mbps, maxQP: link.wired ? (useHEVC ? 18 : 23) : (useHEVC ? 34 : 30), hevc: useHEVC), useHEVC {
            useHEVC = false
            encoder.configure(width: eyeW * 2, height: eyeH, fps: fps, mbps: mbps, maxQP: link.wired ? 23 : 30, hevc: false)
        }
        autoMbps = mbps; config = ["eye_w": eyeW, "eye_h": eyeH, "fps": fps, "codec": useHEVC ? "hevc" : "h264"]
        sendConfig()
        NSLog("VR4Mac: %@ connected %@, %dx%d per eye @ %d Hz, %d Mbps", j["device"] as? String ?? "Quest", link.wired ? "over USB" : "over Wi-Fi", eyeW, eyeH, fps, mbps)
        let s = shm.p
        s.pointee.eye_w = UInt32(eyeW); s.pointee.eye_h = UInt32(eyeH); s.pointee.fps = Float(fps); s.pointee.client_connected = 1
        needPlace = true
        let name = j["device"] as? String ?? "Quest"
        detected = HeadsetModel.detect(device: name); applyControllers()
        Mic.shared.headsetName = detected.label
        activeHand = Dashboard.pointingHand   // the hand chosen in the welcome tour drives the menus first
        let info = "\(eyeW * 2)x\(eyeH) @ \(fps) Hz", wired = link.wired, hs = detected
        dq.async { [self] in
            dash.headset = hs; dash.linkStatus = wired ? "USB" : "Wi-Fi"; dash.streamInfo = info
            if !Dashboard.tutorialDone && dash.view != "welcome" { dash.startTutorial() }   // first-run welcome tour
            requestDraw()
        }
        audioEnabled = j["audio"] as? Bool == true
        if audioEnabled { audio.start() } else { audio.stop() }
        UISounds.shared.headsetOnly = audioEnabled
        if audioEnabled && uiTimer == nil {   // UI sounds still reach the headset when system capture is silent or unavailable
            let t = DispatchSource.makeTimerSource(queue: rq)
            t.schedule(deadline: .now(), repeating: .milliseconds(10))
            t.setEventHandler { [weak self] in
                guard let self, self.audioEnabled, Date().timeIntervalSince(self.lastAudioChunk) > 0.03 else { return }
                self.pullUISounds()
                guard !self.uiQueue.isEmpty || UISounds.shared.musicPlaying, self.link.audioBacklog < 10 else { return }
                var t = UInt64(DispatchTime.now().uptimeNanoseconds)
                var pkt = Data(bytes: &t, count: 8); pkt.append(Data(count: 1920))
                self.mixUI(into: &pkt); self.audioStat.packets += 1
                self.link.send(Int32(VR4_AUDIO), pkt)
            }
            t.resume(); uiTimer = t
        }
        let mainInfo = (wired ? "USB" : "Wi-Fi") + " · " + info
        DispatchQueue.main.async { self.connected = true; self.device = hs.label; self.streamInfo = mainInfo }
    }

    /// Called on the link queue for every TRACKING packet; coalesces onto the render queue.
    private func tracking(_ raw: VR4Tracking, joints raw2: [[VR4Pose]?] = [nil, nil]) {
        if let measured = trackingCadence.observe(raw.time_ns) {
            rq.async { [self] in
                guard measured != fps, eyeW > 0 else { return }
                NSLog("VR4Mac: tracking cadence %d Hz; correcting startup pacing %d Hz", measured, fps)
                fps = measured; shm.p.pointee.fps = Float(measured)
                encoder.setExpectedFrameRate(measured)
                let info = "\(eyeW * 2)x\(eyeH) @ \(measured) Hz (tracking)"
                dq.async { [self] in dash.streamInfo = info; requestDraw() }
                DispatchQueue.main.async { self.streamInfo = (self.link.wired ? "USB" : "Wi-Fi") + " · " + info }
            }
        }
        var t = raw, joints = raw2
        if !settings.bool("hand_tracking") {
            joints = [nil, nil]
            // Never forward optical hand poses or pinch input while the experiment is off.
            if t.hand.0.flags & UInt32(VR4_HAND_TRACKED) != 0 { t.hand.0 = VR4Hand() }
            if t.hand.1.flags & UInt32(VR4_HAND_TRACKED) != 0 { t.hand.1 = VR4Hand() }
        }
        // A live controller wins over simultaneous optical joints. Otherwise a
        // wrist pose replaces the controller grip and shifts in-game hands/input.
        let controllerHands = [raw.hand.0, raw.hand.1]
        for i in 0..<2 where controllerHands[i].flags & UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID | VR4_HAND_TRACKED) == UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID) {
            joints[i] = nil
        }
        for h in 0..<2 { joints[h] = joints[h]?.map { var p = $0; p.py += floorOffset; return p } }
        if floorOffset != 0 {   // LOCAL-space client: lift everything so the floor sits at y = 0 like STAGE
            t.head.py += floorOffset; t.eye.0.pose.py += floorOffset; t.eye.1.pose.py += floorOffset
            t.hand.0.aim.py += floorOffset; t.hand.0.grip.py += floorOffset; t.hand.1.aim.py += floorOffset; t.hand.1.grip.py += floorOffset
        }
        // a tracked hand stands in for its controller: pinch = trigger, aim from the shoulder through the pinch
        if let j = joints[0] { t.hand.0 = HandGesture.hand(j, head: t.head, left: true, was: t.hand.0) }
        if let j = joints[1] { t.hand.1 = HandGesture.hand(j, head: t.head, left: false, was: t.hand.1) }
        var game = t   // while ≡ is held its trigger combos (screenshot) stay out of the game
        if game.hand.0.buttons & UInt32(VR4_BTN_MENU) != 0 { game.hand.0.trigger = 0; game.hand.1.trigger = 0 }
        shm.write(game, joints: joints)
        pendingLock.lock(); pending = t; pendingJoints = joints; let go = !scheduled; scheduled = true; pendingLock.unlock()
        guard go else { return }
        rq.async { [self] in
            pendingLock.lock(); let t = pending!; comp.joints = pendingJoints; scheduled = false; pendingLock.unlock()
            frame(t)
        }
    }

    /// Laser pointers on the menu: trigger press/hold/release, grip = secondary, stick = scroll.
    private var teleportAiming = false
    private func lasers(_ t: VR4Tracking, _ hs: [VR4Hand], _ valid: [Bool], _ trig: [Bool], _ grip: [Bool], _ rays: inout [Float?], _ poke: [Bool]) {
        if teleportAiming { return }
        var hits: [(uv: CGPoint, dist: Float, slot: Int)?] = [nil, nil]
        for i in 0..<2 where valid[i] && !poke[i] {
            // a tracked hand points only while thumb and index are poised to pinch (or pinching / dragging)
            if hs[i].flags & UInt32(VR4_HAND_TRACKED) != 0 && hs[i].flags & UInt32(VR4_HAND_PINCH_READY) == 0 && !trig[i] && grabHand != i { continue }
            if let h = comp.hit(hs[i].aim, solid: { self.dash.solid($0, slot: $1) }) { hits[i] = h; rays[i] = h.dist }
        }
        if !trig[activeHand] {   // the hand that pulls the trigger (or the only one pointing at the menu) drives it
            if let i = (0..<2).first(where: { hits[$0] != nil && trig[$0] && !prevTrigger[$0] }) { activeHand = i }
            else if hits[activeHand] == nil, let i = (0..<2).first(where: { hits[$0] != nil }) { activeHand = i }
        }
        let a = activeHand, uv = hits[a]?.uv, dist = hits[a]?.dist, aim = hs[a].aim, head = t.head, slot = hits[a]?.slot ?? 1
        if let s = hits[a]?.slot, grabHand == nil { comp.setSlotFocus(s) }
        let down = trig[a] && !prevTrigger[a], held = trig[a] && prevTrigger[a], up = !trig[a] && prevTrigger[a]
        let secondary = grip[a] && !prevGrip[a], stick = grabHand == nil ? hs[a].stick_y : 0
        let pinch = hs[a].flags & UInt32(VR4_HAND_TRACKED) != 0   // hands click on release and drag to scroll, like touch
        if grabHand == nil, dashView == "desktop", abs(hs[a].stick_x) > 0.5, hits[a] != nil {
            comp.zoomWindow(hs[a].stick_x * 0.012)   // stick left/right on the Mac desktop: smaller/bigger window
        }
        dq.async { [self] in
            var changed = false
            if down, let uv {
                laserSlot = slot
                let p = dash.inSlot(slot) { pinch ? dash.pinchDown(uv) : dash.press(uv) }
                if p == .grabWindow || p == .grabDock || p == .grabKeyboard, let dist {
                    dash.grabbing = p == .grabWindow ? "grab" : p == .grabDock ? "grabdock" : "grabkb"
                    let part: Compositor.Part = p == .grabWindow ? .window : p == .grabDock ? .dock : .keyboard
                    rq.async { self.grabHand = a; self.comp.beginGrab(part, aim, dist: dist, head: head, slot: slot) }
                }
                changed = true
            } else if held, let uv { dash.inSlot(laserSlot) { dash.drag(uv) }; changed = true }
            if up { dash.inSlot(laserSlot) { pinch ? dash.touchUp(uv ?? CGPoint(x: -10, y: -10)) : dash.release(uv) }; changed = true }
            if secondary, let uv { dash.inSlot(slot) { dash.secondary(uv) } }
            if abs(stick) > 0.2, let uv, dash.inSlot(slot, { dash.scroll(stick, at: uv) }) { changed = true }
            if dash.inSlot(slot, { dash.pointer(uv) }) { changed = true; if uv != nil { haptic(a, 0.25, 0.015) } }
            if changed { requestDraw() }
        }
    }
    private var laserSlot = 1, touchSlot = [1, 1]   // dashboard queue: the window a press started in
    private var rawTrigger = [false, false], comboTrigger = [false, false]   // rq: system-button combos
    /// Buttons that act as the system button on hand `i`: left ≡, plus Y / B if enabled in Settings.
    private func systemMask(_ i: Int) -> UInt32 {
        (i == 0 ? UInt32(VR4_BTN_MENU) : 0) | (settings.bool("system_button") ? UInt32(i == 0 ? VR4_BTN_Y : VR4_BTN_B) : 0)
    }

    private func frame(_ t: VR4Tracking) {
        lastTrack = t
        guard eyeW > 0 else { return }
        let hs = [t.hand.0, t.hand.1]
        let valid = hs.map { $0.flags & UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID) == UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID) }
        if valid[0] != hands.0 || valid[1] != hands.1 { DispatchQueue.main.async { self.hands = (valid[0], valid[1]) } }
        let controllerValid = hs.enumerated().map { valid[$0.offset] && $0.element.flags & UInt32(VR4_HAND_TRACKED) == 0 }
        if controllerValid[0] != controllers.0 || controllerValid[1] != controllers.1 {
            DispatchQueue.main.async { self.controllers = (controllerValid[0], controllerValid[1]) }
            dq.async { [self] in dash.controllersOn = (controllerValid[0], controllerValid[1]); requestDraw() }
        }

        teleportAiming = comp.updateTeleport(t, enabled: !gameActive && !theaterOn && grabHand == nil)

        // System button combos (like the Quest's Meta button): hold ≡ and pull a trigger for a screenshot. The trigger
        // then belongs to the combo until it is let go (no click on the menu, the game sees it released).
        var trig = (0..<2).map { valid[$0] && hs[$0].trigger > 0.55 }
        var grip = (0..<2).map { valid[$0] && hs[$0].squeeze > 0.7 }
        let system = (0..<2).filter { valid[$0] && hs[$0].buttons & systemMask($0) != 0 }
        for j in 0..<2 {
            if !system.isEmpty && trig[j] && !rawTrigger[j] {
                comboTrigger[j] = true; system.forEach { menuHoldDone[$0] = true }   // the ≡ release then neither toggles nor recenters
                takeScreenshot(); haptic(j, 0.6, 0.03)
            }
            rawTrigger[j] = trig[j]
            if !trig[j] { comboTrigger[j] = false } else if comboTrigger[j] { trig[j] = false }
        }

        // left ≡ (menu) is the Quest system button: a press opens/closes the menu, holding it recenters (and opens) it.
        // B / Y too if enabled in Settings.
        for i in 0..<2 {
            let mask = systemMask(i)
            let down = valid[i] && hs[i].buttons & mask != 0, was = prevButtons[i] & mask != 0
            if down && !was { menuDownAt[i] = CACurrentMediaTime(); menuHoldDone[i] = false }
            if down && !menuHoldDone[i] && CACurrentMediaTime() - menuDownAt[i] > 0.6 && dashView != "welcome" {
                menuHoldDone[i] = true; needPlace = true; UISounds.shared.play("pop")   // hold: recenter in front of you
                if !dashVisible { setMenu(true) } else { comp.pop(dock: true) }
            }
            if !down && was && !menuHoldDone[i] {
                if dashView == "welcome" {   // the tour only ends on its last step, by pressing the menu button
                    if tourFinal { dq.async { [self] in dash.finishTutorial(); requestDraw() }; setMenu(false) }
                } else { setMenu(!dashVisible) }
            }
            prevButtons[i] = valid[i] ? hs[i].buttons : 0
        }
        shm.p.pointee.input_blocked = dashVisible ? 1 : 0
        if needPlace { comp.place(head: t.head); needPlace = false }
        comp.setDashVisible(dashVisible)

        // laser pointers: trigger press/hold/release, grip = secondary, stick = scroll (or push/pull while grabbing)
        var rays: [Float?] = [nil, nil], push: [SIMD3<Float>] = [.zero, .zero], poke = [false, false]
        let windowHands = macWindowInput(t, hs, valid, trig, grip, &rays)   // Mac windows and their picker (pinned ones with the menu closed too)
        if dashVisible {
            if let g = grabHand {
                if valid[g] && trig[g] {
                    if comp.updateGrab(hs[g].aim, head: t.head, push: abs(hs[g].stick_y) > 0.6 ? (hs[g].stick_y - 0.6 * (hs[g].stick_y > 0 ? 1 : -1)) * 0.03 : 0) {   // wide stick dead zone: worn sticks drift
                        haptic(g, 0.8, 0.04); UISounds.shared.play("drop")   // hit the distance stop: it sticks here
                    }
                }
                else {
                    grabHand = nil; let moved = comp.endGrab(); UISounds.shared.play("drop")
                    dq.async { [self] in dash.grabbing = nil; if let (a, b) = moved { dash.moveWindow(from: a, to: b) }; requestDraw() }
                }
            }
            // direct touch: the fingertip pad presses when it reaches the surface and re-arms once lifted ~1 cm (taps type
            // fast); the hand stays on the surface unless pushed 6 cm through; while pressed, sliding drags.
            var touchUV: CGPoint?, touchUVSlot = 1
            for i in 0..<2 where directTouch {
                let tc = valid[i] ? comp.touch(i, grip: hs[i].grip) : nil
                let onMenu = tc.map { dash.solid($0.uv, slot: $0.slot) } ?? false, d = onMenu ? tc!.depth : 1
                poke[i] = onMenu && d < 0.12 && !trig[i]   // pulling the trigger keeps the laser
                if onMenu && d < 0 && d > -0.06 { push[i] = tc!.normal * -d }
                let wasDown = touchDown[i]
                touchDown[i] = poke[i] && d > -0.06 && (wasDown ? d < 0.012 : d <= 0.003 && touchDepth[i] > 0.003)
                touchDepth[i] = touchDown[i] ? min(touchDepth[i], d) : d
                guard onMenu, let uv = tc?.uv else { if wasDown { dq.async { [self] in dash.inSlot(touchSlot[i]) { dash.touchUp(nil) }; requestDraw() } }; continue }
                let ts = tc!.slot
                if poke[i] && d < 0.05 { touchUV = uv; touchUVSlot = ts; rays[i] = nil }
                if touchDown[i] && !wasDown {   // landed: light the control (sliders start moving)
                    haptic(i, 0.3, 0.012)
                    dq.async { [self] in touchSlot[i] = ts; dash.inSlot(ts) { dash.touchDown(uv) }; requestDraw() }
                } else if touchDown[i] { dq.async { [self] in dash.inSlot(touchSlot[i]) { dash.drag(uv) }; requestDraw() } }   // sliders, or a swipe scrolls
                else if wasDown {               // lifted: that's the click
                    haptic(i, 0.5, 0.02)
                    dq.async { [self] in dash.inSlot(touchSlot[i]) { dash.touchUp(uv) }; requestDraw() }
                }
            }
            if let uv = touchUV { let ts = touchUVSlot; comp.setSlotFocus(ts); dq.async { [self] in if dash.inSlot(ts, { dash.pointer(uv) }) { requestDraw() } } }   // a finger at the menu drives it
            if touchUV == nil || grabHand != nil { lasers(t, hs, valid, trig, grip, &rays, (0..<2).map { poke[$0] || windowHands[$0] }) }
        }
        for i in 0..<2 { prevTrigger[i] = trig[i]; prevGrip[i] = grip[i] }
        comp.updateHands(t, rays: rays, push: push, poke: poke)

        // the desktop tab streams the Mac screen onto the dashboard
        let wantDesktop = dashVisible && windowShown && dashView == "desktop"
        if (wantDesktop || theaterOn) && (!Engine.offline || Engine.captureInSnapshots) { desktop.start() } else if desktop.running { desktop.stop() }
        let screen = testScreen ?? desktop.latest
        comp.setTheater(theaterOn ? screen : nil, head: theaterPlace ? t.head : nil)
        if theaterOn && screen != nil { theaterPlace = false }
        if theaterOn && !dashVisible { theaterInput(t, hs, valid, trig) }
        let streaming = screen != nil
        dq.async { [self] in if dash.desktopStreaming != streaming { dash.desktopStreaming = streaming; requestDraw() } }
        let shot = wantDesktop ? screen : nil
        comp.setScreen(shot, rect: desktopRect)
        if let shot {
            let aspect = CGFloat(CVPixelBufferGetWidth(shot)) / CGFloat(max(1, CVPixelBufferGetHeight(shot)))
            dq.async { [self] in if abs(dash.desktopAspect - aspect) > 0.001 { dash.desktopAspect = aspect; requestDraw() } }
        }

        updateMacWindows()
        if gameActive && !dashVisible { return }   // game frames drive the stream
        if backdropOn && !(gameActive && dashVisible) { comp.setGameBackdrop(nil, poses: [], fovs: []); backdropOn = false }
        guard link.backlog < 3 else { linkSkips += 1; return }
        let r0 = DispatchTime.now().uptimeNanoseconds
        guard let pb = comp.render(t, eyeW: eyeW, eyeH: eyeH) else { return }
        perf.renderNs += DispatchTime.now().uptimeNanoseconds - r0; perf.renders += 1
        send(pb, t.time_ns, eyes: [t.eye.0.pose, t.eye.1.pose], fovs: [t.eye.0.fov, t.eye.1.fov])
    }

    /// `eyes`/`fovs`: the poses the frame was rendered with (head-locked overlays are projected with them).
    private func send(_ pb: CVPixelBuffer, _ timeNs: UInt64, eyes: [VR4Pose], fovs: [VR4Fov]) {
        if shotPending { shotPending = false; saveShot(pb) }   // before the overlays: they aren't part of the picture
        perf.frames += 1
        if CACurrentMediaTime() - perf.t >= 1 { updateHUD() }
        comp.stamp(pb, eyes: eyes, fovs: fovs, overlays())
        if Date().timeIntervalSince(stat.t) >= 5 {
            let d = Date().timeIntervalSince(stat.t)
            NSLog("VR4Mac: pipeline %.1f game fps, %.1f to encoder, %.1f encoded, %d backlog skips; audio %d pkts (%d dropped, peak %d, enabled %d)", Double(stat.game) / d, Double(stat.encIn) / d, Double(stat.encoded) / d, stat.backlogSkip, audioStat.packets, audioStat.dropped, Int(audioStat.peak), audioEnabled ? 1 : 0)
            audioStat = (0, 0, 0)
            stat = (0, 0, 0, 0, Date())
        }
        setViewFrame(pb)
        if encoder.encode(pb, timeNs: timeNs) { stat.encIn += 1 }
        fpsCount += 1
        if Date().timeIntervalSince(fpsT) >= 1 { let n = fpsCount; dq.async { self.dash.fps = n }; fpsCount = 0; fpsT = Date() }
    }

    private var loadingSince: CFTimeInterval?   // rq: a VR game's loading space is up
    /// Back from the loading space to the home (first frame arrived, the game was quit, or it never started).
    private func endLoading() { loadingSince = nil; comp.setLoading(nil) }

    private func pollRuntime() {
        let s = shm.p
        if CACurrentMediaTime() - lastAdapt >= 1 { adaptBitrate() }
        if let l = loadingSince, CACurrentMediaTime() - l > 90 {   // never started in VR: back home, say where to look
            endLoading(); setMenu(true); notify("The game hasn't started in VR. Check your Mac for a prompt or error.")
        }
        if s.pointee.haptic_seq != hapticSeq {
            hapticSeq = s.pointee.haptic_seq
            var h = s.pointee.haptic
            link.send(Int32(VR4_HAPTICS), Data(bytes: &h, count: MemoryLayout<VR4Haptics>.size))
        }
        let seq = s.pointee.frame_seq
        if seq != gameSeq {
            gameSeq = seq; lastGameFrame = Date(); stat.game += 1
            if !gameActive {
                gameActive = true; setMenu(false); endLoading()
                let name = withUnsafeBytes(of: s.pointee.app_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let shown = name.replacingOccurrences(of: "OpenComposite_", with: "")
                dq.async { [self] in dash.gameActive = true; dash.gameName = shown; requestDraw() }
                NSLog("VR4Mac: streaming game frames from '%@'", name)
                DispatchQueue.main.async { self.nowPlaying = name.isEmpty ? "VR Game" : name }
            }
            let i = seq % 2
            let (w, h) = (Int(withUnsafeBytes(of: s.pointee.frame_w) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) }),
                          Int(withUnsafeBytes(of: s.pointee.frame_h) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) }))
            let t = withUnsafeBytes(of: s.pointee.frame_time_ns) { $0.load(fromByteOffset: Int(i) * 8, as: UInt64.self) }
            let rgba = withUnsafeBytes(of: s.pointee.frame_rgba) { $0.load(fromByteOffset: Int(i) * 4, as: UInt32.self) } != 0
            guard w > 0, h > 0, w * h * 4 <= Int(VR4_FRAME_MAX) else { return }
            if dashVisible {   // menu over the game: keep the latest game frame as the (world-locked) backdrop
                guard let pb = comp.copyFrame(shm.frame(i), w: w, h: h, outW: w, outH: h, rgba: rgba), let lt = lastTrack else { return }
                let poses = withUnsafeBytes(of: s.pointee.frame_eye_pose) { b in
                    (0..<2).map { e in b.load(fromByteOffset: (Int(i) * 2 + e) * MemoryLayout<VR4Pose>.stride, as: VR4Pose.self) }
                }
                comp.setGameBackdrop(pb, poses: poses, fovs: [lt.eye.0.fov, lt.eye.1.fov]); backdropOn = true
                return
            }
            guard link.backlog < 3 else { stat.backlogSkip += 1; linkSkips += 1; return }
            guard let pb = comp.copyFrame(shm.frame(i), w: w, h: h, outW: eyeW * 2, outH: eyeH, rgba: rgba) else { return }
            let poses = withUnsafeBytes(of: s.pointee.frame_eye_pose) { b in
                (0..<2).map { e in b.load(fromByteOffset: (Int(i) * 2 + e) * MemoryLayout<VR4Pose>.stride, as: VR4Pose.self) }
            }
            send(pb, t, eyes: poses, fovs: lastTrack.map { [$0.eye.0.fov, $0.eye.1.fov] } ?? [])
        } else if gameActive && Date().timeIntervalSince(lastGameFrame) > 2 {
            gameActive = false; comp.fadeInHome(); setMenu(true)
            gameOverrides.stop()
            dq.async { [self] in dash.gameActive = false; dash.gameName = ""; requestDraw() }
            NSLog("VR4Mac: game stopped, back to home")
            DispatchQueue.main.async { self.nowPlaying = "" }
        }
    }

    private func haptic(_ hand: Int, _ amp: Float, _ dur: Float) {
        var h = VR4Haptics(hand: UInt8(hand), amplitude: amp, duration_s: dur, frequency_hz: 0)
        link.send(Int32(VR4_HAPTICS), Data(bytes: &h, count: MemoryLayout<VR4Haptics>.size))
    }

    // MARK: system overlays (rq): performance HUD, toasts and the recording light, stamped onto every frame (games too)
    private var perfLogs = 0, loggedSkips = 0
    private var perf = (frames: 0, renderNs: UInt64(0), renders: 0, videoBytes: 0, t: CACurrentMediaTime())
    private var headsetStatus: [String: Any] = [:], lowBatteryWarned = false
    private var hudPanel: CGContext?, toastPanel: (CGContext, CFTimeInterval)?, toastThumb: CGImage?
    /// Stream pixels per metre at 1 m (sizes the overlays from the eye FOV).
    private var ppm: Float {
        guard let f = lastTrack?.eye.0.fov, f.right > f.left else { return Float(eyeW) / 2 }
        return Float(eyeW) / (tan(f.right) - tan(f.left))
    }
    private static let white = CGColor(gray: 1, alpha: 1), grey = CGColor(srgbRed: 0.78, green: 0.81, blue: 0.85, alpha: 1)

    /// VR4_STATUS from the headset: battery for the menu, decoder stats for the HUD, a low-battery warning at 10%.
    private func status(_ j: [String: Any]) {
        headsetStatus = j
        let b = j["battery"] as? Int ?? -1, charging = j["charging"] as? Bool == true
        dq.async { [self] in if dash.headsetBattery != b || dash.headsetCharging != charging { dash.headsetBattery = b; dash.headsetCharging = charging; requestDraw() } }
        if b >= 0 && b <= 10 && !charging && !lowBatteryWarned { lowBatteryWarned = true; notify("Headset battery low: \(b)%") }
        if charging || b > 15 { lowBatteryWarned = false }
    }

    /// Once a second: rebuild the performance HUD (Settings > Developer > Performance Overlay).
    private func updateHUD() {
        let d = max(0.001, CACurrentMediaTime() - perf.t), p = perf
        perf = (0, 0, 0, 0, CACurrentMediaTime())
        let enc = encoder.takeEncodeMs()
        let encoderSkips = encoder.takeBackpressureSkips()
        perfLogs += 1; loggedSkips += encoderSkips
        if perfLogs % 5 == 0 {   // every 5 s, alongside the pipeline counters
            NSLog("VR4Mac: perf %.1f fps, render %.1f ms, encode %.1f ms, latency %@, encoder skips %d in 5 s", Double(p.frames) / d, p.renders > 0 ? Double(p.renderNs) / Double(p.renders) / 1e6 : -1.0, enc ?? -1.0, "\(headsetStatus["latency_ms"] ?? "-")", loggedSkips)
            loggedSkips = 0
        }
        guard settings.bool("perf_hud") else { hudPanel = nil; return }
        var top = String(format: "%.0f fps", Double(p.frames) / d)
        if p.renders > 0 { top += String(format: "   render %.1f ms", Double(p.renderNs) / Double(p.renders) / 1e6) }
        if let enc { top += String(format: "   encode %.1f ms", enc) }
        var lines: [(String, CGColor, Bool)] = [(top, Engine.white, true),
            (String(format: "Stream %.0f Mbps%@  ·  %@  ·  %dx%d", Double(p.videoBytes) * 8 / d / 1e6, settings["bitrate"] == "Auto" ? " (auto \(autoMbps))" : "", useHEVC ? "HEVC" : "H.264", eyeW * 2, eyeH), Engine.grey, false)]
        let s = headsetStatus
        if let f = s["decode_fps"] as? Double {
            let lat = (s["latency_ms"] as? Double).map { String(format: "%.0f ms", $0) } ?? "–"
            lines.append((String(format: "Headset %.0f fps  ·  latency %@  ·  dropped %d", f, lat, s["dropped"] as? Int ?? 0), Engine.grey, false))
        }
        if let b = s["battery"] as? Int {
            lines.append(("Battery \(b)%" + (s["charging"] as? Bool == true ? ", charging" : ""), b <= 15 ? CGColor(srgbRed: 1, green: 0.42, blue: 0.4, alpha: 1) : Engine.grey, false))
        }
        hudPanel = Compositor.overlayPanel(lines, ppm: ppm, textHeight: 0.016)
    }

    /// A system notification: the menu's toast and history, plus a head-locked toast on the stream while the menu is closed.
    private func notify(_ s: String, thumb: CGImage? = nil) {
        if let thumb { rq.async { [self] in toastThumb = thumb } }
        dq.async { [self] in dash.note(s, 3); requestDraw() }
    }

    /// Overlays for the next frame: HUD upper left, toast below the centre of view.
    private func overlays() -> [Compositor.Overlay] {
        var items: [Compositor.Overlay] = []
        if let h = hudPanel { items.append((h, SIMD3(-0.28, 0.2, -1))) }
        if let (c, until) = toastPanel { if CACurrentMediaTime() < until { items.append((c, SIMD3(0, -0.24, -1))) } else { toastPanel = nil } }
        return items
    }

    // MARK: capture (rq): screenshots of the headset view to ~/Pictures/MacVR
    private var shotPending = false
    /// Saves the next frame sent to the headset (before overlays): the left eye, as PNG.
    private func takeScreenshot() { shotPending = true }
    private func saveShot(_ pb: CVPixelBuffer) {
        guard let img = Engine.leftEye(pb) else { return }
        shutter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = Engine.captureURL("png")
            let ok = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil).map { d in CGImageDestinationAddImage(d, img, nil); return CGImageDestinationFinalize(d) } ?? false
            NSLog("VR4Mac: screenshot %@ %@", ok ? "saved to" : "failed:", url.path)
            self?.rq.async { self?.notify(ok ? "Screenshot saved to Pictures › MacVR" : "Couldn't save the screenshot", thumb: ok ? img : nil) }
        }
    }
    /// The left eye of a side-by-side frame (opaque).
    static func leftEye(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb) / 2, h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb), w > 0, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), let dst = c.data else { return nil }
        for y in 0..<h { memcpy(dst + y * c.bytesPerRow, base + y * rb, w * 4) }
        return c.makeImage()
    }
    /// ~/Pictures/MacVR/MacVR 2026-10-02 at 14.21.33.<ext> (under MACVR_HOME in tests).
    static func captureURL(_ ext: String) -> URL {
        let dir = (macvrHome?.appendingPathComponent("Pictures") ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]).appendingPathComponent("MacVR")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = dir.appendingPathComponent("MacVR \(f.string(from: Date())).\(ext)"), n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent("MacVR \(f.string(from: Date())) \(n).\(ext)"); n += 1 }
        return url
    }
    // MARK: Mac windows in VR (rq): pick a Mac window, it floats in VR; point and pull the trigger to click it, grip to
    // right-click, stick up/down to scroll, left/right to resize; its bar moves it (both hands on it resize), pins it
    // (stays with the menu closed), opens the keyboard for it, or closes it.
    private var macWindows: [CGWindowID: MacWindow] = [:], windowIcons: [CGWindowID: NSImage] = [:]
    private var winHold: [(id: CGWindowID, part: MacWindows.BarPart?)?] = [nil, nil]   // trigger held on a window: content (nil) or its bar
    private var winHover: [CGWindowID?] = [nil, nil], barHover: [CGWindowID: MacWindows.BarPart] = [:], barKey: [CGWindowID: String] = [:]
    private var pickerEntries: [MacWindows.Entry] = [], pickerHover: Int?, windowCheck: CFTimeInterval = 0, focusWindow: CGWindowID?
    private var twoHand: (id: CGWindowID, dist0: Float, scale0: Float)?

    /// The picker lists the Mac's open windows (with thumbnails) in front of the menu.
    private func openPicker() {
        Task { [weak self] in
            let e = await MacWindows.list()
            self?.rq.async { [weak self] in
                guard let self else { return }
                pickerEntries = e; pickerHover = nil
                if !dashVisible { setMenu(true) }
                comp.showPicker(MacWindows.pickerImage(e, hover: nil), head: lastTrack?.head)
                UISounds.shared.play("open")
            }
        }
    }
    private func openWindow(_ e: MacWindows.Entry) {
        comp.showPicker(nil, head: nil)
        guard let sw = e.window else { return }
        let id = sw.windowID
        guard macWindows[id] == nil else { focusWindow = id; return }
        guard let head = lastTrack?.head else { return }
        let w = MacWindow(sw); w.start(sw)
        macWindows[id] = w; windowIcons[id] = e.icon; focusWindow = id
        comp.addWindow(id, width: min(1.3, max(0.55, Float(sw.frame.width) / 1100)), head: head)
        UISounds.shared.play("open")
        if !DesktopInput.shared.trusted { dq.async { [self] in dash.note("To click and type in Mac windows, allow VR4Mac under Privacy & Security > Accessibility", 5); requestDraw() } }
    }
    private func closeWindow(_ id: CGWindowID) {
        macWindows.removeValue(forKey: id)?.stop(); windowIcons[id] = nil; barKey[id] = nil; barHover[id] = nil
        comp.removeWindow(id)
        for i in 0..<2 where winHold[i]?.id == id { winHold[i] = nil; DesktopInput.shared.releaseAll() }
        if twoHand?.id == id { twoHand = nil }
        if focusWindow == id { focusWindow = nil; dq.async { [self] in if dash.macKeyboard { dash.macKeyboard = false; requestDraw() } } }
        UISounds.shared.play("close")
    }

    /// Lasers on Mac windows and the picker. Returns the hands that are busy with them (the menu's lasers skip those).
    private func macWindowInput(_ t: VR4Tracking, _ hs: [VR4Hand], _ valid: [Bool], _ trig: [Bool], _ grip: [Bool], _ rays: inout [Float?]) -> [Bool] {
        var mine = [false, false]
        guard !teleportAiming, !macWindows.isEmpty || comp.pickerShown, dashVisible || !gameActive else { return mine }   // in a game they're out of sight
        let input = DesktopInput.shared
        if let th = twoHand {   // both hands on one window: the gap between them scales it
            if valid[0] && valid[1] && trig[0] && trig[1] {
                let d = simd_distance(SIMD3(hs[0].aim.px, hs[0].aim.py, hs[0].aim.pz), SIMD3(hs[1].aim.px, hs[1].aim.py, hs[1].aim.pz))
                comp.setWindowScale(th.id, th.scale0 * d / max(0.05, th.dist0))
                return [true, true]
            }
            twoHand = nil; winHold = [nil, nil]; comp.endWindowMove()
        }
        for i in 0..<2 where valid[i] {
            let aim = hs[i].aim, pressed = trig[i] && !prevTrigger[i]
            if let h = winHold[i] {   // a click-drag or a move keeps the hand until the trigger is let go
                mine[i] = true
                if !trig[i] {
                    if h.part == nil { input.button(false, down: false) } else if h.part == .grab { comp.endWindowMove(); UISounds.shared.play("drop") }
                    winHold[i] = nil; continue
                }
                if h.part == .grab {
                    let sy = hs[i].stick_y
                    comp.updateWindowMove(aim, head: t.head, push: abs(sy) > 0.6 ? (sy - 0.6 * (sy > 0 ? 1 : -1)) * 0.03 : 0)
                } else if h.part == nil, let w = macWindows[h.id], let hit = comp.hitWindow(aim, only: h.id), !hit.bar {
                    input.move(to: w.point(hit.uv)); rays[i] = hit.dist
                }
                continue
            }
            if let ph = comp.hitPicker(aim) {
                mine[i] = true; rays[i] = ph.dist
                let k = MacWindows.pick(ph.uv, count: pickerEntries.count)
                if k != pickerHover { pickerHover = k; comp.showPicker(MacWindows.pickerImage(pickerEntries, hover: k), head: nil); if k != nil { haptic(i, 0.2, 0.012); UISounds.shared.play("hover") } }
                if pressed, let k {
                    haptic(i, 0.5, 0.02)
                    if k < 0 { comp.showPicker(nil, head: nil); UISounds.shared.play("close") } else { openWindow(pickerEntries[k]) }
                }
                continue
            }
            guard let wh = comp.hitWindow(aim) else { if winHover[i] != nil { winHover[i] = nil }; continue }
            if dashVisible, let d = comp.hit(aim, solid: { self.dash.solid($0, slot: $1) }), d.dist < wh.dist { continue }   // the menu is in front
            mine[i] = true; rays[i] = wh.dist
            if winHover[i] != wh.id { winHover[i] = wh.id; haptic(i, 0.2, 0.012) }
            guard let w = macWindows[wh.id] else { continue }
            if wh.bar {
                let part = MacWindows.barPart(wh.uv.x)
                barHover[wh.id] = part
                guard pressed else { continue }
                haptic(i, 0.5, 0.02); focusWindow = wh.id
                if let other = winHold[1 - i], other.id == wh.id, other.part == .grab {   // second hand on the same window: resize
                    let d = simd_distance(SIMD3(hs[0].aim.px, hs[0].aim.py, hs[0].aim.pz), SIMD3(hs[1].aim.px, hs[1].aim.py, hs[1].aim.pz))
                    twoHand = (wh.id, d, comp.windowScale(wh.id)); UISounds.shared.play("grab"); continue
                }
                switch part {
                case .close: closeWindow(wh.id)
                case .pin:
                    let on = !(comp.windowPanels[wh.id]?.pinned ?? false); comp.setWindowPinned(wh.id, on)
                    UISounds.shared.play(on ? "on" : "off")
                    notify(on ? "Pinned: \(w.app) stays when the menu closes" : "Unpinned: \(w.app) hides with the menu")
                case .keyboard:
                    w.raise(); if !dashVisible { setMenu(true) }
                    dq.async { [self] in dash.macKeyboard.toggle(); UISounds.shared.play(dash.macKeyboard ? "open" : "back"); requestDraw() }
                case .grab: winHold[i] = (wh.id, .grab); comp.beginWindowMove(wh.id, aim, dist: wh.dist); UISounds.shared.play("grab")
                }
                continue
            }
            barHover[wh.id] = nil
            // the window itself: hover moves the Mac pointer there, the trigger clicks and drags, grip right-clicks
            guard input.trusted else { continue }
            if winHold[1 - i] == nil { input.move(to: w.point(wh.uv)) }
            if pressed {
                if focusWindow != wh.id || !(NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid) { w.raise() }
                focusWindow = wh.id; input.move(to: w.point(wh.uv)); input.button(false, down: true); winHold[i] = (wh.id, nil); haptic(i, 0.5, 0.02)
            }
            if grip[i] && !prevGrip[i] { w.raise(); input.move(to: w.point(wh.uv)); input.button(true, down: true); input.button(true, down: false); haptic(i, 0.4, 0.02) }
            if abs(hs[i].stick_y) > 0.2 { input.scroll(dx: 0, dy: Int32((hs[i].stick_y * 18).rounded())) }
            if abs(hs[i].stick_x) > 0.5 { comp.scaleWindow(wh.id, by: 1 + hs[i].stick_x * 0.012) }
        }
        return mine
    }
    /// Per frame: new captures and bar states to the panels; once a second follow moves/renames on the Mac and drop closed windows.
    private func updateMacWindows() {
        guard !macWindows.isEmpty else { comp.showWindows(menu: dashVisible, focus: nil); return }
        let now = CACurrentMediaTime(), check = now - windowCheck > 1
        if check { windowCheck = now }
        for (id, w) in macWindows {
            if check && !w.refresh() { notify("\(w.app) window closed"); closeWindow(id); continue }
            let hover = winHover.contains(id) ? barHover[id] : nil, pinned = comp.windowPanels[id]?.pinned ?? false
            let key = "\(w.title)|\(pinned)|\(focusWindow == id)|\(String(describing: hover))"
            var bar: CGImage?
            if barKey[id] != key { barKey[id] = key; bar = MacWindows.barImage(app: w.app, title: w.title, icon: windowIcons[id], pinned: pinned, focused: focusWindow == id, hover: hover) }
            comp.setWindow(id, w.latest, bar: bar)
        }
        comp.showWindows(menu: dashVisible, focus: focusWindow)
    }

    /// Camera shutter for the headset: two short decaying noise clicks (mirror slap, then shutter).
    private func shutter() {
        guard audioEnabled else { return }
        let n = 48_000 * 15 / 100
        if uiQueue.count < n * 2 { uiQueue += [Int32](repeating: 0, count: n * 2 - uiQueue.count) }
        var seed: UInt32 = 0x9E37
        for i in 0..<n {
            let t = Double(i) / 48_000, env = exp(-t * 110) + (t > 0.07 ? 0.8 * exp(-(t - 0.07) * 140) : 0)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let s = Int32(Double(Int32(bitPattern: seed) >> 16) * env * 0.45)
            uiQueue[2 * i] += s; uiQueue[2 * i + 1] += s
        }
    }

    /// A stand-in Mac screen for offline renders: a warm sunset card with a title (Metal-compatible, like captures).
    static func testCard(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let cols = [CGColor(srgbRed: 0.98, green: 0.55, blue: 0.2, alpha: 1), CGColor(srgbRed: 0.85, green: 0.25, blue: 0.35, alpha: 1), CGColor(srgbRed: 0.25, green: 0.12, blue: 0.4, alpha: 1)]
        c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: cols as CFArray, locations: [0, 0.55, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        c.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.5, alpha: 1)); c.fillEllipse(in: CGRect(x: w / 2 - h / 8, y: h / 5, width: h / 4, height: h / 4))
        Compositor.draw("MacVR Theater", in: c, at: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) * 0.68), size: CGFloat(h) / 9, bold: true, align: 0.5)
        return pb
    }

    #if MACVR_DEV   // offline renders and the encoder self-test: developer builds only
    // MARK: self-test: render one frame with a fake headset pose, save PNG, encode, check NAL types
    func snapshot(to path: String) {
        let hevc = ProcessInfo.processInfo.environment["VR4_HEVC"] == "1"
        let readme = ProcessInfo.processInfo.environment["VR4_README"] == "1"   // one wide eye, no controller
        let eye = (ProcessInfo.processInfo.environment["VR4_EYE"] ?? "1024x1024").split(separator: "x").compactMap { Int($0) }   // e.g. 1216x1344 (Quest 2)
        hello(["eye_w": readme ? Int(ProcessInfo.processInfo.environment["VR4_EYE_W"] ?? "1920")! : eye[0], "eye_h": readme ? Int(ProcessInfo.processInfo.environment["VR4_EYE_W"] ?? "1920")! * (ProcessInfo.processInfo.environment["VR4_WIDE"] == "1" ? 9 : 21) / (ProcessInfo.processInfo.environment["VR4_WIDE"] == "1" ? 16 : 32) : eye[1], "device": "Test", "codecs": hevc ? ["hevc", "h264"] : ["h264"]])
        let wide = ProcessInfo.processInfo.environment["VR4_WIDE"] == "1"   // video framing: smaller UI, room for captions
        let fov = wide ? VR4Fov(left: -0.98, right: 0.98, up: 0.62, down: -0.72) : readme ? VR4Fov(left: -0.82, right: 0.82, up: 0.45, down: -0.75) : VR4Fov(left: -0.8, right: 0.8, up: 0.8, down: -0.8)
        func pose(_ x: Float, _ y: Float, _ z: Float) -> VR4Pose { VR4Pose(px: x, py: y, pz: z, qx: 0, qy: 0, qz: 0, qw: 1) }
        let aimDown = simd_quatf(angle: Float(ProcessInfo.processInfo.environment["VR4_AIM_PITCH"] ?? "-0.25") ?? -0.25, axis: SIMD3(1, 0, 0))   // VR4_AIM_PITCH: radians, + = up
        var hand = VR4Hand(flags: readme ? 0 : 3, buttons: 0, aim: pose(0.2, 1.3, -0.3), grip: pose(0.2, 1.3, -0.3), trigger: 0, squeeze: 0, stick_x: 0, stick_y: 0)
        hand.aim.qx = aimDown.imag.x; hand.aim.qw = aimDown.real
        if let v = ProcessInfo.processInfo.environment["VR4_HAND"]?.split(separator: ",").compactMap({ Float($0) }), v.count == 3 {   // grip position
            hand.grip = pose(v[0], v[1], v[2]); hand.aim = pose(v[0], v[1], v[2]); hand.aim.qx = aimDown.imag.x; hand.aim.qw = aimDown.real
        }
        hand.stick_y = Float(ProcessInfo.processInfo.environment["VR4_TELEPORT"] ?? "0") ?? 0
        hand.trigger = Float(ProcessInfo.processInfo.environment["VR4_TRIGGER"] ?? "0") ?? 0   // cursor press states
        let pitch = simd_quatf(angle: Float(ProcessInfo.processInfo.environment["VR4_PITCH"] ?? "0") ?? 0, axis: SIMD3(1, 0, 0))   // README renders
        func look(_ x: Float) -> VR4Pose { var p = pose(x, 1.6, 0); p.qx = pitch.imag.x; p.qw = pitch.real; return p }
        var t = VR4Tracking(time_ns: 1, head: look(0), eye: (VR4Eye(pose: look(-0.032), fov: fov), VR4Eye(pose: look(0.032), fov: fov)),
                            hand: (VR4Hand(), hand))
        // VR4_CAM="dx,dy,dz,yaw": move only the eyes (the menu stays placed at the head): camera moves for video renders
        if let c = ProcessInfo.processInfo.environment["VR4_CAM"]?.split(separator: ",").compactMap({ Float($0) }), c.count == 4 {
            let q = simd_quatf(angle: c[3], axis: SIMD3(0, 1, 0)) * pitch
            func cam(_ x: Float) -> VR4Pose { let o = q.act(SIMD3(x, 0, 0)); return VR4Pose(px: o.x + c[0], py: 1.6 + c[1], pz: o.z + c[2], qx: q.imag.x, qy: q.imag.y, qz: q.imag.z, qw: q.real) }
            t.eye = (VR4Eye(pose: cam(-0.032), fov: fov), VR4Eye(pose: cam(0.032), fov: fov))
        }
        if ProcessInfo.processInfo.environment["VR4_TRACKED"] == "1" {   // a tracked right hand, fingers forward, in front of the menu
            let q = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            let j = HandModel.restJoints(left: false).map { p -> VR4Pose in let w = q.act(p) + SIMD3(0.12, 1.35, -0.38); return VR4Pose(px: w.x, py: w.y, pz: w.z, qx: 0, qy: 0, qz: 0, qw: 1) }
            comp.joints = [nil, j]; t.hand.1 = HandGesture.hand(j, head: t.head, left: false, was: t.hand.1)
        }
        var nals: [UInt8] = []
        let done = DispatchSemaphore(value: 0)
        encoder.onFrame = { d, idr, _ in
            var i = 0
            while i + 4 < d.count { if d[i] == 0, d[i + 1] == 0, d[i + 2] == 0, d[i + 3] == 1 { nals.append(hevc ? (d[i + 4] >> 1) & 0x3f : d[i + 4] & 0x1f) }; i += 1 }
            done.signal()
        }
        let env = ProcessInfo.processInfo.environment
        // render-queue work on its own threads, like the app (rq.sync would run it here, on main, where SceneKit's implicit
        // transactions wait for a run loop and mix with the ones from the queue)
        func onRQ(_ body: @escaping () -> Void) { let s = DispatchSemaphore(value: 0); rq.async { body(); s.signal() }; s.wait() }
        if let s = env["VR4_STATUS"], let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { onRQ { [self] in status(j) } }   // headset VR4_STATUS
        if env["VR4_MENU"] == "0" { onRQ { [self] in lastTrack = t; setMenu(false) } }   // the menu closed (overlay toasts show)
        if env["VR4_SHOT"] == "1" { onRQ { [self] in takeScreenshot() } }               // saved from the first frame below
        if env["VR4_TEST_SCREEN"] == "1" { onRQ { [self] in testScreen = Engine.testCard(1920, 1080) } }
        if env["VR4_THEATER"] == "1" { onRQ { [self] in lastTrack = t; setTheater(true) } }
        if let tw = env["VR4_TEST_WINDOW"] { onRQ { [self] in   // a stand-in Mac window panel ("pinned": pinned)
            lastTrack = t; comp.addWindow(1, width: 0.9, head: t.head); comp.setWindowPinned(1, tw == "pinned")
            comp.setWindow(1, Engine.testCard(1600, 1000), bar: MacWindows.barImage(app: "Safari", title: "MacVR", icon: NSWorkspace.shared.icon(forFile: "/Applications/Safari.app"),
                                                                                      pinned: tw == "pinned", focused: true, hover: .pin))
        } }
        if env["VR4_PICKER"] == "1" { onRQ { [self] in   // the window picker with stand-in cards
            let apps = [("Safari", "Apple", "/Applications/Safari.app"), ("Notes", "Shopping list", "/System/Applications/Notes.app"),
                        ("Finder", "Downloads", "/System/Library/CoreServices/Finder.app"), ("Terminal", "zsh", "/System/Applications/Utilities/Terminal.app")]
            pickerEntries = apps.map { MacWindows.Entry(window: nil, app: $0.0, title: $0.1, icon: NSWorkspace.shared.icon(forFile: $0.2), thumb: Compositor.loadingCard($0.0, art: nil)) }
            comp.showPicker(MacWindows.pickerImage(pickerEntries, hover: 1), head: t.head)
        } }
        if let name = env["VR4_SPLASH"] { onRQ { [self] in lastTrack = t; comp.setLoading(name, head: t.head); setMenu(false) } }   // game loading space
        onRQ { [self] in frame(t) }
        dq.sync {}; dq.sync {}   // let the dashboard draw + upload finish
        if let st = ProcessInfo.processInfo.environment["VR4_TOUR_STEP"].flatMap({ Int($0) }) {   // snapshot a tour step mid-animation
            dq.sync { dash.testTourStep(st) }; dq.sync {}; dq.sync {}
            Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["VR4_SNAP_WAIT"] ?? "2.2") ?? 2.2)
        }
        if ProcessInfo.processInfo.environment["VR4_GAMES"] == "1" { games.scan(); RunLoop.main.run(until: Date() + 5); dq.sync {} }   // video renders: real library
        if let v = ProcessInfo.processInfo.environment["VR4_VIEW"] { dq.sync { dash.view = v }; requestDraw(); Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["VR4_SNAP_WAIT"] ?? "0.6") ?? 0.6) }   // README renders
        if let k = ProcessInfo.processInfo.environment["VR4_CLICK"]?.split(separator: ",").compactMap({ Double($0) }), k.count == 2 {   // canvas px
            dq.sync { dash.click(CGPoint(x: k[0] / Double(Dashboard.W), y: k[1] / Double(Dashboard.H))); dash.draw() }
        }
        if let n = ProcessInfo.processInfo.environment["VR4_SCROLL"].flatMap({ Int($0) }) {   // stick-scroll steps over the window
            dq.sync { for _ in 0..<n { _ = dash.scroll(-1, at: CGPoint(x: 0.5, y: 0.25)) }; dash.draw() }
        }
        if let h = ProcessInfo.processInfo.environment["VR4_HOVER"]?.split(separator: ",").compactMap({ Double($0) }), h.count == 2 {   // canvas px
            dq.sync { _ = dash.pointer(CGPoint(x: h[0] / Double(Dashboard.W), y: h[1] / Double(Dashboard.H))) }; requestDraw()
        }
        Thread.sleep(forTimeInterval: 0.4)   // let window pop-in animations settle
        if let n = ProcessInfo.processInfo.environment["VR4_NOTE"] {   // video renders: a notification card, settled ("text|kind")
            let parts = n.split(separator: "|").map(String.init)
            dq.sync { dash.note(parts[0], 60, kind: parts.count > 1 ? parts[1] : nil) }; Thread.sleep(forTimeInterval: 0.6); requestDraw(); dq.sync {}; dq.sync {}
        }
        if let p = ProcessInfo.processInfo.environment["VR4_DASH_PNG"] {   // video renders: the raw dashboard canvas with alpha
            dq.sync { dash.draw(); if let img = dash.context.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p)) } }
            return
        }
        dq.sync {}; dq.sync {}
        // input again now the scene has rendered (SceneKit hit tests need that): laser hits, cursor, hover. Not with VR4_HOVER
        if env["VR4_HOVER"] == nil { onRQ { [self] in frame(t) }; dq.sync {}; dq.sync {} }
        onRQ { [self] in}   // finish selected view's texture and dock/keyboard updates before capture
        if let e = env["VR4_ENV2"] { onRQ { [self] in comp.setEnvironment(e) } }   // capture half way through the crossfade to it
        Thread.sleep(forTimeInterval: 0.4)
        onRQ { [self] in
            guard let pb = comp.render(t, eyeW: eyeW, eyeH: eyeH) else { print("render failed"); exit(1) }
            perf.t = 0; updateHUD()   // system overlays, as `send` stamps them
            comp.stamp(pb, eyes: [t.eye.0.pose, t.eye.1.pose], fovs: [t.eye.0.fov, t.eye.1.fov], overlays())
            let full = CIImage(cvPixelBuffer: pb), ci = readme ? full.cropped(to: CGRect(x: 0, y: 0, width: full.extent.width / 2, height: full.extent.height)) : full
            let rep = NSBitmapImageRep(ciImage: ci)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            if let n = ProcessInfo.processInfo.environment["VR4_BENCH"].flatMap({ Int($0) }), n > 0 {   // render cost per stereo frame
                var ms: [Double] = []
                for _ in 0..<n { let t0 = CACurrentMediaTime(); _ = comp.render(t, eyeW: eyeW, eyeH: eyeH); ms.append((CACurrentMediaTime() - t0) * 1000) }
                ms.sort(); print(String(format: "render %dx%d per eye: median %.2f ms, p90 %.2f ms", eyeW, eyeH, ms[n / 2], ms[n * 9 / 10]))
            }
        }
        _ = done.wait(timeout: .now() + 5)
        print("VR4Shm size \(MemoryLayout<VR4Shm>.size), VR4Tracking \(MemoryLayout<VR4Tracking>.size), NAL types in first frame: \(Set(nals).sorted())")
        assert(MemoryLayout<VR4Tracking>.size == 284)
        if hevc { assert(nals.first == 32 && nals.contains(33) && nals.contains(34) && nals.contains { $0 == 19 || $0 == 20 }, "HEVC IDR must start with VPS, SPS, PPS") }
        else { assert(nals.first == 7 && nals.contains(8) && nals.contains(5), "IDR must start with SPS, PPS") }
    }
    #endif
}
