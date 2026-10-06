import Foundation
import SceneKit
import Metal
import CoreVideo
import ScreenCaptureKit
import VideoToolbox
import Accelerate

/// Renders the VR home + dashboard + controllers for both eyes (side by side) into a CVPixelBuffer.
final class Compositor {
    let device = MTLCreateSystemDefaultDevice()!
    private lazy var cq = device.makeCommandQueue()!
    private let renderer: SCNRenderer
    let scene = SCNScene()
    private let eyes = [SCNNode(), SCNNode()]
    let dash = SCNNode()
    /// The window (with its grab bar) and the dock (with its grab bar) are separate panels cut from the one menu texture,
    /// each movable on its own. `winContent` is what animates when a window opens.
    private let win = SCNNode(), winContent = SCNNode(), panel = SCNNode(), screen = SCNNode(), dockNode = SCNNode(), dockPanel = SCNNode()
    private let kbNode = SCNNode(), kbPanel = SCNNode()   // pop-up keyboard, floats below the Universal Menu while typing
    private let grid: SCNNode
    enum Part { case window, dock, keyboard }
    private static let split = Float(Dashboard.SPLIT) / Float(Dashboard.H)   // canvas v where the dock part starts
    private static let split2 = Float(Dashboard.SPLIT2) / Float(Dashboard.H) // canvas v where the keyboard part starts
    private var hands: [(grip: SCNNode, aim: SCNNode, laser: SCNNode, dot: SCNNode)] = []
    private var rigs: [ControllerRig] = [], handModels: [HandModel?] = []
    /// Connected headset generation (default Quest 2). Engine should call
    /// setControllerModel(HeadsetModel.detect(device:)) on HELLO.
    private var controllerModel: HeadsetModel = .quest2
    /// Swap controller geometry per headset generation. Additive only:
    /// grip nodes (positions driven by updateHands) are preserved.
    func setControllerModel(_ m: HeadsetModel) {
        guard m != controllerModel else { return }
        controllerModel = m
        for (i, h) in hands.enumerated() {
            h.grip.childNodes.forEach { $0.removeFromParentNode() }
            attachController(h.grip, hand: i)
        }
    }
    /// Hand tuner: rebuild both hands (placement changed) / which controller mesh is showing.
    func rebuildHands() {
        for (i, h) in hands.enumerated() { h.grip.childNodes.forEach { $0.removeFromParentNode() }; attachController(h.grip, hand: i) }
    }
    var shownControllerModel: HeadsetModel { controllerModel.controllerMesh }
    /// Hand tuner: play a pose on the in-home hands instead of the live controller input (nil = live).
    var demoPose: String?
    private func demo(_ h: VR4Hand, hand: Int) -> VR4Hand { demoPose.map { Compositor.demoInput($0, hand: hand, base: h) } ?? h }
    /// Controller input that plays a named pose (time-animated for pull / stick circle / squeeze / play-all).
    static func demoInput(_ pose: String, hand: Int, base: VR4Hand = VR4Hand()) -> VR4Hand {
        var name = pose
        var d = base
        let t = CACurrentMediaTime()
        let all = ["idle", "index_touch", "trigger_pull", "thumbrest", "stick", "stick_circle", "face_low", "face_high", "grip", "poke"]
        if name == "cycle" { name = all[Int(t / 1.6) % all.count] }
        d.buttons = 0; d.trigger = 0; d.squeeze = 0; d.stick_x = 0; d.stick_y = 0
        let low = hand == 0 ? VR4_BTN_X : VR4_BTN_A, high = hand == 0 ? VR4_BTN_Y : VR4_BTN_B
        switch name {
        case "index_touch": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH)
        case "trigger_pull": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH); d.trigger = Float(0.5 + 0.5 * sin(t * 3))
        case "thumbrest": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_THUMB_TOUCH)
        case "stick": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_STICK_TOUCH)
        case "stick_circle": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_STICK_TOUCH); d.stick_x = Float(cos(t * 2)); d.stick_y = Float(sin(t * 2))
        case "face_low": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | low)
        case "face_high": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | high)
        case "grip": d.buttons = UInt32(VR4_BTN_TRIGGER_TOUCH | VR4_BTN_THUMB_TOUCH); d.squeeze = Float(0.5 + 0.5 * sin(t * 3))
        default: break
        }
        return d
    }
    private(set) var radius: Float = 0
    private var cache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool?, poolSize = (0, 0)
    private var depth: MTLTexture?

    init() {
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.usesReverseZ = false          // we supply our own (OpenXR-style) projection
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)

        scene.background.contents = Compositor.sky()
        let plane = SCNPlane(width: 60, height: 60)
        let gm = plane.firstMaterial!
        gm.diffuse.contents = Compositor.gridTile(); gm.diffuse.wrapS = .repeat; gm.diffuse.wrapT = .repeat
        gm.diffuse.contentsTransform = SCNMatrix4MakeScale(60, 60, 1)
        gm.lightingModel = .constant; gm.isDoubleSided = true; gm.writesToDepthBuffer = false
        grid = SCNNode(geometry: plane); grid.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(grid)

        for e in eyes { e.camera = SCNCamera(); scene.rootNode.addChildNode(e) }
        // light for the physically based controller meshes (menu, grid and sky are unlit)
        scene.lightingEnvironment.contents = Compositor.studio(); scene.lightingEnvironment.intensity = 1.6
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, 0.4, 0); scene.rootNode.addChildNode(key)
        dash.addChildNode(win); win.addChildNode(winContent); winContent.addChildNode(panel); winContent.addChildNode(screen)
        dash.addChildNode(dockNode); dockNode.addChildNode(dockPanel)
        sides.forEach { dash.addChildNode($0); $0.isHidden = true }
        dash.addChildNode(kbNode); kbNode.addChildNode(kbPanel); kbNode.isHidden = true
        scene.rootNode.addChildNode(dash)

        for i in 0..<2 {
            let grip = SCNNode(), aim = SCNNode()
            attachController(grip, hand: i)
            let laser = SCNNode(geometry: SCNCylinder(radius: 0.0015, height: 1))
            laser.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0); laser.eulerAngles.x = -.pi / 2
            laser.geometry?.firstMaterial?.diffuse.contents = NSColor(red: 0.4, green: 0.75, blue: 0.96, alpha: 1)
            laser.geometry?.firstMaterial?.lightingModel = .constant
            laser.geometry?.firstMaterial?.blendMode = .alpha
            laser.geometry?.firstMaterial?.transparencyMode = .aOne
            laser.geometry?.firstMaterial?.writesToDepthBuffer = false
            laser.geometry?.firstMaterial?.readsFromDepthBuffer = true
            laser.renderingOrder = 199
            laser.geometry?.firstMaterial?.shaderModifiers = [
                // fade by distance from the hand (metres), not by beam length: a beam cut short by nearby UI stays faded
                .geometry: "#pragma arguments\nfloat rayLen;\n#pragma varyings\nfloat rayMeters;\n#pragma body\nout.rayMeters = (_geometry.position.y + 0.5) * rayLen;",
                .fragment: "#pragma transparent\n#pragma body\n_output.color.a *= 1.0 - smoothstep(0.06, 0.26, in.rayMeters);"
            ]
            aim.addChildNode(laser)
            let dot = Compositor.cursor()
            [grip, aim, dot].forEach(scene.rootNode.addChildNode)
            hands.append((grip, aim, laser, dot))
        }
    }
    /// Controller mesh plus the translucent hand holding it (rigs index by hand).
    private func attachController(_ grip: SCNNode, hand i: Int) {
        let ctl = ControllerModels.build(controllerModel, hand: i), hm = HandModel(hand: i, model: controllerModel, controller: ctl)
        // Draw held controllers after shell panels and before translucent hands.
        ctl.renderingOrder = 140
        ctl.enumerateChildNodes { node, _ in node.renderingOrder = 140 }
        grip.addChildNode(ctl)
        if let hm { grip.addChildNode(hm.node) }
        if rigs.count > i { rigs[i] = ControllerRig(ctl, hand: i); handModels[i] = hm } else { rigs.append(ControllerRig(ctl, hand: i)); handModels.append(hm) }
    }

    // MARK: scene content
    static func sky() -> CGImage {  // 2:1 equirectangular vertical gradient (purple void like SteamVR)
        let w = 512, h = 256
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cols = [CGColor(srgbRed: 0.1, green: 0.05, blue: 0.22, alpha: 1), CGColor(srgbRed: 0.42, green: 0.26, blue: 0.72, alpha: 1),
                    CGColor(srgbRed: 0.05, green: 0.03, blue: 0.16, alpha: 1)]   // bottom, horizon, top (CG y-up)
        c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: cols as CFArray, locations: [0.3, 0.5, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return c.makeImage()!
    }
    /// Neutral studio environment (bright top, dim floor) used only as image-based light.
    static func studio() -> CGImage {
        let w = 256, h = 128
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cols = [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0.95, alpha: 1)]   // bottom, horizon, top
        c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: cols as CFArray, locations: [0, 0.5, 1])!, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return c.makeImage()!
    }
    static func gridTile() -> CGImage {
        let c = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setStrokeColor(CGColor(srgbRed: 0.64, green: 0.49, blue: 1, alpha: 0.35)); c.setLineWidth(2)
        c.stroke(CGRect(x: 0, y: 0, width: 64, height: 64))
        return c.makeImage()!
    }

    /// Plane of width w wrapped around a cylinder of radius r whose axis passes through the viewer; texture v=0 at top.
    /// Settings > Universal Menu > Curved UI. Off = flat panels.
    static var curved = true
    static func bent(w: Float, h: Float, r: Float, seg: Int = 64, v0: CGFloat = 0, v1: CGFloat = 1, curve: Bool? = nil) -> SCNGeometry {   // curve: override Curved UI
        var v: [SCNVector3] = [], t: [CGPoint] = [], idx: [Int32] = []; let curved = curve ?? Compositor.curved
        for i in 0...seg {
            let u = Float(i) / Float(seg), a = (u - 0.5) * w / r
            let x = curved ? CGFloat(r * sin(a)) : CGFloat((u - 0.5) * w), z = curved ? CGFloat(r - r * cos(a)) : 0
            v += [SCNVector3(x, CGFloat(h / 2), z), SCNVector3(x, CGFloat(-h / 2), z)]
            t += [CGPoint(x: CGFloat(u), y: v0), CGPoint(x: CGFloat(u), y: v1)]
        }
        for i in 0..<Int32(seg) { let a = i * 2; idx += [a, a + 1, a + 2, a + 2, a + 1, a + 3] }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v), SCNGeometrySource(textureCoordinates: t)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.firstMaterial?.lightingModel = .constant; g.firstMaterial?.isDoubleSided = true
        return g
    }

    /// Meters per dashboard-canvas pixel at the current radius (constant angular size).
    var metersPerPx: Float { 2.2 / Float(Dashboard.W) * radius / 1.3 }   // ~85° wide, like SteamVR

    func setCurved(_ on: Bool) {
        guard on != Compositor.curved else { return }
        Compositor.curved = on
        let r = radius; radius = 0; setRadius(r)             // rebuild every panel
        theater.geometry = nil; theaterAspect = 0
    }
    func setRadius(_ r: Float) {
        guard r != radius else { return }
        radius = r
        let L = layout   // each panel bends around the viewer at its own distance (its node is scaled, so bend at distance / scale)
        bend = [ObjectIdentifier(panel): r / L.win, ObjectIdentifier(dockPanel): (r - L.dockZ) / L.dock, ObjectIdentifier(kbPanel): (r - L.kbZ) / L.kb]
        for n in sides { bend[ObjectIdentifier(n)] = r / L.win }
        built = [:]
        screen.renderingOrder = 11
        resetLayout()
    }
    private var built: [ObjectIdentifier: Float] = [:]   // bend each panel's geometry was built with
    /// (Re)builds the panel meshes for the current `bend` radii (only those that changed), keeping their textures.
    private func buildPanels() {
        let m = metersPerPx, w = Float(Dashboard.W) * m, h = Float(Dashboard.H) * m, sp = Compositor.split, sp2 = Compositor.split2
        let parts: [(SCNNode, Float, CGFloat, CGFloat)] = [(panel, h * sp, 0, CGFloat(sp)), (dockPanel, h * (sp2 - sp), CGFloat(sp), CGFloat(sp2)),
                                                          (kbPanel, h * (1 - sp2), CGFloat(sp2), 1), (sides[0], h * sp, 0, 1), (sides[1], h * sp, 0, 1)]
        for (n, ph, v0, v1) in parts {
            let r = bend[ObjectIdentifier(n)] ?? radius
            guard built[ObjectIdentifier(n)] != r else { continue }
            built[ObjectIdentifier(n)] = r
            let old = n.geometry?.firstMaterial?.diffuse.contents
            n.geometry = Compositor.bent(w: w, h: ph, r: r, v0: v0, v1: v1)
            if let k = [sides[0], panel, sides[1]].firstIndex(where: { $0 === n }) { slotDim[k] = 1 }   // fresh material: undimmed
            guard let mat = n.geometry?.firstMaterial else { continue }   // the menu texture has transparent gaps around the window, bars and dock
            mat.diffuse.contents = old; mat.blendMode = .alpha; mat.writesToDepthBuffer = false
            mat.diffuse.mipFilter = .linear; mat.diffuse.maxAnisotropy = 16   // readable text when the panel is far/small
            n.renderingOrder = 10
        }
        if built[ObjectIdentifier(panel)] != screenBend { screen.geometry = nil }   // the desktop rebuilds on its next frame
    }
    private var screenBend: Float = 0
    /// Quest: turn a panel node (at its spot in dash space) so it faces your eyes, and bend it around them exactly.
    private func face(_ n: SCNNode, _ panel: SCNNode, scale: Float, extraTilt: Float = 0) {
        let v = headLocal - n.simdPosition
        n.simdEulerAngles = SIMD3(atan2(-v.y, v.z) + extraTilt, 0, 0)
        n.simdScale = SIMD3(repeating: scale)
        bend[ObjectIdentifier(panel)] = simd_length(v) / scale * 2.5   // a gentle Quest-style curve, not a wrap around the eyes
    }
    private var questLayout = true, compact = true
    private var bend: [ObjectIdentifier: Float] = [:]
    /// Panel scales and how much nearer than the window the dock / keyboard float.
    /// Quest + direct touch: compact, within reach. Quest + lasers: further, window large, dock tucked under it.
    private var layout: (win: Float, dock: Float, kb: Float, dockZ: Float, kbZ: Float) {
        !questLayout ? (0.78, 0.78, 0.62, 0.3, 0.55) : compact ? (0.6, 0.85, 0.6, 0.06, 0.3) : (0.66, 0.42, 0.45, 0.62, 0.8)   // lasers: window far, dock and keyboard near
    }
    /// quest: Horizon-style shell; compact: direct touch on (menu in reach) vs lasers (further away).
    func setLayout(quest: Bool, compact: Bool) {
        guard quest != questLayout || compact != self.compact else { return }
        questLayout = quest; self.compact = compact
        let r = radius; radius = 0; setRadius(r)   // rebuild the panels for the new layout
    }
    /// Window above, dock below, exactly as laid out on the canvas.
    private func resetLayout() {
        let m = metersPerPx
        win.simdTransform = matrix_identity_float4x4; dockNode.simdTransform = matrix_identity_float4x4; kbNode.simdTransform = matrix_identity_float4x4
        if questLayout {   // Horizon OS: the window with the dock right under it, about as wide
            win.simdPosition = SIMD3(0, 0.08, 0)
            let L = layout
            face(win, panel, scale: L.win)                    // ~48 deg wide, square on to your eyes
            for n in sides { bend[ObjectIdentifier(n)] = bend[ObjectIdentifier(panel)] }
            winHome = win.simdTransform
            let winBottom = 0.08 - L.win * Float(Dashboard.SPLIT) * m / 2
            dockNode.simdPosition = SIMD3(0, winBottom - 0.075 * radius / 0.95, L.dockZ)   // just below the window's grab bar, a touch closer
            face(dockNode, dockPanel, scale: L.dock)
            kbNode.simdPosition = SIMD3(0, winBottom - (compact ? 0.2 : 0.27) * radius / 0.95, L.kbZ)
            kbNode.simdEulerAngles = SIMD3(compact ? -0.5 : -0.6, 0, 0)   // compact: tilted toward the fingers for typing
            kbNode.simdScale = SIMD3(repeating: L.kb)
            buildPanels()
            layoutSides()
            return
        }
        win.simdPosition = SIMD3(0, 0.12, 0)
        win.simdScale = SIMD3(repeating: 0.78)               // Quest-sized window (~60° wide)
        // dock: chest height, a little closer, tilted up toward the eyes (dock art sits at canvas y ~1124 of its 990-1262 part)
        let winBottom = 0.12 - 0.78 * Float(Dashboard.SPLIT) * m / 2
        dockNode.simdPosition = SIMD3(0, winBottom - 0.2, 0.3)
        dockNode.simdEulerAngles = SIMD3(-0.35, 0, 0)
        dockNode.simdScale = SIMD3(repeating: 0.78)
        // keyboard: just below the dock and nearer the hands, tilted like a desk
        kbNode.simdPosition = SIMD3(0, winBottom - 0.52, 0.55)
        kbNode.simdEulerAngles = SIMD3(-0.7, 0, 0)
        kbNode.simdScale = SIMD3(repeating: 0.62)
        buildPanels()
    }
    func setDashboard(_ tex: MTLTexture?) {
        for n in [panel, dockPanel, kbPanel] { n.geometry?.firstMaterial?.diffuse.contents = tex }
    }
    // MARK: live 3D controller for the welcome tour
    // The real left-controller mesh floats in front of the tour window. On each step it turns and slides so the input
    // being taught faces you, the input fades in blue, then it presses itself in a loop (trigger/grip/buttons) or rocks
    // (thumbstick) until the step changes. Press poses come from the WebXR assets' *_pressed_min/max nodes.
    private let tourRoot = SCNNode()
    private var tourCtl: SCNNode?, tourModel: HeadsetModel?, tourPart = "", tourStart: CFTimeInterval = 0
    private var tourFrom = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), tourTo = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private var tourPanFrom = SIMD3<Float>(0, 0, 0), tourPanTo = SIMD3<Float>(0, 0, 0), tourCenter = SIMD3<Float>(0, 0, 0)
    private var tourMats: [SCNMaterial] = []
    private static let tourParts: [String: (mesh: [String], anim: String)] = [
        "trigger": (["trigger"], "xr_standard_trigger_pressed"), "grip": (["squeeze"], "xr_standard_squeeze_pressed"),
        "stick": (["thumbstick"], "xr_standard_thumbstick_yaxis_pressed"), "buttons": (["x_button", "y_button"], "x_button_pressed"),
    ]
    /// nil hides it. Call every dashboard redraw; it only animates when the step's part changes.
    func setTourController(_ model: HeadsetModel?, part: String?) {
        guard let model, let part else { tourRoot.isHidden = true; return }
        if tourRoot.parent == nil { winContent.addChildNode(tourRoot) }
        tourRoot.isHidden = false
        // stage: left part of the tour window (canvas box x 194..754, y 132..692; centred a bit high to clear the label), a little in front of the panel
        let m = metersPerPx, cx = (474 - Float(Dashboard.W) / 2) * m, cy = (Float(Dashboard.SPLIT) / 2 - 385) * m
        let z: Float = Compositor.curved ? radius - radius * cos(cx / radius) + 0.16 : 0.16
        tourRoot.simdPosition = SIMD3(Compositor.curved ? radius * sin(cx / radius) : cx, cy, z)
        tourRoot.simdEulerAngles = SIMD3(0, Compositor.curved ? -cx / radius : 0, 0)
        if tourModel != model {
            tourCtl?.removeFromParentNode()
            let n = ControllerModels.build(model, hand: 0)
            n.enumerateHierarchy { c, _ in   // private copies: tinting must not touch the hands' shared materials
                if let g = c.geometry?.copy() as? SCNGeometry { g.materials = g.materials.map { $0.copy() as! SCNMaterial }; c.geometry = g }
            }
            let (lo, hi) = n.boundingBox
            tourCenter = SIMD3(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z + hi.z) / 2)
            let size = simd_length(SIMD3(Float(hi.x - lo.x), Float(hi.y - lo.y), Float(hi.z - lo.z)))
            n.simdScale = SIMD3(repeating: 0.6 / max(size, 0.01))   // ~60 cm across on the stage
            n.enumerateHierarchy { c, _ in c.renderingOrder = 15 }   // after the window panel (10), or it paints over the controller
            tourRoot.addChildNode(n); tourCtl = n; tourModel = model; tourPart = "-"
        }
        guard part != tourPart, let n = tourCtl else { return }
        // new step: from the current pose, turn the part toward the viewer (+z) and slide it to the centre of the stage
        tourFrom = n.simdOrientation; tourPanFrom = n.simdPosition
        tourMats.forEach { $0.emission.contents = NSColor.black }
        tourMats = []
        // hand-picked viewpoints (model space, toward the camera) that show each input; a fixed "up" so it never rolls
        let views: [String: (dir: SIMD3<Float>, up: SIMD3<Float>)] = [
            "none": (SIMD3(0.7, -0.3, -0.6), SIMD3(0, 1, 0)), "trigger": (SIMD3(0.2, -0.65, -0.75), SIMD3(0, 1, 0)),
            "grip": (SIMD3(0.95, -0.15, -0.35), SIMD3(0, 1, 0)), "stick": (SIMD3(-0.35, 0.85, 0.45), SIMD3(0, 0, -1)),
            "buttons": (SIMD3(-0.35, 0.85, 0.45), SIMD3(0, 0, -1))]
        let v = views[part] ?? views["none"]!
        let f = simd_normalize(v.dir), r = simd_normalize(simd_cross(v.up, f)), u = simd_cross(f, r)
        let target = simd_quatf(simd_float3x3(columns: (r, u, f)).transpose)   // maps the viewpoint onto the viewer (+z)
        var focus = tourCenter
        if let p = Compositor.tourParts[part] {
            let nodes = p.mesh.compactMap { n.childNode(withName: $0, recursively: true) }
            if let first = nodes.first {
                let (a, b) = first.boundingBox
                focus = n.simdConvertPosition(first.simdConvertPosition(SIMD3(Float(a.x + b.x) / 2, Float(a.y + b.y) / 2, Float(a.z + b.z) / 2), to: nil), from: nil)
            }
            nodes.forEach { $0.enumerateHierarchy { c, _ in tourMats += c.geometry?.materials ?? [] } }
        }
        tourTo = target
        tourPanTo = -target.act((focus - tourCenter) * 0.5 + tourCenter) * n.simdScale.x
        tourPart = part; tourStart = CACurrentMediaTime()
    }
    private func animateTour() {
        guard !tourRoot.isHidden, let n = tourCtl else { return }
        let t = Float(CACurrentMediaTime() - tourStart)
        let e = min(1, t / 0.9), ease = e * e * (3 - 2 * e)       // 0.9 s pan
        n.simdOrientation = simd_slerp(tourFrom, tourTo, ease)
        n.simdPosition = tourPanFrom + (tourPanTo - tourPanFrom) * ease
        let glow = CGFloat(min(1, max(0, (t - 0.9) / 0.5)))       // then the highlight fades in
        tourMats.forEach { $0.emission.contents = NSColor(red: 0.08 * glow, green: 0.4 * glow, blue: 1.0 * glow, alpha: 1) }
        guard let anim = Compositor.tourParts[tourPart]?.anim,
              let v = n.childNode(withName: anim + "_value", recursively: true),
              let lo = n.childNode(withName: anim + "_min", recursively: true),
              let hi = n.childNode(withName: anim + "_max", recursively: true) else { return }
        // then it presses itself: 1.2 s cycle once the highlight is in (thumbstick: rocks between both ends)
        let phase = max(0, t - 1.4)
        var k = Float(0.5 - 0.5 * cos(Double(phase) * 2 * .pi / 1.2))
        if tourPart == "stick" { k = Float(0.5 + 0.5 * sin(Double(phase) * 2 * .pi / 1.6)) }
        v.simdOrientation = simd_slerp(lo.simdOrientation, hi.simdOrientation, k)
        v.simdPosition = lo.simdPosition + (hi.simdPosition - lo.simdPosition) * k
    }

    /// First-run tour: no Universal Menu.
    func setDockHidden(_ hidden: Bool) { dockNode.isHidden = hidden }
    func setWindowHidden(_ hidden: Bool) { win.isHidden = hidden }

    // MARK: space backdrop for the first-run tour; fades away to reveal the home environment
    private let space = SCNNode()
    private var spaceFade: (from: CGFloat, start: CFTimeInterval)?
    /// on: starfield all around; off (animated): it fades out over 3 s, showing the home environment behind it.
    func setSpace(_ on: Bool) {
        if space.geometry == nil {
            let g = SCNSphere(radius: 100); g.segmentCount = 96   // well inside the 300 m far plane, or the home leaks through
            let m = g.firstMaterial!; m.diffuse.contents = Compositor.starfield(); m.lightingModel = .constant
            m.cullMode = .front; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1); m.diffuse.wrapS = .repeat   // seen from inside
            space.geometry = g; space.renderingOrder = -150; space.isHidden = true
            scene.rootNode.addChildNode(space)
        }
        if on { spaceFade = nil; space.opacity = 1; space.isHidden = false }
        else if !space.isHidden && spaceFade == nil { spaceFade = (space.opacity, CACurrentMediaTime()) }
    }
    private func animateSpace() {
        guard let f = spaceFade else { return }
        let t = CGFloat(min(1, (CACurrentMediaTime() - f.start) / 3))
        space.opacity = f.from * (1 - t * t * (3 - 2 * t))   // smoothstep
        if t >= 1 { space.isHidden = true; spaceFade = nil }
    }

    // MARK: transitions: the old sky fades out over the new one (Spaces, theater, game loading); a veil fades home in
    /// Settings > Universal Menu > Reduce Motion: no fades, hops or glides; things just appear.
    var reduceMotion = false
    let skyFade = SCNNode()
    private let veil = SCNNode()
    private var skyFadeStart: CFTimeInterval = 0, veilStart: CFTimeInterval = 0, archShown: CGFloat = 1
    private var archFade: (from: CGFloat, to: CGFloat, start: CFTimeInterval) = (1, 1, 0)
    /// A sphere that shows a panorama exactly like `scene.background` does (same equirect mapping), seen from inside.
    static func skySphere(radius: CGFloat) -> SCNNode {
        let g = SCNSphere(radius: radius); g.segmentCount = 96
        let m = g.firstMaterial!; m.lightingModel = .constant
        m.cullMode = .front; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1); m.diffuse.wrapS = .repeat   // seen from inside
        let n = SCNNode(geometry: g); n.simdEulerAngles = SIMD3(0, skyYaw, 0); return n
    }
    static var skyYaw: Float = -.pi / 2   // SCNSphere's u = 0 seam vs the background's (checked by Tests/ShellTest)
    /// Call right before the background changes: what it shows now fades out over 0.8 s.
    private func fadeFromCurrentSky() {
        guard !reduceMotion, let old = scene.background.contents else { return }
        if skyFade.geometry == nil {
            let s = Compositor.skySphere(radius: 120); skyFade.geometry = s.geometry; skyFade.simdEulerAngles = s.simdEulerAngles
            skyFade.renderingOrder = -140; scene.rootNode.addChildNode(skyFade)   // after the background, before everything else
        }
        skyFade.geometry?.firstMaterial?.diffuse.contents = old
        skyFade.opacity = 1; skyFade.isHidden = false; skyFadeStart = CACurrentMediaTime()
    }
    // Game loading: the home fades into a dark starfield with the game's card and a spinner, until its first frame.
    private let splash = SCNNode(), spinner = SCNNode()
    private var splashStart: CFTimeInterval = 0
    private(set) var loading = false
    private static let loadingSky: CGImage = {   // the tour's starfield, dimmed
        let s = starfield(), c = CGContext(data: nil, width: s.width, height: s.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(s, in: CGRect(x: 0, y: 0, width: s.width, height: s.height))
        c.setFillColor(CGColor(gray: 0, alpha: 0.45)); c.fill(CGRect(x: 0, y: 0, width: s.width, height: s.height))
        return c.makeImage()!
    }()
    /// `title` non-nil: show the loading space and card 1.8 m ahead of `head`; nil: back to the home environment.
    func setLoading(_ title: String?, art: CGImage? = nil, head: VR4Pose? = nil) {
        guard let title else {
            guard loading else { return }
            loading = false; splash.isHidden = true
            if scene.background.contents != nil { let e = envName; envName = ""; setEnvironment(e) }   // crossfades back
            return
        }
        if splash.parent == nil {
            scene.rootNode.addChildNode(splash); splash.addChildNode(spinner)
            let g = SCNPlane(width: 0.11, height: 0.11), m = g.firstMaterial!
            let c = Compositor.overlayCanvas(128, 128)   // a 270 degree arc
            c.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); c.setLineWidth(10); c.setLineCap(.round)
            c.addArc(center: CGPoint(x: 64, y: 64), radius: 52, startAngle: 0, endAngle: .pi * 1.5, clockwise: false); c.strokePath()
            m.diffuse.contents = c.makeImage(); m.lightingModel = .constant; m.isDoubleSided = true; m.writesToDepthBuffer = false
            spinner.geometry = g; spinner.renderingOrder = 21
        }
        let card = Compositor.loadingCard(title, art: art), w: CGFloat = 0.9, h = w * CGFloat(card.height) / CGFloat(card.width)
        let g = SCNPlane(width: w, height: h); g.cornerRadius = 0
        let m = g.firstMaterial!; m.diffuse.contents = card; m.lightingModel = .constant; m.isDoubleSided = true; m.writesToDepthBuffer = false
        splash.geometry = g; splash.renderingOrder = 20
        spinner.simdPosition = SIMD3(0, -Float(h) / 2 - 0.12, 0)
        if let head {
            let f = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw).act(SIMD3<Float>(0, 0, -1)), yaw = atan2(-f.x, -f.z)
            splash.simdPosition = SIMD3(head.px - sin(yaw) * 1.8, head.py - 0.05, head.pz - cos(yaw) * 1.8)
            splash.simdEulerAngles = SIMD3(0, yaw, 0)
        }
        if !loading && scene.background.contents != nil { fadeFromCurrentSky(); scene.background.contents = Compositor.loadingSky; grid.isHidden = true }
        loading = true; splash.isHidden = false; splashStart = CACurrentMediaTime()
    }
    /// The loading card: the game's Steam header (or a colour tile with its initial), its name and "Starting…".
    static func loadingCard(_ title: String, art: CGImage?) -> CGImage {
        let W = 1024, artH = 479, H = artH + 230   // header art is 460 x 215
        let c = overlayCanvas(W, H), r = CGRect(x: 0, y: 0, width: W, height: H)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 44, cornerHeight: 44, transform: nil)); c.clip()
        c.setFillColor(CGColor(srgbRed: 0.09, green: 0.1, blue: 0.13, alpha: 0.96)); c.fill(r)
        let ar = CGRect(x: 0, y: H - artH, width: W, height: artH)
        if let art { c.draw(art, in: ar) } else {
            c.saveGState(); c.clip(to: ar)
            c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: 0.24, green: 0.2, blue: 0.5, alpha: 1), CGColor(srgbRed: 0.08, green: 0.3, blue: 0.55, alpha: 1)] as CFArray, locations: [0, 1])!,
                                 start: CGPoint(x: 0, y: ar.maxY), end: CGPoint(x: CGFloat(W), y: ar.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()
            draw(String(title.prefix(1)).uppercased(), in: c, at: CGPoint(x: ar.midX, y: ar.midY - 70), size: 200, bold: true, align: 0.5)
        }
        draw(title, in: c, at: CGPoint(x: 48, y: 120), size: 64, bold: true, maxW: CGFloat(W) - 96)
        draw("Starting…", in: c, at: CGPoint(x: 48, y: 52), size: 40, color: CGColor(srgbRed: 0.7, green: 0.74, blue: 0.8, alpha: 1))
        return c.makeImage()!
    }
    /// One line of the shell's rounded type into a y-up context (baseline at `at`), shortened with … to `maxW`.
    static func draw(_ s: String, in c: CGContext, at: CGPoint, size: CGFloat, bold: Bool = false, color: CGColor = CGColor(gray: 1, alpha: 1), align: CGFloat = 0, maxW: CGFloat = 1e5) {
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
        if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: size) ?? font }
        func line(_ s: String) -> CTLine { CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white])) }
        var str = s, l = line(s)
        while CTLineGetTypographicBounds(l, nil, nil, nil) > maxW, str.count > 1 { str = String(str.dropLast(2)) + "…"; l = line(str) }
        c.textPosition = CGPoint(x: at.x - CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) * align, y: at.y); CTLineDraw(l, c)
    }
    /// Home comes back from black (leaving a game) over 0.6 s.
    func fadeInHome() {
        guard !reduceMotion else { return }
        if veil.geometry == nil {   // a small black sphere around the eyes, drawn over everything
            let g = SCNSphere(radius: 0.3); g.segmentCount = 24
            let m = g.firstMaterial!; m.diffuse.contents = NSColor.black; m.lightingModel = .constant; m.cullMode = .front
            m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
            veil.geometry = g; veil.renderingOrder = 1000; scene.rootNode.addChildNode(veil)
        }
        veil.isHidden = false; veil.opacity = 1; veilStart = CACurrentMediaTime()
    }
    private func animateTransitions(head: SIMD3<Float>) {
        if !skyFade.isHidden && skyFade.parent != nil {
            let t = CGFloat(min(1, (CACurrentMediaTime() - skyFadeStart) / 0.8))
            skyFade.opacity = 1 - t * t * (3 - 2 * t)
            if t >= 1 { skyFade.isHidden = true; skyFade.geometry?.firstMaterial?.diffuse.contents = nil }
        }
        if !veil.isHidden && veil.parent != nil {
            veil.simdPosition = head
            let t = CGFloat(min(1, (CACurrentMediaTime() - veilStart) / 0.6))
            veil.opacity = 1 - t * t
            if t >= 1 { veil.isHidden = true }
        }
        if loading && !splash.isHidden {   // the card fades in; the spinner turns
            let t = Float(CACurrentMediaTime() - splashStart)
            splash.opacity = reduceMotion ? 1 : CGFloat(min(1, t / 0.4))
            spinner.simdEulerAngles = SIMD3(0, 0, -t * 5)
        }
        // home architecture fades with the sky (theater, loading) over 0.6 s; under a game backdrop it goes at once
        let want: CGFloat = homeOccluded ? 0 : 1
        if want != archFade.to { archFade = (archShown, want, CACurrentMediaTime()) }
        let k = CGFloat(min(1, (CACurrentMediaTime() - archFade.start) / 0.6))
        archShown = reduceMotion || scene.background.contents == nil ? want : archFade.from + (want - archFade.from) * k
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        homeArchitecture.opacity = archShown; homeArchitecture.isHidden = archShown <= 0
        SCNTransaction.commit()
    }
    /// Procedural deep-space panorama: dark blue-black sky, two soft nebulae, a few thousand stars.
    static func starfield() -> CGImage {
        let w = 4096, h = 2048
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0.008, green: 0.012, blue: 0.035, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for (x, y, r, col) in [(1300.0, 1150.0, 900.0, (0.35, 0.18, 0.55)), (3100.0, 800.0, 750.0, (0.1, 0.28, 0.5)), (2200.0, 1500.0, 500.0, (0.4, 0.15, 0.3))] {
            let g = CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: col.0, green: col.1, blue: col.2, alpha: 0.22), CGColor(srgbRed: col.0, green: col.1, blue: col.2, alpha: 0)] as CFArray, locations: [0, 1])!
            c.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        for _ in 0..<5000 {
            let x = rnd() * Double(w), y = rnd() * Double(h), b = pow(rnd(), 3)
            let r = 0.6 + b * 2.6, tint = rnd()
            c.setFillColor(CGColor(srgbRed: 0.85 + 0.15 * tint, green: 0.88, blue: 1 - 0.15 * tint, alpha: 0.35 + 0.65 * b))
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return c.makeImage()!
    }

    /// Show/hide the pop-up keyboard panel (it rises in with the same ease as a window).
    func setKeyboard(_ open: Bool) {
        guard kbNode.isHidden == open else { return }
        kbNode.isHidden = !open
        if open { kbPop = CACurrentMediaTime() }
    }
    private var kbPop: CFTimeInterval = 0

    /// Static, low-poly architecture gives the panorama a grounded stereo foreground.
    /// Kept outside the interaction area; no moving scenery or per-frame mesh work.
    private let homeArchitecture = SCNNode()
    private var homeStyle = ""
    private var homeOccluded: Bool { scene.background.contents == nil || (theater.parent != nil && !theater.isHidden && theaterStyle.lights != "Home") || (space.parent != nil && !space.isHidden) || loading }
    private struct HomeTriangle {
        let a, b, c, lo, hi: SIMD3<Float>
        init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            self.a = a; self.b = b; self.c = c; lo = simd_min(a, simd_min(b, c)); hi = simd_max(a, simd_max(b, c))
        }
    }
    private var homeTriangles: [HomeTriangle] = []
    private func collectHomeCollision() {
        homeTriangles = []
        homeArchitecture.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry, let source = geometry.sources(for: .vertex).first, source.usesFloatComponents, source.bytesPerComponent == 4 else { return }
            let points: [SIMD3<Float>] = source.data.withUnsafeBytes { bytes in
                (0..<source.vectorCount).map { i in
                    let offset = source.dataOffset + i * source.dataStride
                    let p = SIMD3<Float>(bytes.loadUnaligned(fromByteOffset: offset, as: Float.self), bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self), bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
                    return node.simdConvertPosition(p, to: self.homeArchitecture)
                }
            }
            for element in geometry.elements where element.primitiveType == .triangles {
                element.data.withUnsafeBytes { bytes in
                    func index(_ i: Int) -> Int { element.bytesPerIndex == 2 ? Int(bytes.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) : Int(bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
                    for i in 0..<element.primitiveCount {
                        let a = index(i * 3), b = index(i * 3 + 1), c = index(i * 3 + 2)
                        if points.indices.contains(a) && points.indices.contains(b) && points.indices.contains(c) { self.homeTriangles.append(HomeTriangle(points[a], points[b], points[c])) }
                    }
                }
            }
        }
    }
    private func homeSegmentBlocked(_ start: SIMD3<Float>, _ end: SIMD3<Float>) -> Bool {
        let direction = end - start, lo = simd_min(start, end), hi = simd_max(start, end)
        for triangle in homeTriangles {
            if triangle.hi.x < lo.x || triangle.lo.x > hi.x || triangle.hi.y < lo.y || triangle.lo.y > hi.y || triangle.hi.z < lo.z || triangle.lo.z > hi.z { continue }
            let e1 = triangle.b - triangle.a, e2 = triangle.c - triangle.a, cross = simd_cross(direction, e2), determinant = simd_dot(e1, cross)
            if abs(determinant) < 0.000001 { continue }
            let inverse = 1 / determinant, delta = start - triangle.a, u = simd_dot(delta, cross) * inverse
            if u < 0 || u > 1 { continue }
            let q = simd_cross(delta, e1), v = simd_dot(direction, q) * inverse
            if v < 0 || u + v > 1 { continue }
            let t = simd_dot(e2, q) * inverse
            if t > 0.001 && t < 0.999 { return true }
        }
        return false
    }
    private let teleportPoints = SCNNode(), teleportBeam = SCNNode(geometry: SCNCylinder(radius: 0.003, height: 1))
    private var teleportLocations: [SIMD3<Float>] = [], teleportMarkers: [SCNNode] = []
    private var teleportHeld = false, teleportHand: Int?, teleportSelection: Int?
    private lazy var teleportDot = teleportTexture(ring: false)
    private lazy var teleportCircle = teleportTexture(ring: true)
    private func teleportTexture(ring: Bool) -> CGImage? {
        let c = Self.overlayCanvas(128, 128), r = CGRect(x: 8, y: 8, width: 112, height: 112)
        if ring { c.addEllipse(in: r); c.addEllipse(in: r.insetBy(dx: 13, dy: 13)); c.clip(using: .evenOdd) }
        else { c.addEllipse(in: r); c.clip() }
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor.systemBlue.cgColor, NSColor.systemPurple.cgColor] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 8, y: 8), end: CGPoint(x: 120, y: 120), options: [])
        return c.makeImage()
    }
    private func rebuildTeleportPoints() {
        teleportPoints.removeFromParentNode(); teleportPoints.childNodes.forEach { $0.removeFromParentNode() }
        teleportLocations = []; teleportMarkers = []; teleportHeld = false; teleportSelection = nil; teleportHand = nil
        let floors = homeTriangles.filter { t in
            let normal = simd_cross(t.b - t.a, t.c - t.a)
            return abs(normal.y) > simd_length(normal) * 0.8 && t.lo.y >= -0.30 && t.hi.y <= 0.25
        }
        for x in -12...12 { for z in -12...12 {
            let px = Float(x) * 0.85, pz = Float(z) * 0.85
            var floorHeight: Float?
            for triangle in floors {
                guard px >= triangle.lo.x && px <= triangle.hi.x && pz >= triangle.lo.z && pz <= triangle.hi.z else { continue }
                let e1 = triangle.b - triangle.a, e2 = triangle.c - triangle.a
                let determinant = e1.x * e2.z - e1.z * e2.x
                guard abs(determinant) > 0.000001 else { continue }
                let dx = px - triangle.a.x, dz = pz - triangle.a.z
                let u = (dx * e2.z - dz * e2.x) / determinant, v = (e1.x * dz - e1.z * dx) / determinant
                if u >= -0.001 && v >= -0.001 && u + v <= 1.001 {
                    let y = triangle.a.y + u * e1.y + v * e2.y
                    floorHeight = max(floorHeight ?? y, y)
                }
            }
            guard let y = floorHeight else { continue }
            let location = SIMD3<Float>(px, y, pz)
            var clear = true
            for offset in [SIMD3<Float>(0.3, 0, 0), SIMD3(-0.3, 0, 0), SIMD3(0, 0, 0.3), SIMD3(0, 0, -0.3)] {
                let start = location + SIMD3<Float>(0, 0.9, 0)
                if homeSegmentBlocked(start, start + offset) { clear = false }
            }
            guard clear else { continue }
            let marker = SCNNode(geometry: SCNPlane(width: 0.09, height: 0.09)); marker.simdPosition = location + SIMD3(0, 0.014, 0)
            marker.simdEulerAngles.x = -.pi / 2; marker.geometry?.firstMaterial?.lightingModel = .constant
            marker.geometry?.firstMaterial?.diffuse.contents = teleportDot; marker.geometry?.firstMaterial?.blendMode = .alpha
            marker.geometry?.firstMaterial?.writesToDepthBuffer = false
            teleportLocations.append(location); teleportMarkers.append(marker); teleportPoints.addChildNode(marker)
        } }
        NSLog("VR4Mac: %@ home loaded with %d walkable teleport points", homeStyle, teleportLocations.count)
        homeArchitecture.addChildNode(teleportPoints); teleportPoints.isHidden = true
        if teleportBeam.parent == nil { scene.rootNode.addChildNode(teleportBeam) }
        teleportBeam.pivot = SCNMatrix4MakeTranslation(0, -0.5, 0)
        teleportBeam.geometry?.firstMaterial?.lightingModel = .constant; teleportBeam.geometry?.firstMaterial?.diffuse.contents = NSColor.systemBlue
        teleportBeam.isHidden = true
    }
    // 0 = neutral, 1 = UI scroll gesture, 2 = teleport gesture.
    private var teleportStickOwner = [0, 0]
    private func pointsAtUI(_ aim: VR4Pose) -> Bool {
        hit(aim, solid: { _, _ in true }) != nil || hitWindow(aim) != nil || hitPicker(aim) != nil
    }
    /// Forward stick holds teleport aiming; release commits only a snapped, walkable floor point.
    func updateTeleport(_ t: VR4Tracking, enabled: Bool) -> Bool {
        let hands = [t.hand.0, t.hand.1]
        for i in hands.indices {
            if !enabled || hands[i].flags & UInt32(VR4_HAND_POSE_VALID) == 0 || abs(hands[i].stick_y) < 0.2 {
                teleportStickOwner[i] = 0
            } else if teleportStickOwner[i] == 0 || teleportStickOwner[i] == 2 {
                if pointsAtUI(hands[i].aim) {
                    teleportStickOwner[i] = 1
                    // Moving a teleport aim onto UI cancels rather than committing a jump.
                    if teleportHand == i { teleportSelection = nil }
                } else if teleportStickOwner[i] == 0 { teleportStickOwner[i] = 2 }
            }
        }
        let requested = hands.indices.first {
            teleportStickOwner[$0] == 2 && hands[$0].flags & UInt32(VR4_HAND_POSE_VALID) != 0 && hands[$0].stick_y > 0.65
        }
        let held = enabled && !homeOccluded && requested != nil
        if !held {
            if teleportHeld, enabled, !homeOccluded, let selection = teleportSelection, let hand = teleportHand, hands[hand].flags & UInt32(VR4_HAND_POSE_VALID) != 0 {
                let point = teleportLocations[selection] + homeOffset
                homeOffset += SIMD3(t.head.px - point.x, -point.y, t.head.pz - point.z)
                homeArchitecture.simdPosition = homeOffset
            }
            teleportHeld = false; teleportSelection = nil; teleportHand = nil; teleportPoints.isHidden = true; teleportBeam.isHidden = true; return false
        }
        teleportHeld = true; teleportHand = requested; teleportPoints.isHidden = false
        var (origin, direction) = ray(hands[requested!].aim)
        if let trigger = self.hands[requested!].grip.childNode(withName: "trigger", recursively: true) {
            let (lo, hi) = trigger.boundingBox
            let local = trigger.simdConvertPosition(SIMD3(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z) - 0.006), to: self.hands[requested!].grip)
            let grip = hands[requested!].grip
            origin = SIMD3(grip.px, grip.py, grip.pz) + simd_quatf(ix: grip.qx, iy: grip.qy, iz: grip.qz, r: grip.qw).act(local)
        }
        teleportSelection = nil
        var arc = [origin], velocity = direction * 4.5 + SIMD3<Float>(0, 1.0, 0)
        var position = origin
        for _ in 0..<70 {
            let next = position + velocity * 0.035 + SIMD3<Float>(0, -2.75 * 0.035 * 0.035, 0)
            velocity.y -= 5.5 * 0.035
            arc.append(next)
            if homeSegmentBlocked(position - homeOffset, next - homeOffset) || next.y < homeOffset.y - 0.30 { break }
            position = next
        }
        let landing = arc.last!
        var best: Float = 0.42
        for (i, local) in teleportLocations.enumerated() {
            let point = local + homeOffset
            guard abs(point.y - landing.y) < 0.30 else { continue }
            let delta = simd_length(SIMD2(point.x - landing.x, point.z - landing.z))
            if delta < best { best = delta; teleportSelection = i }
        }
        if let selection = teleportSelection { arc[arc.count - 1] = teleportLocations[selection] + homeOffset + SIMD3(0, 0.02, 0) }
        drawTeleportArc(arc)
        for (i, marker) in teleportMarkers.enumerated() {
            let selected = i == teleportSelection
            marker.geometry?.firstMaterial?.diffuse.contents = selected ? teleportCircle : teleportDot
            marker.simdScale = SIMD3(repeating: selected ? 3.5 : 1)
        }
        teleportBeam.isHidden = false
        return true
    }
    private func drawTeleportArc(_ points: [SIMD3<Float>]) {
        var vertices: [SCNVector3] = [], colors = Data(), indices: [Int32] = []
        for i in points.indices {
            let tangent = simd_normalize(points[min(i + 1, points.count - 1)] - points[max(0, i - 1)])
            let reference: SIMD3<Float> = abs(tangent.y) > 0.95 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let x = simd_normalize(simd_cross(tangent, reference)), y = simd_cross(tangent, x)
            let progress = Float(i) / Float(max(1, points.count - 1))
            for j in 0..<6 {
                let angle = Float(j) * 2 * .pi / 6
                vertices.append(SCNVector3(points[i] + (x * cos(angle) + y * sin(angle)) * 0.004))
                var color = SIMD4<Float>(0.15 + progress * 0.5, 0.4 - progress * 0.18, 1, 1)
                withUnsafeBytes(of: &color) { colors.append(contentsOf: $0) }
                if i > 0 { let a = Int32((i - 1) * 6 + j), b = Int32((i - 1) * 6 + (j + 1) % 6), c = Int32(i * 6 + j), d = Int32(i * 6 + (j + 1) % 6); indices += [a, b, c, b, d, c] }
            }
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(data: colors, semantic: .color, vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.firstMaterial?.lightingModel = .constant; g.firstMaterial?.diffuse.contents = NSColor.white
        g.firstMaterial?.readsFromDepthBuffer = false; g.firstMaterial?.writesToDepthBuffer = false
        teleportBeam.geometry = g; teleportBeam.simdTransform = matrix_identity_float4x4; teleportBeam.pivot = SCNMatrix4Identity; teleportBeam.renderingOrder = 199
    }
    private var homeOffset = SIMD3<Float>.zero
    func setHomeStyle(_ style: String) {
        guard homeStyle != style else { return }
        homeStyle = style; homeOffset = .zero
        homeArchitecture.childNodes.forEach { $0.removeFromParentNode() }
        homeArchitecture.name = "MacVR Home Architecture"
        if homeArchitecture.parent == nil { scene.rootNode.addChildNode(homeArchitecture) }
        if let model = ControllerGLB.home(style == "Kleeblatt" ? "kleeblatt" : "room1107") { homeArchitecture.addChildNode(model) }
        homeArchitecture.simdPosition = .zero; homeArchitecture.isHidden = homeOccluded
        collectHomeCollision(); rebuildTeleportPoints()
    }

    // MARK: home environments (CC0 panoramas) or the purple void
    private var envName = ""
    func setEnvironment(_ name: String) {
        guard name != envName else { return }
        envName = name
        var contents: Any = Compositor.sky(), isVoid = true   // (`is CGImage` is always true for CF types, so track it)
        if let f = Dashboard.envFile(name), let url = Bundle.main.url(forResource: f, withExtension: "jpg", subdirectory: "environments"),
           let img = NSImage(contentsOf: url) { contents = img; isVoid = false }
        if theater.parent != nil && !theater.isHidden && scene.background.contents != nil {   // in the theater: the room keeps its lights
            skyContents = contents; voidEnv = isVoid; applyTheaterLights(); return
        }
        if scene.background.contents != nil && !loading { fadeFromCurrentSky(); scene.background.contents = contents }   // nil = a game is behind the menu
        skyContents = contents
        voidEnv = isVoid
        grid.isHidden = !gridOn || !isVoid || scene.background.contents == nil || loading
    }
    private var voidEnv = true
    private lazy var dashQueue = device.makeCommandQueue()

    private var dashTex: [MTLTexture] = [], dashIdx = 0   // dashboard queue only
    /// Copies the dashboard bitmap into one of two textures (off the render queue) and returns it.
    func uploadDashboard(_ ctx: CGContext) -> MTLTexture? {
        if dashTex.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: ctx.width, height: ctx.height, mipmapped: true)
            d.usage = .shaderRead; d.storageMode = .shared
            dashTex = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard let data = ctx.data, dashTex.count == 2 else { return nil }
        dashIdx ^= 1
        dashTex[dashIdx].replace(region: MTLRegionMake2D(0, 0, ctx.width, ctx.height), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        if let cb = dashQueue?.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: dashTex[dashIdx]); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        return dashTex[dashIdx]
    }
    private var sideTex: [[MTLTexture]] = [[], []], sideIdx = [0, 0]   // dashboard queue only
    /// Side window canvases, like uploadDashboard (double-buffered, mipmapped).
    func uploadSide(_ i: Int, _ ctx: CGContext) -> MTLTexture? {
        if sideTex[i].isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: ctx.width, height: ctx.height, mipmapped: true)
            d.usage = .shaderRead; d.storageMode = .shared
            sideTex[i] = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard let data = ctx.data, sideTex[i].count == 2 else { return nil }
        sideIdx[i] ^= 1
        let t = sideTex[i][sideIdx[i]]
        t.replace(region: MTLRegionMake2D(0, 0, ctx.width, ctx.height), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        if let cb = dashQueue?.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() { blit.generateMipmaps(for: t); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted() }
        return t
    }
    private var gridOn = true
    func setGrid(_ on: Bool) { gridOn = on; grid.isHidden = !on || !voidEnv || scene.background.contents == nil || loading }

    // MARK: grab bars: the window or the dock follows the pointer ray while the trigger is held
    private var grabPart = Part.window, grabDist0: Float = 1, grabScale: Float = 1, grabLocal = SIMD3<Float>(0, 0, 0)
    private var handDist0: Float = 0, grabPush: Float = 0, grabDist: Float = 1, atStop = false
    private var carried: [(SCNNode, simd_float4x4)] = []   // dragging the dock carries the window + keyboard along
    /// Tests: world position of the window centre / its grab bar.
    func debugWindowWorld() -> SIMD3<Float> { win.simdWorldPosition }
    func debugGrabBarWorld() -> SIMD3<Float> {
        let m = metersPerPx, y = (Float(Dashboard.SPLIT) / 2 - Float(Dashboard.GRAB.midY)) * m
        return panel.simdConvertPosition(SIMD3(0, y, 0), to: nil)
    }
    private func node(_ p: Part) -> SCNNode { p == .window ? win : p == .dock ? dockNode : kbNode }
    private func horizontal(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { simd_length(SIMD2(a.x - b.x, a.z - b.z)) }
    /// Start dragging `part` at the ray's current hit.
    private var grabSlot = 1
    func beginGrab(_ part: Part, _ aim: VR4Pose, dist: Float, head: VR4Pose, slot: Int = 1) {
        grabSlot = slot
        let (o, d) = ray(aim), n = node(part)
        grabPart = part; grabDist0 = dist; grabDist = dist; grabScale = n.simdScale.x; grabPush = 0; atStop = false
        handDist0 = horizontal(o, SIMD3(head.px, head.py, head.pz))
        grabLocal = n.simdConvertPosition(o + d * dist, from: nil)
        grabRot0 = n.simdWorldOrientation; grabStart = CACurrentMediaTime()
        carried = part == .dock ? [win, kbNode].map { ($0, n.simdWorldTransform.inverse * $0.simdWorldTransform) } : []
        if part == .window && questLayout { beginSlots(slot: grabSlot, at: o + d * dist) }
        if part == .dock && questLayout {   // Quest: the dock carries the whole shell (windows, slots) rigidly
            dashLocal = dash.simdConvertPosition(o + d * dist, from: nil); dashRot0 = dash.simdWorldOrientation
            let f = dashRot0.act(SIMD3<Float>(0, 0, -1)); dashPitch = simd_quatf(angle: -atan2(-f.y, simd_length(SIMD2(f.x, f.z))), axis: SIMD3(1, 0, 0))
            carried = []
        }
    }
    private var dashLocal = SIMD3<Float>(0, 0, 0), dashRot0 = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), dashPitch = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
    private var grabRot0 = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), grabStart: CFTimeInterval = 0
    /// The grabbed point stays on the ray at the distance it was grabbed, facing the head. SteamVR style: moving the
    /// hand forward/back (x3) sends it further or nearer and the window grows as it recedes. The stick pushes/pulls.
    /// Quest windows instead slide left/right between the three multitasking slots (updateSlots).
    /// Returns true the moment it hits a distance stop (haptic + sound cue).
    @discardableResult
    func updateGrab(_ aim: VR4Pose, head: VR4Pose, push: Float) -> Bool {
        if grabPart == .window && questLayout { updateSlots(aim); return false }
        if grabPart == .dock && questLayout {   // keep the grabbed point on the ray, turn to face you, keep the shell's lean
            let (o, d) = ray(aim), h = SIMD3(head.px, head.py, head.pz), p = o + d * grabDist0, v = h - p
            let want = simd_quatf(angle: atan2(v.x, v.z), axis: SIMD3(0, 1, 0)) * dashPitch
            let rot = simd_slerp(dashRot0, want, Float(min(1, (CACurrentMediaTime() - grabStart) / 0.15)))
            dash.simdWorldOrientation = rot
            dash.simdWorldPosition = p - rot.act(dashLocal)
            return false
        }
        let (o, d) = ray(aim), n = node(grabPart), h = SIMD3(head.px, head.py, head.pz)
        grabPush += push
        let reach: Float = questLayout ? 0 : 3
        let maxD: Float = grabPart == .window ? 3 : 2, want = grabDist0 + grabPush + reach * (horizontal(o, h) - handDist0)
        grabDist = min(maxD, max(0.35, want))
        let hit = (want >= maxD || want <= 0.35) && !atStop
        atStop = want >= maxD || want <= 0.35
        if atStop { grabPush = grabDist - grabDist0 - reach * (horizontal(o, h) - handDist0) }   // no wind-up past the stop
        let p = o + d * grabDist, v = h - p
        let q = simd_quatf(angle: atan2(v.x, v.z), axis: SIMD3(0, 1, 0))
        // Quest style faces you wherever it's dragged. SteamVR style stays upright near eye level and pitches to face
        // you once dragged well above or below the head (smoothly, from ~20 deg).
        let elev = atan2(v.y, simd_length(SIMD2(v.x, v.z)))
        let blend = questLayout ? 1 : min(1, max(0, (abs(elev) - 0.35) / 0.3))
        let base: Float = grabPart == .dock ? (questLayout ? -0.18 : -0.35) : grabPart == .keyboard ? -0.6 : 0
        let tilt = simd_quatf(angle: base + (-elev - base) * blend, axis: SIMD3(1, 0, 0))
        let sc = grabPart == .window && !questLayout ? min(2.2, max(0.45, grabScale * (grabDist / grabDist0).squareRoot())) : grabScale
        // turn toward the new facing over ~0.15 s instead of snapping on grab
        let rot = simd_slerp(grabRot0, q * tilt, Float(min(1, (CACurrentMediaTime() - grabStart) / 0.15)))
        n.simdScale = SIMD3(repeating: sc)
        n.simdWorldOrientation = rot
        n.simdWorldPosition = p - rot.act(grabLocal * sc)
        for (c, rel) in carried { c.simdWorldTransform = n.simdWorldTransform * rel }
        return hit
    }
    /// Ends a drag; for a Quest window returns (from slot, to slot) so the windows can be swapped.
    @discardableResult func endGrab() -> (Int, Int)? { grabPart == .window && questLayout ? endSlots() : nil }

    // MARK: multitasking (Quest style): three window slots side by side around you (left, centre, right), in dash space.
    // Dragging a window by its bar slides it left/right across the slots (a transparent band with three frames shows
    // while dragging); on release it settles into the nearest slot and swaps with whatever was there.
    let sides = [SCNNode(), SCNNode()]   // left, right window panels (centre is `win`)
    private let slotsNode = SCNNode()
    private var headLocal = SIMD3<Float>(0, 0.1, 1), winHome = matrix_identity_float4x4   // the head in dash space at the last placement
    private var dragSlot = 1, dragAngle: Float = 0
    private var settle: (node: SCNNode, from: simd_float4x4, to: simd_float4x4, start: CFTimeInterval)?
    /// Window panel (and its home transform) for slot 0 left, 1 centre, 2 right.
    private func slotNode(_ k: Int) -> SCNNode { k == 1 ? win : sides[k == 0 ? 0 : 1] }
    private var slotStep: Float {
        let w = Float(Dashboard.WIN.width) * metersPerPx * layout.win
        return (w + 0.05) / max(0.3, simd_length(SIMD2(headLocal.x, headLocal.z)))   // window width + gap, as an angle
    }
    /// Home transform of slot k: the centre window's transform turned about the head's vertical axis.
    private func slotTransform(_ k: Int, angle extra: Float = 0) -> simd_float4x4 {
        let a = Float(1 - k) * slotStep + extra   // left slot is to the left (+ yaw)
        var t = matrix_identity_float4x4; t.columns.3 = SIMD4(headLocal, 1)
        var ti = matrix_identity_float4x4; ti.columns.3 = SIMD4(-headLocal, 1)
        let base = winHome   // the centre window's home (resetLayout)
        return t * simd_float4x4(simd_quatf(angle: a, axis: SIMD3(0, 1, 0))) * ti * base
    }
    private func layoutSides() {
        guard questLayout else { sides.forEach { $0.isHidden = true }; return }
        for k in [0, 2] { slotNode(k).simdTransform = slotTransform(k) }
    }
    /// Dashboard side canvases (nil = slot empty).
    func setSide(_ i: Int, _ tex: MTLTexture?) {
        sides[i].geometry?.firstMaterial?.diffuse.contents = tex
        sides[i].isHidden = tex == nil || !questLayout
    }
    private func beginSlots(slot: Int, at hit: SIMD3<Float>) {
        dragSlot = slot; dragAngle = 0
        let l = dash.simdConvertPosition(hit, from: nil)
        slotR = max(0.2, simd_length(SIMD2(l.x - headLocal.x, l.z - headLocal.z)))
        grabYaw = yaw(l) - Float(1 - slot) * slotStep   // where on the window it was grabbed, as an angle
        slotsNode.childNodes.forEach { $0.removeFromParentNode() }
        let m = metersPerPx, w = Float(Dashboard.WIN.width) * m, h = Float(Dashboard.WIN.height) * m, r = bend[ObjectIdentifier(panel)] ?? radius / layout.win
        func frame(_ w: Float, _ h: Float, _ a: CGFloat) -> SCNNode {
            let g = Compositor.bent(w: w, h: h, r: r, seg: 48)
            g.firstMaterial?.diffuse.contents = NSColor(white: 1, alpha: a); g.firstMaterial?.blendMode = .alpha
            g.firstMaterial?.writesToDepthBuffer = false; g.firstMaterial?.readsFromDepthBuffer = false
            let n = SCNNode(geometry: g); n.renderingOrder = 9; return n
        }
        let ly = (Float(Dashboard.SPLIT) / 2 - Float(Dashboard.WIN.midY)) * m   // window rect centre inside the panel
        for k in 0..<3 {   // three window-sized frames
            let f = frame(w, h, 0.1); f.simdTransform = slotTransform(k); f.simdPosition += f.simdOrientation.act(SIMD3(0, ly, 0.002)) * layout.win
            slotsNode.addChildNode(f)
        }
        let band = frame(w * 3 + 0.25 / layout.win, h + 0.08 / layout.win, 0.05)   // the wide band behind them
        band.simdTransform = slotTransform(1); band.simdPosition += band.simdOrientation.act(SIMD3(0, ly, -0.002)) * layout.win
        slotsNode.addChildNode(band)
        if slotsNode.parent == nil { dash.addChildNode(slotsNode) }
        slotsNode.isHidden = false; slotsNode.opacity = 1; settle = nil
    }
    private var slotR: Float = 1, grabYaw: Float = 0
    /// Angle of a dash-space point around the head's vertical axis (0 = the centre window, + = left).
    private func yaw(_ l: SIMD3<Float>) -> Float {
        atan2(l.x - headLocal.x, l.z - headLocal.z) - atan2(-headLocal.x, -headLocal.z)
    }
    /// The window follows where the laser meets the slots' cylinder (absolute, so moving your head or body can't drift it).
    private func updateSlots(_ aim: VR4Pose) {
        let (o, d) = ray(aim)
        let lo = dash.simdConvertPosition(o, from: nil), ld = dash.simdConvertVector(d, from: nil)
        let p = SIMD2(lo.x - headLocal.x, lo.z - headLocal.z), v = SIMD2(ld.x, ld.z)
        let a = simd_dot(v, v), b = 2 * simd_dot(p, v), c = simd_dot(p, p) - slotR * slotR, disc = b * b - 4 * a * c
        guard a > 1e-6, disc >= 0 else { return }
        let t = (-b + disc.squareRoot()) / (2 * a)
        guard t > 0 else { return }
        var dy = yaw(lo + ld * t) - grabYaw
        if dy > .pi { dy -= 2 * .pi } else if dy < -.pi { dy += 2 * .pi }
        let home = Float(1 - dragSlot) * slotStep
        dragAngle = min(slotStep, max(-slotStep, dy)) - home   // stay within the band
        slotNode(dragSlot).simdTransform = slotTransform(dragSlot, angle: dragAngle)
    }
    /// Release: the slot it lands in. The panels stay bound to their slots, so the caller swaps the windows' contents;
    /// the dragged panel snaps home and the target slot's panel glides in from where the window was let go.
    private func endSlots() -> (Int, Int) {
        let pos = Float(1 - dragSlot) * slotStep + dragAngle
        let target = 1 - Int((pos / slotStep).rounded())
        let to = min(2, max(0, target)), released = slotNode(dragSlot).simdTransform
        slotNode(dragSlot).simdTransform = slotTransform(dragSlot)
        settle = (slotNode(to), released, slotTransform(to), CACurrentMediaTime())
        slotNode(to).simdTransform = released
        return (dragSlot, to)
    }
    /// Per frame: a released window springs into its slot (slight overshoot, settled in ~0.4 s) and the frames fade.
    private func tickSlots() {
        if let s = settle {
            let t = Float(CACurrentMediaTime() - s.start), e = reduceMotion ? 1 : Compositor.spring(t)
            var m = s.from
            for c in 0..<4 { m[c] = s.from[c] + (s.to[c] - s.from[c]) * e }
            s.node.simdTransform = m
            slotsNode.opacity = CGFloat(max(0, 1 - t / 0.25))
            if t >= 0.45 || reduceMotion { settle = nil; slotsNode.isHidden = true; layoutSides(); win.simdTransform = slotTransform(1) }
        }
    }
    /// Damped spring step response (0 -> 1, ~6% overshoot, within 1% by 0.4 s).
    static func spring(_ t: Float) -> Float {
        let w: Float = 18, z: Float = 0.68, wd = w * (1 - z * z).squareRoot()
        return t <= 0 ? 0 : 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }
    private var jumpStart: CFTimeInterval = -10
    /// A new app replaced the centre window: it hops.
    func jump() { jumpStart = CACurrentMediaTime() }

    /// Thumbstick left/right on the Mac desktop: resize the window (bigger = more readable desktop text).
    func zoomWindow(_ d: Float) {
        let s = min(2.2, max(0.5, win.simdScale.x * (1 + d)))
        win.simdScale = SIMD3(repeating: s)
    }

    // MARK: open/close motion (Quest Universal Menu): a quick fade with a tiny settle, no flying across the room
    private var popStart: CFTimeInterval = 0, popDock = false, closeStart: CFTimeInterval = 0, shown = true
    private var slotFocus = 1, slotDim: [CGFloat] = [1, 1, 1]
    /// The multitasking window (0 left, 1 centre, 2 right) being pointed at or touched.
    func setSlotFocus(_ slot: Int) { slotFocus = slot }
    func pop(dock: Bool) { popStart = CACurrentMediaTime(); popDock = dock }
    /// Show/hide the whole shell; hiding fades it out quickly (inverse of opening) before it disappears.
    func setDashVisible(_ on: Bool) {
        if on { shown = true; dash.isHidden = false; dash.opacity = 1 }
        else if shown { shown = false; closeStart = CACurrentMediaTime() }
    }
    private func animate() {
        let rm = reduceMotion
        let t = rm ? 1 : Float(min(1, (CACurrentMediaTime() - popStart) / 0.16)), e = 1 - pow(1 - t, 3)   // ease-out cubic, 160 ms
        winContent.simdPosition = SIMD3(0, -0.025 * (1 - e), 0)
        winContent.simdScale = SIMD3(repeating: 0.97 + 0.03 * e)
        winContent.opacity = CGFloat(e)
        let j = Float((CACurrentMediaTime() - jumpStart) / 0.34)
        if j >= 0 && j < 1 && !rm {   // a new app replaced the centre window: a quick hop up and back with a slight squash
            winContent.simdPosition.y += 0.035 * sin(.pi * j) * (1 - j * 0.3)
            winContent.simdScale *= 1 - 0.04 * sin(.pi * j)
        }
        let de = popDock ? e : 1
        dockPanel.simdPosition = SIMD3(0, -0.015 * (1 - de), 0)
        dockPanel.simdScale = SIMD3(repeating: 0.98 + 0.02 * de)
        dockPanel.opacity = CGFloat(de)
        let ke = rm ? 1 : 1 - pow(1 - Float(min(1, (CACurrentMediaTime() - kbPop) / 0.16)), 3)
        kbPanel.simdPosition = SIMD3(0, -0.02 * (1 - ke), 0); kbPanel.opacity = CGFloat(ke)
        // multitasking focus: with side windows open, the one you last pointed at is lit and the others dim a little
        let anySide = sides.contains { !$0.isHidden }
        for (k, n) in [(0, sides[0]), (1, panel), (2, sides[1])] {
            let want: CGFloat = !anySide || k == slotFocus ? 1 : 0.8, v = rm ? want : slotDim[k] + (want - slotDim[k]) * 0.2
            if abs(v - slotDim[k]) > 0.002 || (v == want && slotDim[k] != want) { slotDim[k] = v; n.geometry?.firstMaterial?.multiply.contents = NSColor(white: v, alpha: 1) }
        }
        if !shown && !dash.isHidden {   // close: 120 ms fade
            let c = rm ? 1 : min(1, (CACurrentMediaTime() - closeStart) / 0.12)
            dash.opacity = CGFloat(1 - c)
            if c >= 1 { dash.isHidden = true; dash.opacity = 1 }
        }
    }

    private func ray(_ aim: VR4Pose) -> (SIMD3<Float>, SIMD3<Float>) {
        (SIMD3(aim.px, aim.py, aim.pz), simd_quatf(ix: aim.qx, iy: aim.qy, iz: aim.qz, r: aim.qw).act(SIMD3<Float>(0, 0, -1)))
    }

    /// Put the dashboard at `radius` in front of the head, facing it, slightly below eye level.
    func place(head: VR4Pose) {
        let q = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw)
        let f = q.act(SIMD3<Float>(0, 0, -1))
        let yaw = atan2(-f.x, -f.z)
        let drop: Float = questLayout ? 0.12 : 0.2
        dash.simdPosition = SIMD3(head.px - sin(yaw) * radius, head.py - drop, head.pz - cos(yaw) * radius)
        // Quest: lean the whole menu back so the window (below eye level) faces your eyes, not the horizon
        let pitch: Float = questLayout ? atan2(drop - 0.08, radius) : 0
        dash.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -pitch, axis: SIMD3(1, 0, 0))
        headLocal = dash.simdConvertPosition(SIMD3(head.px, head.py, head.pz), from: nil)
        resetLayout()
    }

    // MARK: Mac windows in VR: a floating panel per Mac app window, with a soft shadow and a bar under it (move, keyboard,
    // pin, close). Shown with the menu; pinned ones stay when it closes. The window picker floats in front of the menu.
    final class WindowPanel {
        let root = SCNNode(), content = SCNNode(), bar = SCNNode(), shadow = SCNNode()
        var mip: MTLTexture?, last: CVPixelBuffer?, aspect: CGFloat = 0, width: Float = 1, pinned = false, dim: CGFloat = 1
    }
    private(set) var windowPanels: [CGWindowID: WindowPanel] = [:]
    private let picker = SCNNode()
    private var windowsShown = true, focusedWindow: CGWindowID?
    /// A new panel ~0.95 m ahead of `head` (fanned out to the sides when there are several), `width` metres wide.
    func addWindow(_ id: CGWindowID, width: Float, head: VR4Pose) {
        guard windowPanels[id] == nil else { return }
        let p = WindowPanel(); p.width = width
        p.root.addChildNode(p.shadow); p.root.addChildNode(p.content); p.root.addChildNode(p.bar)
        let sm = SCNMaterial(); sm.diffuse.contents = Compositor.glow(soft: 0.35); sm.multiply.contents = NSColor.black; sm.transparency = 0.55
        sm.lightingModel = .constant; sm.writesToDepthBuffer = false; sm.isDoubleSided = true
        let sg = SCNPlane(width: 1, height: 1); sg.materials = [sm]; p.shadow.geometry = sg; p.shadow.renderingOrder = 8
        p.content.renderingOrder = 12; p.bar.renderingOrder = 13
        let bg = SCNPlane(width: CGFloat(min(width, 0.75)), height: CGFloat(min(width, 0.75)) * CGFloat(MacWindows.barH) / CGFloat(MacWindows.barW))
        bg.firstMaterial?.lightingModel = .constant; bg.firstMaterial?.isDoubleSided = true; bg.firstMaterial?.writesToDepthBuffer = false
        p.bar.geometry = bg
        let f = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw).act(SIMD3<Float>(0, 0, -1))
        let fan: [Float] = [-0.62, 0.62, -1.15, 1.15, -0.3, 0.3], yaw = atan2(-f.x, -f.z) + fan[windowPanels.count % fan.count]   // beside the menu: right, left, ...
        let h = SIMD3(head.px, head.py, head.pz)
        p.root.simdPosition = h + SIMD3(-sin(yaw) * 1.0, -0.04, -cos(yaw) * 1.0)
        p.root.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        scene.rootNode.addChildNode(p.root); windowPanels[id] = p; focusedWindow = id
    }
    func removeWindow(_ id: CGWindowID) { windowPanels.removeValue(forKey: id)?.root.removeFromParentNode() }
    /// Latest capture of the window, and (when it changed) its bar image.
    func setWindow(_ id: CGWindowID, _ pb: CVPixelBuffer?, bar: CGImage?) {
        guard let p = windowPanels[id] else { return }
        if let bar { p.bar.geometry?.firstMaterial?.diffuse.contents = bar }
        guard let pb, let tex = mipmap(pb, &p.mip, &p.last) else { return }
        let aspect = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(max(1, CVPixelBufferGetHeight(pb)))
        if abs(aspect - p.aspect) > 0.001 || p.content.geometry == nil {   // (re)size to the window's shape
            p.aspect = aspect
            let h = p.width / Float(aspect)
            p.content.geometry = Compositor.bent(w: p.width, h: h, r: 1, seg: 1, curve: false)
            p.shadow.simdScale = SIMD3(p.width * 1.12, h * 1.14 + 0.03, 1); p.shadow.simdPosition = SIMD3(0, -0.015, -0.03)
            let bh = Float((p.bar.geometry as? SCNPlane)?.height ?? 0.06)
            p.bar.simdPosition = SIMD3(0, -h / 2 - bh / 2 - 0.018, 0.005)
        }
        if let m = p.content.geometry?.firstMaterial {
            m.diffuse.contents = tex; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16; m.writesToDepthBuffer = false
            m.multiply.contents = NSColor(white: p.dim, alpha: 1)
        }
    }
    func setWindowPinned(_ id: CGWindowID, _ on: Bool) { windowPanels[id]?.pinned = on }
    /// Per frame: panels show with the menu (pinned ones always); the window you last used is lit, the others dimmed a little.
    func showWindows(menu: Bool, focus: CGWindowID?) {
        windowsShown = menu; if let focus { focusedWindow = focus }
        for (id, p) in windowPanels {
            p.root.isHidden = !(menu || p.pinned)
            let want: CGFloat = id == focusedWindow || windowPanels.count == 1 ? 1 : 0.78
            p.dim += (want - p.dim) * (reduceMotion ? 1 : 0.2)
            p.content.geometry?.firstMaterial?.multiply.contents = NSColor(white: p.dim, alpha: 1)
        }
        if !menu { picker.isHidden = true }
    }
    /// Nearest Mac window under a ray: its id, uv on the window (or on its bar), distance.
    func hitWindow(_ aim: VR4Pose, only: CGWindowID? = nil) -> (id: CGWindowID, uv: CGPoint, dist: Float, bar: Bool)? {
        let (o, d) = ray(aim)
        var best: (id: CGWindowID, uv: CGPoint, dist: Float, bar: Bool)?
        for (id, p) in windowPanels where !p.root.isHidden && (only == nil || only == id) {
            for (n, isBar) in [(p.content, false), (p.bar, true)] where n.geometry != nil {
                let a = n.simdConvertPosition(o, from: nil), b = n.simdConvertPosition(o + d * 10, from: nil)
                guard let h = n.hitTestWithSegment(from: SCNVector3(a), to: SCNVector3(b), options: [SCNHitTestOption.backFaceCulling.rawValue: false]).first else { continue }
                let dist = simd_distance(o, h.simdWorldCoordinates)
                if dist < best?.dist ?? .infinity { best = (id, h.textureCoordinates(withMappingChannel: 0), dist, isBar); rememberPointerSurface(h, aim: aim) }
            }
        }
        return best
    }
    // moving a window by its bar: the grabbed point rides the ray at its distance, the panel turns to face you
    private var winGrab: (id: CGWindowID, local: SIMD3<Float>, dist: Float, rot0: simd_quatf, start: CFTimeInterval)?
    func beginWindowMove(_ id: CGWindowID, _ aim: VR4Pose, dist: Float) {
        guard let p = windowPanels[id] else { return }
        let (o, d) = ray(aim)
        winGrab = (id, p.root.simdConvertPosition(o + d * dist, from: nil), dist, p.root.simdWorldOrientation, CACurrentMediaTime())
    }
    func updateWindowMove(_ aim: VR4Pose, head: VR4Pose, push: Float) {
        guard var g = winGrab, let p = windowPanels[g.id] else { return }
        g.dist = min(3, max(0.35, g.dist + push)); winGrab = g
        let (o, d) = ray(aim), at = o + d * g.dist, h = SIMD3(head.px, head.py, head.pz), k = Float(min(1, (CACurrentMediaTime() - g.start) / 0.15))
        var rot = g.rot0, centre = p.root.simdWorldPosition
        for _ in 0..<3 {   // face the head from the window's centre (not the grabbed point on its bar): settle the circular dependency
            let v = h - centre
            let want = simd_quatf(angle: atan2(v.x, v.z), axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -atan2(v.y, simd_length(SIMD2(v.x, v.z))), axis: SIMD3(1, 0, 0))
            rot = simd_slerp(g.rot0, want, k); centre = at - rot.act(g.local * p.root.simdScale.x)
        }
        p.root.simdWorldOrientation = rot; p.root.simdWorldPosition = centre
    }
    func endWindowMove() { winGrab = nil }
    /// Resize (stick left/right while pointing at it, or both hands pulling apart): scale clamped 0.4x-3x.
    func scaleWindow(_ id: CGWindowID, by k: Float) {
        guard let p = windowPanels[id] else { return }
        p.root.simdScale = SIMD3(repeating: min(3, max(0.4, p.root.simdScale.x * k)))
    }
    func windowScale(_ id: CGWindowID) -> Float { windowPanels[id]?.root.simdScale.x ?? 1 }
    func setWindowScale(_ id: CGWindowID, _ s: Float) { windowPanels[id]?.root.simdScale = SIMD3(repeating: min(3, max(0.4, s))) }

    /// The window picker (nil hides it), placed 0.8 m ahead of `head` in front of the menu when it opens.
    func showPicker(_ img: CGImage?, head: VR4Pose?) {
        guard let img else { picker.isHidden = true; return }
        if picker.geometry == nil {
            let g = SCNPlane(width: 0.78, height: 0.78 * CGFloat(MacWindows.H) / CGFloat(MacWindows.W))
            g.firstMaterial?.lightingModel = .constant; g.firstMaterial?.isDoubleSided = true; g.firstMaterial?.writesToDepthBuffer = false
            picker.geometry = g; picker.renderingOrder = 30; scene.rootNode.addChildNode(picker)
        }
        picker.geometry?.firstMaterial?.diffuse.contents = img
        if let head {
            let f = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw).act(SIMD3<Float>(0, 0, -1)), yaw = atan2(-f.x, -f.z)
            picker.simdPosition = SIMD3(head.px - sin(yaw) * 0.8, head.py - 0.02, head.pz - cos(yaw) * 0.8)
            picker.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        }
        picker.isHidden = false
    }
    var pickerShown: Bool { picker.parent != nil && !picker.isHidden }
    func hitPicker(_ aim: VR4Pose) -> (uv: CGPoint, dist: Float)? {
        guard pickerShown else { return nil }
        let (o, d) = ray(aim)
        let a = picker.simdConvertPosition(o, from: nil), b = picker.simdConvertPosition(o + d * 10, from: nil)
        guard let h = picker.hitTestWithSegment(from: SCNVector3(a), to: SCNVector3(b), options: [SCNHitTestOption.backFaceCulling.rawValue: false]).first else { return nil }
        rememberPointerSurface(h, aim: aim)
        let t = h.textureCoordinates(withMappingChannel: 0)
        return (CGPoint(x: t.x, y: t.y), simd_distance(o, h.simdWorldCoordinates))
    }

    // MARK: desktop screen inside the dashboard
    private var screenRect = CGRect.zero
    /// Live Mac screen laid exactly over `rect` (dashboard canvas px, horizontally centred) so pointer uv maps 1:1.
    private var screenMip: MTLTexture?, lastScreenPB: CVPixelBuffer?
    func setScreen(_ pb: CVPixelBuffer?, rect: CGRect) {
        guard let pb, let tex = mipmapped(pb) else { screen.isHidden = true; return }
        if rect != screenRect || screen.geometry == nil {
            screenRect = rect
            let m = metersPerPx
            screenBend = bend[ObjectIdentifier(panel)] ?? radius / layout.win
            screen.geometry = Compositor.bent(w: Float(rect.width) * m, h: Float(rect.height) * m, r: screenBend)
            screen.position = SCNVector3(0, CGFloat((Float(Dashboard.SPLIT) / 2 - Float(rect.midY)) * m), 0.004)
        }
        if let m = screen.geometry?.firstMaterial {
            m.diffuse.contents = tex; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16
        }
        screen.isHidden = false
    }
    /// Retina desktop shown much smaller than its pixels: without mipmaps text aliases into mush, so each new capture
    /// is copied into a mipmapped texture (same queue as rendering, so it's ready before the next eye render).
    private func mipmapped(_ pb: CVPixelBuffer) -> MTLTexture? {
        if avgBuf == nil { avgBuf = device.makeBuffer(length: 4, options: .storageModeShared) }
        return mipmap(pb, &screenMip, &lastScreenPB, average: avgBuf)
    }
    /// Copies a new capture into `store` (a mipmapped texture it keeps per source) unless `last` is that same buffer.
    /// `average`: also copy the 1x1 mip there, the picture's average colour (the theater's light spill reads it a frame later).
    private func mipmap(_ pb: CVPixelBuffer, _ store: inout MTLTexture?, _ last: inout CVPixelBuffer?, average: MTLBuffer? = nil) -> MTLTexture? {
        guard let src = texture(pb, .bgra8Unorm_srgb) else { return nil }
        if pb !== last {
            last = pb
            if store?.width != src.width || store?.height != src.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: src.width, height: src.height, mipmapped: true)
                d.usage = .shaderRead; d.storageMode = .private
                store = device.makeTexture(descriptor: d)
            }
            if let m = store, let cb = cq.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, to: m, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
                blit.generateMipmaps(for: m)
                if let b = average { blit.copy(from: m, sourceSlice: 0, sourceLevel: m.mipmapLevelCount - 1, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                                                to: b, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4) }
                blit.endEncoding(); cb.commit()
            }
        }
        return store
    }
    private var avgBuf: MTLBuffer?
    /// Average colour of the last screen capture (linear RGB, 0-1), from its smallest mip.
    var screenAverage: SIMD3<Float> {
        guard let p = avgBuf?.contents().assumingMemoryBound(to: UInt8.self) else { return .zero }
        func lin(_ v: UInt8) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return SIMD3(lin(p[2]), lin(p[1]), lin(p[0]))   // BGRA
    }

    // MARK: theater mode: flatscreen games / the Mac on a big screen. Size, curve and room lights from Settings;
    // in a dark room the picture's colour spills onto the floor and glows around the screen.
    private let theater = SCNNode(), spill = SCNNode(), halo = SCNNode()
    private var theaterAspect: CGFloat = 0, spillColor = SIMD3<Float>(0, 0, 0)
    struct TheaterStyle: Equatable { var width: Float = 6.4, distance: Float = 5, lift: Float = 0.3, curved = true, lights = "Dark" }
    /// Settings > Theater: screen size preset, curve, and room lights (Dark, Dim, Home).
    private(set) var theaterStyle = TheaterStyle()
    static func theaterStyle(screen: String, curved: Bool, lights: String) -> TheaterStyle {
        let p: [String: (Float, Float, Float)] = ["Small": (2.0, 2.2, 0), "Medium": (3.6, 3.4, 0.1), "Large": (6.4, 5, 0.3), "IMAX": (13, 8, 1.4)]
        let (w, d, l) = p[screen] ?? p["Large"]!
        return TheaterStyle(width: w, distance: d, lift: l, curved: curved, lights: lights)
    }
    func setTheaterStyle(_ s: TheaterStyle) {
        guard s != theaterStyle else { return }
        let lightsChanged = s.lights != theaterStyle.lights
        theaterStyle = s; theater.geometry = nil; theaterAspect = 0   // rebuilt (and re-placed by the caller's `head`) on the next frame
        if lightsChanged && !theater.isHidden { applyTheaterLights() }
    }
    private func applyTheaterLights() {
        let s = theaterStyle
        fadeFromCurrentSky()
        scene.background.contents = s.lights == "Dark" ? NSColor(white: 0.015, alpha: 1) : s.lights == "Dim" ? dimmedPanorama() : skyContents ?? Compositor.sky()
        grid.isHidden = s.lights != "Home" || !gridOn || !voidEnv
    }
    /// Theater "Dim" lights: a dark sphere just inside the sky (fades with the transitions).
    /// Theater "Dim" lights: the home panorama, darkened (a 2048 px copy, made once per Space).
    private var dimmedSky: (name: String, image: CGImage)?
    private func dimmedPanorama() -> Any {
        if let d = dimmedSky, d.name == envName { return d.image }
        let src = skyContents ?? Compositor.sky()   // NSImage panorama, or the procedural CGImage (`as? CGImage` can't tell)
        guard let cg = src is NSImage ? (src as! NSImage).cgImage(forProposedRect: nil, context: nil, hints: nil) : (src as! CGImage),
              let c = CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return src }
        c.interpolationQuality = .medium
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 2048, height: 1024))
        c.setFillColor(CGColor(gray: 0, alpha: 0.6)); c.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))   // sRGB 0.4 = ~16% light
        guard let img = c.makeImage() else { return src }
        dimmedSky = (envName, img); return img
    }
    /// nil hides the theater (and restores the home environment). `head` re-centres the screen in front of you.
    func setTheater(_ pb: CVPixelBuffer?, head: VR4Pose?) {
        if theater.parent == nil {
            scene.rootNode.addChildNode(theater); theater.isHidden = true
            for (n, img, order) in [(spill, Compositor.glow(soft: 0.5), -5), (halo, Compositor.glow(soft: 0.12), -6)] {
                let g = SCNPlane(width: 1, height: 1), m = g.firstMaterial!
                m.diffuse.contents = img; m.lightingModel = .constant; m.blendMode = .add; m.writesToDepthBuffer = false; m.isDoubleSided = true
                n.geometry = g; n.renderingOrder = order; theater.addChildNode(n)
            }
        }
        guard let pb, let tex = mipmapped(pb) else {
            if !theater.isHidden { theater.isHidden = true; let e = envName; envName = ""; setEnvironment(e) }
            return
        }
        let s = theaterStyle, aspect = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(max(1, CVPixelBufferGetHeight(pb))), h = s.width / Float(aspect)
        if aspect != theaterAspect || theater.geometry == nil {
            theaterAspect = aspect
            theater.geometry = Compositor.bent(w: s.width, h: h, r: s.distance, seg: 96, curve: s.curved)
            theater.geometry?.firstMaterial?.lightingModel = .constant
            // light spill: a pool on the floor in front of the screen, and a halo just behind its edges
            spill.simdScale = SIMD3(s.width * 1.3, s.distance * 1.2, 1); spill.simdEulerAngles = SIMD3(-.pi / 2, 0, 0)
            halo.simdScale = SIMD3(s.width * 1.35, h * 1.6, 1); halo.simdPosition = SIMD3(0, 0, -0.05)
        }
        if theater.isHidden || head != nil, let head {   // entering: put the screen ahead at eye height (plus the preset's lift)
            let f = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw).act(SIMD3<Float>(0, 0, -1)), yaw = atan2(-f.x, -f.z)
            theater.simdPosition = SIMD3(head.px - sin(yaw) * s.distance, head.py + s.lift, head.pz - cos(yaw) * s.distance)
            theater.simdEulerAngles = SIMD3(0, yaw, 0)
            spill.simdPosition = SIMD3(0, 0.01 - theater.simdPosition.y, s.distance * 0.4)   // on the floor, between you and the screen
        }
        if theater.isHidden { theater.isHidden = false; applyTheaterLights() }
        if let m = theater.geometry?.firstMaterial { m.diffuse.contents = tex; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16 }
        // the spill follows the picture's average colour, smoothed so cuts don't strobe the room
        spillColor += (screenAverage - spillColor) * (reduceMotion ? 1 : 0.12)
        let k: Float = s.lights == "Dark" ? 1 : 0, c = spillColor * k   // only a dark room shows the spill
        for (n, gain) in [(spill, Float(0.16)), (halo, Float(0.3))] {   // linear light added to the room, then sRGB for the material
            n.isHidden = k == 0
            let l = simd_min(c * gain, SIMD3(repeating: 1)), e = SIMD3(pow(l.x, 1 / 2.2), pow(l.y, 1 / 2.2), pow(l.z, 1 / 2.2))
            n.geometry?.firstMaterial?.multiply.contents = NSColor(srgbRed: CGFloat(e.x), green: CGFloat(e.y), blue: CGFloat(e.z), alpha: 1)
        }
    }
    /// White radial falloff (centre bright, transparent edge); `soft` = how far in from the edge the fade starts.
    static func glow(soft: CGFloat) -> CGImage {
        let c = overlayCanvas(256, 256)
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1 - soft, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: 128, y: 128), startRadius: 0, endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        return c.makeImage()!
    }
    /// Pointer on the theater screen -> normalized point on the Mac display (0-1, top-left) + distance.
    func theaterHit(_ aim: VR4Pose) -> (uv: CGPoint, dist: Float)? {
        guard !theater.isHidden, theater.geometry != nil else { return nil }
        let (o, d) = ray(aim)
        let a = theater.simdConvertPosition(o, from: nil), b = theater.simdConvertPosition(o + d * 30, from: nil)
        guard let h = theater.hitTestWithSegment(from: SCNVector3(a), to: SCNVector3(b), options: [SCNHitTestOption.backFaceCulling.rawValue: false]).first
        else { return nil }
        rememberPointerSurface(h, aim: aim)
        return (h.textureCoordinates(withMappingChannel: 0), simd_distance(o, h.simdWorldCoordinates))
    }

    // MARK: game behind the menu
    private var backdrop: [SCNNode] = []
    private var backdropPB: CVPixelBuffer?   // keeps the pool from recycling the frame while it is on screen
    private var skyContents: Any?
    /// Shows the running game (dimmed) behind the menu: each eye's half of `pb` on a quad placed in that eye's
    /// rendered frustum, so turning the head reveals it world-locked instead of head-locked. nil = back to the home void.
    func setGameBackdrop(_ pb: CVPixelBuffer?, poses: [VR4Pose], fovs: [VR4Fov]) {
        if backdrop.isEmpty {
            for i in 0..<2 {
                let n = SCNNode(geometry: SCNPlane(width: 1, height: 1))
                let m = n.geometry!.firstMaterial!
                m.lightingModel = .constant; m.isDoubleSided = true; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = false
                m.multiply.contents = NSColor(white: 0.55, alpha: 1)   // dim the game under the menu
                n.renderingOrder = -100; n.categoryBitMask = 1 << (i + 2)
                scene.rootNode.addChildNode(n); backdrop.append(n)
                eyes[i].camera!.categoryBitMask = ~(1 << ((1 - i) + 2))   // each eye sees only its own half
            }
            skyContents = scene.background.contents
        }
        guard let pb, poses.count == 2, fovs.count == 2, let tex = texture(pb, .bgra8Unorm_srgb) else {
            backdrop.forEach { $0.isHidden = true; $0.geometry?.firstMaterial?.diffuse.contents = nil }; backdropPB = nil
            if scene.background.contents == nil { scene.background.contents = skyContents; grid.isHidden = !gridOn }
            return
        }
        backdropPB = pb
        scene.background.contents = nil; grid.isHidden = true
        let dist: Float = 20
        for i in 0..<2 {
            let n = backdrop[i], f = fovs[i], p = poses[i]
            let l = tan(f.left) * dist, r = tan(f.right) * dist, u = tan(f.up) * dist, d = tan(f.down) * dist
            let q = simd_quatf(ix: p.qx, iy: p.qy, iz: p.qz, r: p.qw)
            n.simdOrientation = q
            n.simdPosition = SIMD3(p.px, p.py, p.pz) + q.act(SIMD3((l + r) / 2, (u + d) / 2, -dist))
            n.simdScale = SIMD3(r - l, u - d, 1)
            let m = n.geometry!.firstMaterial!
            m.diffuse.contents = tex
            m.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(0.5, 1, 1), CGFloat(i) * 0.5, 0, 0)
            n.isHidden = false
        }
    }

    // MARK: input
    /// Ray from a hand's aim pose against the dashboard panel -> texture uv (origin top-left) + distance.
    /// Nearest hit on the window or dock panel. Their texture coords are already canvas uv (origin top-left).
    /// `slot`: 1 = the main canvas (centre window, dock, keyboard), 0 / 2 = the left / right window's own canvas.
    func hit(_ aim: VR4Pose, solid: (CGPoint, Int) -> Bool) -> (uv: CGPoint, dist: Float, slot: Int)? {
        guard !dash.isHidden, panel.geometry != nil else { return nil }
        let (o, d) = ray(aim)
        var best: (uv: CGPoint, dist: Float, slot: Int)?
        for (n, slot) in [(panel, 1), (dockPanel, 1), (kbPanel, 1), (sides[0], 0), (sides[1], 2)] where !(n === kbPanel && kbNode.isHidden) && !n.isHidden && !(n.parent?.isHidden ?? false) {
            let a = n.simdConvertPosition(o, from: nil), b = n.simdConvertPosition(o + d * 10, from: nil)
            for h in n.hitTestWithSegment(from: SCNVector3(a), to: SCNVector3(b), options: [SCNHitTestOption.backFaceCulling.rawValue: false]) {
                let dist = simd_distance(o, h.simdWorldCoordinates), uv = h.textureCoordinates(withMappingChannel: 0)
                if solid(uv, slot), dist < best?.dist ?? .infinity { best = (uv, dist, slot); rememberPointerSurface(h, aim: aim) }   // lasers pass through transparent gaps
            }
        }
        return best
    }

    // MARK: direct touch
    struct Touch { let uv: CGPoint; let depth: Float; let normal: SIMD3<Float>; var slot = 1 }
    /// Where hand `i`'s index fingertip is against the menu: canvas uv, depth along the panel normal (metres, positive
    /// in front of it, negative pushed through) and the panel's outward normal. nil if not over a panel.
    func touch(_ i: Int, grip: VR4Pose) -> Touch? {
        guard !dash.isHidden, panel.geometry != nil, let hm = handModels[i] else { return nil }
        var g = simd_float4x4(simd_quatf(ix: grip.qx, iy: grip.qy, iz: grip.qz, r: grip.qw)); g.columns.3 = SIMD4(grip.px, grip.py, grip.pz, 1)
        if hm.isTracked { g = matrix_identity_float4x4 }
        let tip4 = g * SIMD4(hm.indexTip, 1), tip = SIMD3(tip4.x, tip4.y, tip4.z)
        let m = metersPerPx, w = Float(Dashboard.W) * m, h = Float(Dashboard.H) * m, sp = Compositor.split, sp2 = Compositor.split2
        var best: Touch?
        for (n, v0, v1, slot) in [(panel, Float(0), sp, 1), (dockPanel, sp, sp2, 1), (kbPanel, sp2, Float(1), 1), (sides[0], Float(0), Float(1), 0), (sides[1], Float(0), Float(1), 2)]
            where !(n === kbPanel && kbNode.isHidden) && !n.isHidden {
            let p = n.simdConvertPosition(tip, from: nil), ph = slot == 1 ? h * (v1 - v0) : h * sp, r = bend[ObjectIdentifier(n)] ?? radius
            let a = Compositor.curved ? asin(max(-1, min(1, p.x / r))) : 0
            let zs = Compositor.curved ? r - r * cos(a) : 0
            let u = Compositor.curved ? a * r / w + 0.5 : p.x / w + 0.5, vl = 0.5 - p.y / ph
            guard u >= 0, u <= 1, vl >= 0, vl <= 1 else { continue }
            let nl = Compositor.curved ? SIMD3(-sin(a), 0, cos(a)) : SIMD3<Float>(0, 0, 1)
            let scale = simd_length(n.simdConvertVector(SIMD3(1, 0, 0), to: nil))
            let d = simd_dot(p - SIMD3(p.x, p.y, zs), nl) * scale
            guard d > -0.08, d < 0.15, abs(d) < abs(best?.depth ?? .infinity) else { continue }
            best = Touch(uv: CGPoint(x: CGFloat(u), y: CGFloat(v0 + vl * (v1 - v0))), depth: d, normal: simd_normalize(n.simdConvertVector(nl, to: nil)), slot: slot)
        }
        return best
    }

    var lasersAlways = false   // theater: lasers drive the Mac even with the menu closed
    /// `push`: offset holding a hand (and its controller) on a panel it touches. `poke`: hand near the menu points its
    /// index (and hides its laser).
    var skinTone = "Original" { didSet { if skinTone != oldValue { mirrorMaterials.removeAll() } } }
    var showBody = false, showMirror = false
    private let avatarBody = SCNNode(), avatarReflection = SCNNode(), homeMirror = SCNNode()
    private var reflectedHands: [SCNNode] = []
    private var mirrorMaterials: [ObjectIdentifier: SCNMaterial] = [:]
    private var proximity: [ObjectIdentifier: Float] = [:]
    private var torsoYaw: Float?
    private var avatarTime = CACurrentMediaTime()
    /// Extend the original arm shoulder boundary loops into one connected chest/waist surface.
    private func updateTorsoMesh() {
        guard showBody, handModels.count == 2, let left = handModels[0], let right = handModels[1] else { return }
        var loopOrder: [[Int]] = [[], []]
        let loops = [left.shoulderRim, right.shoulderRim].enumerated().map { side, ring -> [SIMD3<Float>] in
            var points = ring.map { avatarBody.simdConvertPosition($0, from: nil) }
            guard points.count == 8 else { return [] }
            var center = points.reduce(SIMD3<Float>.zero, +) / 8
            if hands[side].grip.isHidden {
                // Keep the torso's shoulder seam stable when one controller loses tracking.
                let target = SIMD3<Float>(side == 0 ? -0.16 : 0.16, 0.59, 0)
                let normal = simd_normalize(simd_cross(points[1] - points[0], points[2] - points[0]))
                let rotation = simd_quatf(from: normal, to: SIMD3<Float>(side == 0 ? -1 : 1, 0, 0))
                points = points.map { target + rotation.act($0 - center) }; center = target
            }
            let order = points.indices.sorted { atan2(points[$0].z - center.z, points[$0].y - center.y) < atan2(points[$1].z - center.z, points[$1].y - center.y) }
            loopOrder[side] = order.map { [left, right][side].shoulderVertexIndices[$0] }
            return order.map { points[$0] }
        }
        guard loops.allSatisfy({ $0.count == 8 }) else { return }
        var vertices = loops[0] + loops[1], indices: [Int32] = []
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int) { indices += [a, b, c, a, c, d].map(Int32.init) }
        // Connect the upper shoulder arcs across the chest. Remaining arcs form the torso perimeter.
        for i in 2..<6 { quad(i, i + 1, 8 + i + 1, 8 + i) }
        var perimeter = [6, 7, 0, 1, 2, 10, 9, 8, 15, 14]
        let source = perimeter.map { vertices[$0] }
        for (y, width, depth) in [(Float(0.38), Float(0.155), Float(0.085)), (0.20, 0.125, 0.07), (0.02, 0.135, 0.08)] {
            var next: [Int] = []
            for i in source.indices {
                // Sculpt the continued shoulder perimeter into full chest/waist cross-sections.
                let angle = Float.pi / 2 + Float(i) * 2 * .pi / Float(source.count)
                next.append(vertices.count); vertices.append(SIMD3(cos(angle) * width, y, sin(angle) * depth))
            }
            for i in perimeter.indices { let j = (i + 1) % perimeter.count; quad(perimeter[i], perimeter[j], next[j], next[i]) }
            perimeter = next
        }
        // Weld torso faces to the existing arm vertex indices, then include the original skinned hands/arms.
        var welded: [SIMD3<Float>] = [], armIndices: [Int32] = [], remap: [Int] = []
        for (side, model) in [left, right].enumerated() {
            let offset = welded.count
            let points = model.posedVertices.map { avatarBody.simdConvertPosition(model.node.simdConvertPosition($0, to: nil), from: nil) }
            welded += points
            for (point, originalIndex) in zip(loops[side], loopOrder[side]) {
                remap.append(offset + originalIndex)
                welded[offset + originalIndex] = point
            }
            if !hands[side].grip.isHidden { armIndices += model.torsoTriangles.map { $0 + Int32(offset) } }
        }
        for i in 16..<vertices.count { remap.append(welded.count); welded.append(vertices[i]) }
        indices = armIndices + indices.map { Int32(remap[Int($0)]) }
        vertices = welded
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2]), n = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices.map { SCNVector3($0) }), SCNGeometrySource(normals: normals.map { SCNVector3(simd_length_squared($0) > 1e-14 ? simd_normalize($0) : SIMD3(0, 1, 0)) })], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        // Match hand shading with smooth vertex normals along the shared shoulder rim.
        g.materials = [left.node.geometry?.firstMaterial ?? SCNMaterial()]; g.subdivisionLevel = 0
        avatarBody.childNodes.first?.geometry = g
        avatarBody.childNodes.first?.renderingOrder = 150
    }
    private func buildAvatar() {
        guard avatarBody.parent == nil else { return }
        avatarBody.addChildNode(SCNNode()) // torso geometry extends the original shoulder rings each frame
        scene.rootNode.addChildNode(avatarBody); scene.rootNode.addChildNode(avatarReflection); scene.rootNode.addChildNode(homeMirror)
        avatarReflection.simdPosition = SIMD3(0, 0, -3); avatarReflection.simdScale = SIMD3(1, 1, -1)
        // Reflection plane is fixed at z=-1.5; reflected geometry is clipped to the mirror aperture.
        for (x, y, w, h) in [(Float(-0.73), Float(1.15), 0.06, 2.1), (0.73, 1.15, 0.06, 2.1), (0, 0.12, 1.5, 0.06), (0, 2.18, 1.5, 0.06)] {
            let frame = SCNNode(geometry: SCNBox(width: w, height: h, length: 0.04, chamferRadius: 0.02))
            frame.simdPosition = SIMD3(x, y, -1.5); frame.geometry?.firstMaterial?.diffuse.contents = NSColor.darkGray; homeMirror.addChildNode(frame)
        }
        let glass = SCNNode(geometry: SCNPlane(width: 1.4, height: 2)); glass.simdPosition = SIMD3(0, 1.15, -1.49)
        glass.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.8, alpha: 0.12)
        glass.geometry?.firstMaterial?.writesToDepthBuffer = false; glass.geometry?.firstMaterial?.isDoubleSided = true; glass.geometry?.firstMaterial?.blendMode = .alpha
        homeMirror.addChildNode(glass)
        for _ in 0..<2 { let n = SCNNode(); avatarReflection.addChildNode(n); reflectedHands.append(n) }
    }
    private func mirrorGeometry(_ source: SCNGeometry, head: SIMD3<Float>) -> SCNGeometry {
        // Preserve SceneKit primitive dimensions and subdivision. The reflected
        // renderer handles reflected transforms; retain exterior faces only.
        let g = source.copy() as! SCNGeometry
        g.materials = source.materials.map { original in
            let key = ObjectIdentifier(original)
            if let cached = mirrorMaterials[key] {
                cached.setValue(NSValue(scnVector3: SCNVector3(head)), forKey: "mirrorEye")
                cached.diffuse.contents = original.diffuse.contents
                cached.setValue(NSValue(scnVector3: SCNVector3(homeOffset + SIMD3(0, 1.15, -1.5))), forKey: "mirrorCenter")
                return cached
            }
            let m = original.copy() as! SCNMaterial
            var shaders = m.shaderModifiers ?? [:]
            shaders[.geometry] = "#pragma varyings\nfloat3 mirrorWorld;\n#pragma body\nout.mirrorWorld = (scn_node.modelTransform * _geometry.position).xyz;"
            var fragment = shaders[.fragment] ?? "#pragma body\n"
            if fragment.contains("#pragma arguments") { fragment = fragment.replacingOccurrences(of: "#pragma arguments", with: "#pragma arguments\nfloat3 mirrorEye;\nfloat3 mirrorCenter;") }
            else { fragment = "#pragma arguments\nfloat3 mirrorEye;\nfloat3 mirrorCenter;\n" + fragment }
            fragment += "\nfloat dz = in.mirrorWorld.z - mirrorEye.z;\nfloat hitT = (mirrorCenter.z - mirrorEye.z) / (abs(dz) < 0.0001 ? 0.0001 : dz);\nfloat3 hit = mirrorEye + hitT * (in.mirrorWorld - mirrorEye);\nif (hitT <= 0.0 || hitT >= 1.0 || abs(hit.x - mirrorCenter.x) > 0.7 || abs(hit.y - mirrorCenter.y) > 1.0) discard_fragment();"
            shaders[.fragment] = fragment; m.shaderModifiers = shaders
            m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false
            m.setValue(NSValue(scnVector3: SCNVector3(head)), forKey: "mirrorEye"); m.isDoubleSided = false; m.cullMode = .back
            m.setValue(NSValue(scnVector3: SCNVector3(homeOffset + SIMD3(0, 1.15, -1.5))), forKey: "mirrorCenter")
            mirrorMaterials[key] = m
            return m
        }
        return g
    }
    private func updateAvatar(_ t: VR4Tracking) {
        buildAvatar()
        let head = (SIMD3(t.eye.0.pose.px, t.eye.0.pose.py, t.eye.0.pose.pz) + SIMD3(t.eye.1.pose.px, t.eye.1.pose.py, t.eye.1.pose.pz)) / 2
        let p = t.eye.0.pose, direction = simd_quatf(ix: p.qx, iy: p.qy, iz: p.qz, r: p.qw).act(SIMD3<Float>(0, 0, -1))
        let orientation = simd_quatf(ix: p.qx, iy: p.qy, iz: p.qz, r: p.qw)
        let yaw = atan2(-direction.x, -direction.z)
        let previous = torsoYaw ?? yaw, delta = atan2(sin(yaw - previous), cos(yaw - previous))
        torsoYaw = previous + (abs(delta) > 0.45 ? delta * 0.06 : 0)
        let pitch = asin(simd_clamp(direction.y, -1, 1)), roll = atan2(orientation.act(SIMD3<Float>(0, 1, 0)).x, orientation.act(SIMD3<Float>(0, 1, 0)).y)
        let torsoRotation = simd_quatf(angle: torsoYaw!, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: simd_clamp(pitch * 0.22, -0.22, 0.22), axis: SIMD3(1, 0, 0)) * simd_quatf(angle: simd_clamp(-roll * 0.15, -0.12, 0.12), axis: SIMD3(0, 0, 1))
        let neck = head + orientation.act(SIMD3<Float>(0, -0.11, 0.10))
        avatarBody.simdOrientation = torsoRotation
        avatarBody.simdPosition = neck + torsoRotation.act(SIMD3<Float>(0, -0.66, 0.055))
        homeMirror.simdPosition = homeOffset
        avatarReflection.simdPosition = SIMD3(0, 0, 2 * (homeOffset.z - 1.5))
        let home = scene.background.contents != nil && !homeOccluded
        avatarBody.isHidden = !showBody || !home; homeMirror.isHidden = !showMirror || !home; avatarReflection.isHidden = homeMirror.isHidden
        if showBody {
            let shoulderHead = neck + torsoRotation.act(SIMD3<Float>(0, 0.11, -0.10))
            let torsoForward = simd_quatf(angle: torsoYaw!, axis: SIMD3<Float>(0, 1, 0)).act(SIMD3<Float>(0, 0, -1))
            for i in handModels.indices where !hands[i].grip.isHidden { handModels[i]?.updateArm(head: shoulderHead, forward: torsoForward) }
        }
        updateTorsoMesh()
        // Copy live skinned geometry; reflect world poses, preserving each hand's full rig.
        for i in handModels.indices where !avatarReflection.isHidden {
            reflectedHands[i].renderingOrder = 5
            reflectedHands[i].geometry = handModels[i]?.node.geometry.map { mirrorGeometry($0, head: head) }
            reflectedHands[i].simdTransform = handModels[i]?.node.simdWorldTransform ?? matrix_identity_float4x4
            reflectedHands[i].isHidden = hands[i].grip.isHidden || showBody
        }
        // Keep one reflected body, updated as options change.
        if avatarReflection.childNode(withName: "Reflected torso", recursively: false) == nil { let clone = avatarBody.clone(); clone.name = "Reflected torso"; avatarReflection.addChildNode(clone) }
        let body = avatarReflection.childNode(withName: "Reflected torso", recursively: false)!; body.simdTransform = avatarBody.simdTransform; body.isHidden = avatarBody.isHidden
        for (n, original) in zip(body.childNodes, avatarBody.childNodes) where !avatarReflection.isHidden {
            n.renderingOrder = 5
            if let geometry = original.geometry { n.geometry = mirrorGeometry(geometry, head: head) }
        }
        let now = CACurrentMediaTime(), alpha = Float(1 - exp(-min(0.05, now - avatarTime) * 10)); avatarTime = now
        var surfaces = [panel, dockPanel, kbPanel, picker, theater]
        for side in sides { side.enumerateChildNodes { node, _ in if node.geometry != nil { surfaces.append(node) } } }
        surfaces += windowPanels.values.flatMap { [$0.content, $0.bar] }
        for ui in surfaces {
            guard let geometry = ui.geometry else { continue }
            // Signed panel-local distance and aperture checks avoid fading distant panels beside the head.
            let local = ui.simdConvertPosition(head, from: nil), bounds = ui.boundingBox
            let inside = local.x >= Float(bounds.min.x) - 0.12 && local.x <= Float(bounds.max.x) + 0.12 && local.y >= Float(bounds.min.y) - 0.12 && local.y <= Float(bounds.max.y) + 0.12
            let distance = abs(local.z)
            let target: Float = inside ? simd_clamp((0.25 - distance) / 0.17, 0, 1) : 0
            let id = ObjectIdentifier(ui), old = proximity[id] ?? 0, value = old + (target - old) * alpha; proximity[id] = value
            ui.opacity = CGFloat(1 - value * 0.9)
            for material in geometry.materials {
                material.writesToDepthBuffer = false
                material.emission.contents = NSColor(calibratedWhite: CGFloat(value), alpha: 1)
            }
        }
        // All dashboard surfaces leave the controller depth intact for pointer occlusion.
        dash.enumerateChildNodes { n, _ in n.geometry?.materials.forEach { $0.writesToDepthBuffer = false } }
    }
    var showArms = false
    func updateHands(_ t: VR4Tracking, rays: [Float?], push: [SIMD3<Float>] = [.zero, .zero], poke: [Bool] = [false, false]) {
        defer {
            pointerSurfaces.removeAll(keepingCapacity: true)
            let pose = t.eye.0.pose
            let head = (SIMD3(pose.px, pose.py, pose.pz) + SIMD3(t.eye.1.pose.px, t.eye.1.pose.py, t.eye.1.pose.pz)) / 2
            var forward = simd_quatf(ix: pose.qx, iy: pose.qy, iz: pose.qz, r: pose.qw).act(SIMD3<Float>(0, 0, -1)); forward.y = 0
            forward = simd_length_squared(forward) > 0.001 ? simd_normalize(forward) : SIMD3(0, 0, -1)
            let tracked = [t.hand.0, t.hand.1]
            for i in handModels.indices where !hands[i].grip.isHidden {
                handModels[i]?.updateRestPose(tracked[i], head: head, forward: forward)
                if !showBody { handModels[i]?.updateArm(head: head, forward: forward) }
            }
        }
        tickSlots()   // runs every frame: window snap animation
        let hs = [t.hand.0, t.hand.1]
        for (i, h) in hs.enumerated() {
            let valid = h.flags & UInt32(VR4_HAND_POSE_VALID) != 0
            let n = hands[i]
            n.grip.isHidden = !valid || (scene.background.contents == nil && dash.isHidden); n.aim.isHidden = !valid || (dash.isHidden && !lasersAlways && rays[i] == nil)   // menu closed: only onto a pinned window
            let hm = handModels.count > i ? handModels[i] : nil
            hm?.showArms = showArms || showBody
            hm?.showTorso = showBody
            hm?.node.opacity = showBody && !homeOccluded && scene.background.contents != nil ? 0 : 1
            hm?.skinTone = skinTone
            for c in n.grip.childNodes where c !== hm?.node { c.isHidden = joints[i] != nil }   // tracked hand: no controller
            if let j = joints[i], let hm {   // hand tracking: the grip node only carries the direct-touch push
                var g = matrix_identity_float4x4; g.columns.3 = SIMD4(push[i], 1); n.grip.simdTransform = g
                hm.track(j.map { SIMD3($0.px, $0.py, $0.pz) })
                if poke[i] { n.aim.isHidden = true }
                setLaser(n, h, rays[i])
                continue
            }
            hm?.untrack()
            var g = simd_float4x4(simd_quatf(ix: h.grip.qx, iy: h.grip.qy, iz: h.grip.qz, r: h.grip.qw)); g.columns.3 = SIMD4(SIMD3(h.grip.px, h.grip.py, h.grip.pz) + push[i], 1)
            n.grip.simdTransform = g
            let h = demo(h, hand: i), pk = demoPose == "poke" || demoPose == "cycle" && Int(CACurrentMediaTime() / 1.6) % 10 == 9 ? true : poke[i]
            if valid { rigs[i].update(h); handModels[i]?.update(h, targets: rigs[i].targets(), poke: pk) }
            if poke[i] { n.aim.isHidden = true }
            setLaser(n, h, rays[i])
        }
    }
    private struct PointerSurface {
        let origin, direction, position, normal, up: SIMD3<Float>
        let distance: Float
    }
    private var pointerSurfaces: [PointerSurface] = []
    private func rememberPointerSurface(_ hit: SCNHitTestResult, aim: VR4Pose) {
        let (origin, direction) = ray(aim)
        var normal = simd_normalize(hit.simdWorldNormal)
        if simd_dot(normal, direction) > 0 { normal = -normal }
        pointerSurfaces.append(PointerSurface(origin: origin, direction: direction,
            position: hit.simdWorldCoordinates, normal: normal,
            up: hit.node.simdConvertVector(SIMD3(0, 1, 0), to: nil),
            distance: simd_distance(origin, hit.simdWorldCoordinates)))
        if pointerSurfaces.count > 64 { pointerSurfaces.removeFirst() }
    }
    private func pointerSurface(aim: VR4Pose, distance: Float) -> PointerSurface? {
        let (origin, direction) = ray(aim)
        return pointerSurfaces.filter { simd_distance($0.origin, origin) < 0.001 && simd_distance($0.direction, direction) < 0.001 && abs($0.distance - distance) < 0.005 }
            .min { abs($0.distance - distance) < abs($1.distance - distance) }
    }
    /// Surface tangent basis keeps the cursor flush to curved/tilted UI and removes controller roll.
    static func cursorOrientation(normal: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        let z = simd_normalize(normal)
        var y = up - z * simd_dot(up, z)
        if simd_length_squared(y) < 0.000001 {
            let fallback: SIMD3<Float> = abs(z.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
            y = fallback - z * simd_dot(fallback, z)
        }
        y = simd_normalize(y)
        return simd_quatf(simd_float3x3(columns: (simd_normalize(simd_cross(y, z)), y, z)))
    }

    private func setLaser(_ n: (grip: SCNNode, aim: SCNNode, laser: SCNNode, dot: SCNNode), _ h: VR4Hand, _ ray: Float?) {
        n.aim.simdPosition = SIMD3(h.aim.px, h.aim.py, h.aim.pz); n.aim.simdOrientation = simd_quatf(ix: h.aim.qx, iy: h.aim.qy, iz: h.aim.qz, r: h.aim.qw)
        let tracked = h.flags & UInt32(VR4_HAND_TRACKED) != 0
        n.aim.isHidden = n.aim.isHidden || ray == nil
        let len = ray ?? 0
        // Follow the animated trigger's front surface; retain the original aim hit for targeting.
        var start = tracked ? SIMD3<Float>.zero : n.grip.simdConvertPosition(SIMD3(0, 0.02, -0.04), to: n.aim)
        if !tracked, let trigger = n.grip.childNode(withName: "trigger", recursively: true) {
            let (lo, hi) = trigger.boundingBox
            start = trigger.simdConvertPosition(SIMD3(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z) - 0.006), to: n.aim)
        }
        let destination = SIMD3<Float>(0, 0, -max(0, len - 0.015))
        let vector = destination - start, distance = simd_length(vector)
        n.laser.simdPosition = start
        if distance > 0.001 { n.laser.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: vector / distance) }
        n.laser.simdScale = SIMD3(1, min(0.35, distance), 1)
        n.laser.geometry?.firstMaterial?.setValue(NSNumber(value: min(0.35, distance)), forKey: "rayLen")
        n.laser.opacity = tracked ? 0.35 : 0.8
        n.dot.isHidden = n.aim.isHidden || ray == nil
        n.dot.simdPosition = n.aim.simdConvertPosition(SIMD3(0, 0, -len + 0.002), to: nil)
        if let surface = pointerSurface(aim: h.aim, distance: len) {
            n.dot.simdOrientation = Self.cursorOrientation(normal: surface.normal, up: surface.up)
            n.dot.simdPosition = surface.position + surface.normal * 0.002
        }
        n.dot.simdScale = SIMD3(repeating: max(0.5, len) * 0.06)   // constant angular size (~3.4 deg)
        // pinch progress (Meta-style hand cursor): the ring closes in as thumb and index approach and fills on the pinch.
        // Controllers: the trigger's travel does the same.
        let p = tracked ? min(1, h.trigger / 0.5) : min(1, h.trigger / 0.55), pressed = tracked ? h.trigger >= 1 : h.trigger > 0.55
        n.dot.childNodes[0].simdScale = SIMD3(repeating: 1 - 0.35 * p)
        n.dot.childNodes[1].simdScale = SIMD3(repeating: pressed ? 0.62 : 0.22 + 0.12 * p)
        n.dot.childNodes[1].opacity = pressed ? 0.3 : 0
        let tint = pressed ? NSColor(red: 0.16, green: 0.45, blue: 1, alpha: 1) : NSColor.white
        n.laser.geometry?.firstMaterial?.diffuse.contents = tint
        for child in n.dot.childNodes { child.geometry?.firstMaterial?.multiply.contents = tint }
    }
    /// Pointer cursor: a white ring (with a dark rim for contrast on bright panels) around a dot; unit size, drawn on top.
    static func cursor() -> SCNNode {
        func disc(_ ring: Bool) -> SCNNode {
            let c = overlayCanvas(128, 128), r = CGRect(x: 0, y: 0, width: 128, height: 128)
            c.setStrokeColor(CGColor(gray: 0, alpha: 0.35)); c.setFillColor(CGColor(gray: 0, alpha: 0.35))
            if ring { c.setLineWidth(22); c.strokeEllipse(in: r.insetBy(dx: 14, dy: 14)) } else { c.fillEllipse(in: r.insetBy(dx: 2, dy: 2)) }
            c.setStrokeColor(CGColor(gray: 1, alpha: 1)); c.setFillColor(CGColor(gray: 1, alpha: 1))
            if ring { c.setLineWidth(12); c.strokeEllipse(in: r.insetBy(dx: 14, dy: 14)) } else { c.fillEllipse(in: r.insetBy(dx: 8, dy: 8)) }
            let g = SCNPlane(width: 1, height: 1), m = g.firstMaterial!
            m.diffuse.contents = c.makeImage(); m.lightingModel = .constant; m.isDoubleSided = true
            m.readsFromDepthBuffer = false; m.writesToDepthBuffer = false; m.blendMode = .alpha
            let n = SCNNode(geometry: g); n.renderingOrder = 200; return n
        }
        let n = SCNNode(); n.addChildNode(disc(true)); n.addChildNode(disc(false)); return n
    }
    /// Hand-tracking joints per hand (render queue; nil = on a controller).
    var joints: [[VR4Pose]?] = [nil, nil]

    // MARK: rendering
    private func texture(_ pb: CVPixelBuffer, _ fmt: MTLPixelFormat) -> MTLTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        return t.flatMap(CVMetalTextureGetTexture)
    }
    func pixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool); poolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        return pb
    }

    static func projection(_ f: VR4Fov, near n: Float = 0.05, far: Float = 300) -> SCNMatrix4 {
        let l = tan(f.left) * n, r = tan(f.right) * n, u = tan(f.up) * n, d = tan(f.down) * n
        var m = SCNMatrix4()   // column-vector GL projection, transposed into SceneKit's row-vector layout
        m.m11 = CGFloat(2 * n / (r - l)); m.m22 = CGFloat(2 * n / (u - d))
        m.m31 = CGFloat((r + l) / (r - l)); m.m32 = CGFloat((u + d) / (u - d))
        m.m33 = CGFloat(-(far + n) / (far - n)); m.m34 = -1
        m.m43 = CGFloat(-2 * far * n / (far - n))
        return m
    }

    /// Supersampling: the scene renders at 2x per axis and is averaged down (2x2 box) into the stream frame. Panel text is
    /// sampled from a sharper mip level and every edge is anti-aliased.
    static let ss = 2
    private var ssColor: MTLTexture?
    private lazy var downsample: MTLRenderPipelineState? = {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V vtx(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V v; v.p = float4(q * 2 - 1, 0, 1); v.uv = float2(q.x, 1 - q.y); return v; }
        fragment float4 frag(V v [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return t.sample(s, v.uv);   // exactly 2x: one bilinear tap at the centre of each 2x2 block = their average
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vtx"); d.fragmentFunction = lib.makeFunction(name: "frag")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        return try? device.makeRenderPipelineState(descriptor: d)
    }()

    func render(_ t: VR4Tracking, eyeW: Int, eyeH: Int) -> CVPixelBuffer? {
        guard let pb = pixelBuffer(eyeW * 2, eyeH), let color = texture(pb, .bgra8Unorm_srgb) else { return nil }
        // At near-native Quest 3 resolution, another 2x in each dimension
        // renders 33 million pixels per frame and consumes the streaming budget.
        // Retain supersampling for smaller streams, render large streams natively.
        let k = downsample == nil || min(eyeW, eyeH) >= 1792 ? 1 : Compositor.ss
        let W = eyeW * 2 * k, H = eyeH * k
        if depth?.width != W || depth?.height != H {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: W, height: H, mipmapped: false)
            d.usage = .renderTarget; d.storageMode = .private
            depth = device.makeTexture(descriptor: d)
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: W, height: H, mipmapped: false)
            c.usage = [.renderTarget, .shaderRead]; c.storageMode = .private
            ssColor = k > 1 ? device.makeTexture(descriptor: c) : nil
        }
        guard let cb = cq.makeCommandBuffer() else { return nil }
        let target = ssColor ?? color
        animate(); animateSpace(); animateTour(); updateAvatar(t)
        animateTransitions(head: (SIMD3(t.eye.0.pose.px, t.eye.0.pose.py, t.eye.0.pose.pz) + SIMD3(t.eye.1.pose.px, t.eye.1.pose.py, t.eye.1.pose.pz)) / 2)
        for (i, e) in [t.eye.0, t.eye.1].enumerated() {
            eyes[i].simdPosition = SIMD3(e.pose.px, e.pose.py, e.pose.pz)
            eyes[i].simdOrientation = simd_quatf(ix: e.pose.qx, iy: e.pose.qy, iz: e.pose.qz, r: e.pose.qw)
            eyes[i].camera!.projectionTransform = Compositor.projection(e.fov)
            renderer.pointOfView = eyes[i]
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = target
            pd.colorAttachments[0].loadAction = i == 0 ? .clear : .load
            pd.colorAttachments[0].storeAction = .store
            pd.depthAttachment.texture = depth; pd.depthAttachment.loadAction = .clear; pd.depthAttachment.clearDepth = 1; pd.depthAttachment.storeAction = .dontCare
            renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(x: i * eyeW * k, y: 0, width: eyeW * k, height: H), commandBuffer: cb, passDescriptor: pd)
        }
        if let ssColor, let pipe = downsample {
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = color; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
            if let enc = cb.makeRenderCommandEncoder(descriptor: pd) {
                enc.setRenderPipelineState(pipe); enc.setFragmentTexture(ssColor, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
            }
        }
        cb.commit(); cb.waitUntilCompleted()
        return pb
    }

    // MARK: frame overlays: head-locked system UI (performance HUD, toasts, recording light) stamped onto every outgoing
    // frame, home and games alike. Each eye gets its own projection of the overlay's head-space anchor, so it floats at
    // that depth in stereo; the headset's timewarp then keeps it steady.
    typealias Overlay = (image: CGContext, at: SIMD3<Float>)
    /// `eyes`/`fovs`: the poses the frame was rendered with. Images are premultiplied BGRA (`overlayCanvas`), blitted 1:1.
    func stamp(_ pb: CVPixelBuffer, eyes: [VR4Pose], fovs: [VR4Fov], _ items: [Overlay]) {
        guard !items.isEmpty, eyes.count == 2, fovs.count == 2 else { return }
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let H = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb), ew = CVPixelBufferGetWidth(pb) / 2
        func q(_ p: VR4Pose) -> simd_quatf { simd_quatf(ix: p.qx, iy: p.qy, iz: p.qz, r: p.qw) }
        func at(_ p: VR4Pose) -> SIMD3<Float> { SIMD3(p.px, p.py, p.pz) }
        let centre = (at(eyes[0]) + at(eyes[1])) / 2
        for (img, anchor) in items {
            guard let src = img.data else { continue }
            let world = centre + q(eyes[0]).act(anchor)
            for e in 0..<2 {
                let l = q(eyes[e]).inverse.act(world - at(eyes[e])), f = fovs[e]
                guard l.z < -0.05 else { continue }
                let u = (l.x / -l.z - tan(f.left)) / (tan(f.right) - tan(f.left)), v = (tan(f.up) - l.y / -l.z) / (tan(f.up) - tan(f.down))
                guard u.isFinite, v.isFinite else { continue }
                let x0 = e * ew + Int(u * Float(ew)) - img.width / 2, y0 = Int(v * Float(H)) - img.height / 2
                let cx0 = max(x0, e * ew), cy0 = max(y0, 0), cx1 = min(x0 + img.width, (e + 1) * ew), cy1 = min(y0 + img.height, H)
                guard cx1 > cx0, cy1 > cy0 else { continue }
                var top = vImage_Buffer(data: src + (cy0 - y0) * img.bytesPerRow + (cx0 - x0) * 4, height: vImagePixelCount(cy1 - cy0), width: vImagePixelCount(cx1 - cx0), rowBytes: img.bytesPerRow)
                var dst = vImage_Buffer(data: base + cy0 * rb + cx0 * 4, height: top.height, width: top.width, rowBytes: rb)
                vImagePremultipliedAlphaBlend_BGRA8888(&top, &dst, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
    }
    /// Premultiplied BGRA canvas for `stamp` (CoreGraphics y-up; memory rows top-down like the frame).
    static func overlayCanvas(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }
    /// A dark rounded panel with lines of text (and an optional image on the left), sized for `ppm` frame pixels per metre
    /// at 1 m. Line = (text, colour, bold).
    static func overlayPanel(_ lines: [(String, CGColor, Bool)], ppm: Float, textHeight: Float = 0.022, image: CGImage? = nil, dot: CGColor? = nil) -> CGContext {
        let px = CGFloat(textHeight * ppm), pad = px * 0.8, lead = px * 1.35
        let ct = lines.map { l -> CTLine in   // the shell's rounded system type
            var font = NSFont.systemFont(ofSize: px, weight: l.2 ? .semibold : .medium)
            if let d = font.fontDescriptor.withDesign(.rounded) { font = NSFont(descriptor: d, size: px) ?? font }
            return CTLineCreateWithAttributedString(NSAttributedString(string: l.0, attributes: [.font: font, .foregroundColor: NSColor(cgColor: l.1) ?? .white]))
        }
        let textW = ct.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0, textH = lead * CGFloat(lines.count) - (lead - px)
        let imgH = image == nil ? 0 : max(textH, px * 3), imgW = image.map { imgH * CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 0
        let dotW = dot == nil ? 0 : px * 1.3
        let w = pad * 2 + dotW + (image == nil ? 0 : imgW + pad) + textW, h = pad * 2 + max(textH, imgH)
        let c = overlayCanvas(Int(w.rounded(.up)), Int(h.rounded(.up)))
        let r = CGRect(x: 0, y: 0, width: CGFloat(c.width), height: CGFloat(c.height))
        c.addPath(CGPath(roundedRect: r, cornerWidth: min(r.height / 2, px * 1.2), cornerHeight: min(r.height / 2, px * 1.2), transform: nil))
        c.setFillColor(CGColor(srgbRed: 0.07, green: 0.08, blue: 0.1, alpha: 0.86)); c.fillPath()
        var x = pad
        if let dot { c.setFillColor(dot); c.fillEllipse(in: CGRect(x: x, y: r.midY - px * 0.4, width: px * 0.8, height: px * 0.8)); x += dotW }
        if let image {
            let ir = CGRect(x: x, y: (r.height - imgH) / 2, width: imgW, height: imgH)
            c.saveGState(); c.addPath(CGPath(roundedRect: ir, cornerWidth: px * 0.4, cornerHeight: px * 0.4, transform: nil)); c.clip(); c.draw(image, in: ir); c.restoreGState()
            x += imgW + pad
        }
        var y = (r.height + textH) / 2 - px * 0.8   // first baseline
        for l in ct { c.textPosition = CGPoint(x: x, y: y); CTLineDraw(l, c); y -= lead }
        return c
    }

    private var gamePool: CVPixelBufferPool?, gamePoolSize = (0, 0)
    private var scaler: VTPixelTransferSession?
    /// Copy a game frame out of shared memory into an encoder-ready buffer, scaling (GPU) if the game rendered at another size.
    func copyFrame(_ src: UnsafeRawPointer, w: Int, h: Int, outW: Int, outH: Int, rgba: Bool = false) -> CVPixelBuffer? {
        if gamePoolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &gamePool); gamePoolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        guard let gamePool, CVPixelBufferPoolCreatePixelBuffer(nil, gamePool, &pb) == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let dst = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h { memcpy(dst + y * stride, src + y * w * 4, w * 4) }
        if rgba {   // RGBA game swapchain -> BGRA, NEON-fast here instead of a per-pixel loop inside the game
            var buf = vImage_Buffer(data: dst, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
            let map: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&buf, &buf, map, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        if (w, h) == (outW, outH) { return pb }
        if scaler == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &scaler) }
        guard let scaler, let out = pixelBuffer(outW, outH), VTPixelTransferSessionTransferImage(scaler, from: pb, to: out) == noErr else { return nil }
        return out
    }
}

/// Mac desktop capture for the dashboard's desktop tab.
final class DesktopCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    var latest: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return _latest }
    var running: Bool { stream != nil }

    private var starting = false, generation = 0
    func start() {
        guard stream == nil, !starting else { return }
        starting = true; generation += 1
        let gen = generation
        Task {
            defer { DispatchQueue.main.async { self.starting = false } }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first else { return }
            let cfg = SCStreamConfiguration()
            // capture in pixels (Retina), not points, capped at 4K wide: the panel's mipmaps need the real detail
            let backing = Double(NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor ?? 2)
            let scale = min(backing, 3840 / Double(display.width))
            cfg.width = Int(Double(display.width) * scale) / 2 * 2; cfg.height = Int(Double(display.height) * scale) / 2 * 2
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            try? s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "vr4.capture"))
            do {
                try await s.startCapture()
                if gen == generation { stream = s } else { try? await s.stopCapture() }   // stopped while starting
            } catch { NSLog("screen capture failed: \(error)") }
        }
    }
    func stop() {
        generation += 1
        stream?.stopCapture { _ in }
        stream = nil
        lock.lock(); _latest = nil; lock.unlock()
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        lock.lock(); _latest = pb; lock.unlock()
    }
}
