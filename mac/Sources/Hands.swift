import Foundation
import SceneKit
import simd

/// Smoky translucent hands (Horizon OS style) holding the controllers (Resources/hands/hand.obj, a static left hand in metres). Rigged here:
/// a palm root, three bones per finger and three for the thumb, each vertex skinned to its two nearest bones, and
/// every joint a hinge with anatomical limits (nothing bends backwards).
/// On attach the fingers close until they touch that controller's handle; then the pose follows the input every
/// frame: the grip squeezes, the index rests on the trigger while touched (and follows it as it's pulled) or points
/// when lifted, and the thumb finds the stick, thumbrest or pressed face button, or lifts off. Fades out at the wrist.
final class HandModel {
    let node = SCNNode()
    private let left: Bool, meshModel: HeadsetModel
    private let rest: [SIMD3<Float>], restN: [SIMD3<Float>], colors: Data, armColors: Data, element: SCNGeometryElement, handElement: SCNGeometryElement, torsoElement: SCNGeometryElement, material: SCNMaterial
    private let skin: [(Int, Int, Float)]
    private var bones: [Bone]
    private let joints: [[SIMD3<Float>]]
    private let wristPos: SIMD3<Float>
    /// Reveal the original mesh beyond its wrist instead of fading it away.
    var showArms = false { didSet { if showArms != oldValue { apply() } } }
    static func skinColor(_ name: String) -> NSColor { Settings.skinColor(name) }
    var skinTone = "Original" { didSet { if skinTone != oldValue { applyLook() } } }
    var showTorso = false { didSet { if showTorso != oldValue { apply() } } }
    private(set) var posedVertices: [SIMD3<Float>] = []
    private(set) var torsoTriangles: [Int32] = []
    var shoulderVertexIndices: [Int] { rest.indices.filter { rest[$0].y > 0.619 } }
    private var shoulderVertices: [SIMD3<Float>] = []
    var shoulderRim: [SIMD3<Float>] { shoulderVertices.map { node.simdConvertPosition($0, to: nil) } }
    private var armElbow: SIMD3<Float>?, armShoulder: SIMD3<Float>?
    private var bendPole: SIMD3<Float>?
    private var armTime = CACurrentMediaTime()
    /// Analytic two-bone IK, wrist-anchored. Head yaw supplies the shoulder, wrist orientation the pole.
    func updateArm(head: SIMD3<Float>, forward: SIMD3<Float>) {
        guard showArms else { armElbow = nil; armShoulder = nil; bendPole = nil; return }
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0)), side: Float = left ? -1 : 1
        let wrist = node.simdConvertPosition(wristPos, to: nil)
        let shoulder = head + right * side * 0.16 - forward * 0.13 + SIMD3<Float>(0, -0.23, 0)
        let delta = wrist - shoulder, distance = max(0.001, simd_length(delta)), axis = delta / distance
        let forearmHint = simd_normalize(node.simdConvertVector((Self.forearm - Self.wrist) * mirror, to: nil))
        let hint = SIMD3<Float>(0, -1, 0) + right * side * 0.5 - forward * 0.2 + forearmHint * 0.6
        var pole = hint - axis * simd_dot(hint, axis)
        if simd_length_squared(pole) < 0.0001 { pole = right - axis * simd_dot(right, axis) }
        if simd_length_squared(pole) < 0.0001 { pole = simd_cross(axis, SIMD3<Float>(0, 0, 1)) }
        pole = simd_normalize(pole)
        let now = CACurrentMediaTime(), weight = Float(1 - exp(-min(0.05, now - armTime) * 14)); armTime = now
        if let old = bendPole {
            let projected = old - axis * simd_dot(old, axis)
            let mixed = projected * (1 - weight) + pole * weight
            if simd_length_squared(mixed) > 0.0001 { pole = simd_normalize(mixed) }
        }
        bendPole = pole
        // Clamp shoulder reach while keeping the tracked wrist exact; retain both bone lengths.
        let upper: Float = 0.30, lower: Float = 0.27
        let reach = simd_clamp(distance, abs(upper - lower) + 0.005, upper + lower - 0.002)
        let root = wrist - axis * reach
        let along = (upper * upper - lower * lower + reach * reach) / (2 * reach)
        let elbow = root + axis * along + pole * sqrt(max(0, upper * upper - along * along))
        armElbow = node.simdConvertPosition(elbow, from: nil)
        armShoulder = node.simdConvertPosition(root, from: nil)
        apply()
    }
    private var idleAnchor: SIMD3<Float>?, idleRotation: simd_quatf?
    private var lastMovement = CACurrentMediaTime(), restTime = CACurrentMediaTime()
    private var restWeight: Float = 0
    /// Ease the displayed avatar wrist into an A pose; input/controller poses stay tracked.
    func updateRestPose(_ hand: VR4Hand, head: SIMD3<Float>, forward: SIMD3<Float>) {
        guard showArms, !isTracked, let parent = node.parent else {
            idleAnchor = nil; idleRotation = nil; restWeight = 0; lastMovement = CACurrentMediaTime()
            if !isTracked { node.simdTransform = placement }
            return
        }
        let now = CACurrentMediaTime(), dt = min(0.05, max(0, now - restTime)); restTime = now
        let position = SIMD3(hand.grip.px, hand.grip.py, hand.grip.pz)
        let rotation = simd_normalize(simd_quatf(ix: hand.grip.qx, iy: hand.grip.qy, iz: hand.grip.qz, r: hand.grip.qw))
        let moved = idleAnchor.map { simd_distance($0, position) > 0.012 } ?? true
        let turned = idleRotation.map { 2 * acos(min(1, abs(simd_dot($0.vector, rotation.vector)))) > 0.06 } ?? true
        let input = hand.buttons != 0 || hand.trigger > 0.05 || hand.squeeze > 0.05 || abs(hand.stick_x) + abs(hand.stick_y) > 0.15
        if moved || turned || input {
            lastMovement = now; idleAnchor = position; idleRotation = rotation
        }
        let target: Float = now - lastMovement >= 10 ? 1 : 0
        restWeight += (target - restWeight) * Float(1 - exp(-dt * (target == 0 ? 5 : 2)))
        let held = parent.simdWorldTransform * placement
        let heldRotation = simd_quatf(held), heldPosition = SIMD3(held.columns.3.x, held.columns.3.y, held.columns.3.z)
        let side: Float = left ? -1 : 1, right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let shoulder = head + right * side * 0.16 - forward * 0.13 + SIMD3<Float>(0, -0.23, 0)
        let wrist = shoulder + right * side * 0.31 + SIMD3<Float>(0, -0.44, 0)
        let yaw = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: SIMD3<Float>(0, 1, 0))
        let relaxed = yaw * simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(SIMD3<Float>(-side * 0.31, 0.44, 0)))
        let restPosition = wrist - relaxed.act(wristPos)
        var world = simd_float4x4(simd_slerp(heldRotation, relaxed, restWeight))
        world.columns.3 = SIMD4(heldPosition * (1 - restWeight) + restPosition * restWeight, 1)
        node.simdTransform = simd_inverse(parent.simdWorldTransform) * world
    }
    private var placement = matrix_identity_float4x4
    /// Knuckle angles each lower finger wraps the handle with (dev fitting reads them).
    var graspAngles: [[Float]] { grasp }
    private var grasp: [[Float]] = Array(repeating: [0.9, 1.1, 0.8], count: 3)   // pinky, ring, middle joint angles wrapped on the handle
    private var poseKey: [Float] = []
    private struct Bone { let parent: Int; let pivot: SIMD3<Float>; let segs: [(SIMD3<Float>, SIMD3<Float>)]; var axis = SIMD3<Float>(0, 0, 1)
        var limit: ClosedRange<Float> = 0...1.7; var free = false; var q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }

    // Rig in the mesh's coordinates (metres, palm centre at the origin; fingers -y, palm facing -x, thumb toward +z).
    private static let wrist = SIMD3<Float>(0.0102, 0.0507, 0.0102), forearm = SIMD3<Float>(0.0130, 0.1015, 0.0072)
    /// pinky, ring, middle, index, thumb: four joints each (MCP/PIP/DIP/tip; thumb CMC/MCP/IP/tip)
    private static let fingers: [[SIMD3<Float>]] = [
        [SIMD3(-0.0043, -0.0203, -0.0478), SIMD3(-0.0051, -0.0435, -0.0587), SIMD3(-0.0058, -0.0565, -0.0653), SIMD3(-0.0058, -0.0670, -0.0679)],
        [SIMD3(-0.0014, -0.0275, -0.0174), SIMD3(-0.0029, -0.0652, -0.0254), SIMD3(-0.0042, -0.0870, -0.0297), SIMD3(-0.0043, -0.1051, -0.0319)],
        [SIMD3(0.0000, -0.0290, 0.0051), SIMD3(-0.0014, -0.0696, 0.0039), SIMD3(-0.0039, -0.0943, 0.0036), SIMD3(-0.0043, -0.1138, 0.0036)],
        [SIMD3(0.0000, -0.0261, 0.0275), SIMD3(-0.0017, -0.0609, 0.0341), SIMD3(-0.0033, -0.0826, 0.0391), SIMD3(-0.0036, -0.1012, 0.0420)],
        [SIMD3(0.0000, 0.0304, 0.0290), SIMD3(-0.0072, 0.0261, 0.0580), SIMD3(-0.0167, 0.0181, 0.0769), SIMD3(-0.0203, 0.0102, 0.0986)],
    ]
    /// Mesh space -> grip space for the left hand per controller mesh (the right hand is mirrored across grip x).
    /// Built by aligning the palm's grip line (index knuckle down to the heel of the hand, pinky side) with each
    /// handle's axis, palm resting on it, then turned/slid along the handle so the index lands on the trigger and the
    /// thumb reaches the stick and face buttons (tools/handfit).
    typealias Placement = (pos: SIMD3<Float>, rot: simd_quatf)
    static var place: [HeadsetModel: Placement] = [
        .quest1: (SIMD3(-0.0333, -0.0042, 0.0382), simd_quatf(vector: SIMD4(0.0652, 0.9526, 0.1620, -0.2491))),   // placed by hand in the tuner
        .quest2: (SIMD3(-0.0413, 0.0163, 0.0278), simd_quatf(vector: SIMD4(0.1946, 0.8872, 0.3815, 0.1718))),
        .quest3: (SIMD3(-0.0394, 0.0080, -0.0012), simd_quatf(vector: SIMD4(0.0995, 0.9100, 0.3848, 0.1184))),
    ]
    /// Placements saved from the hand tuner (Application Support/VR4Mac/hand-placement.json) override the built-ins.
    static let savedURL = appSupport.appendingPathComponent("hand-placement.json")
    /// Manual per-bone adjustments from the tuner (radians about each joint's hinge, added after the automatic pose):
    /// 15 per controller mesh, pinky/ring/middle/index/thumb x knuckle/middle/tip.
    static var boneOffsets: [HeadsetModel: [Float]] = [   // tuned by hand in the tuner
        .quest1: [0.8552, -1.2043, -1.2043, 0.6109, -0.6109, 0.2443, 0.1396, 0.1745, -0.1396, 0, 0, 0, 0, 0, 0],
    ]
    /// Look: fill RGB, edge RGB, fill opacity, edge opacity, edge width (0-1).
    static var look: [Float] = [0.17, 0.18, 0.2, 0.78, 0.8, 0.83, 0.68, 0.85, 0.5]
    private static let modelKeys: [String: HeadsetModel] = ["quest1": .quest1, "quest2": .quest2, "quest3": .quest3]
    static func loadSaved() {
        guard let d = try? Data(contentsOf: savedURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: [Float]] else { return }
        for (k, v) in j {
            if v.count == 7, let m = modelKeys[k] { place[m] = (SIMD3(v[0], v[1], v[2]), simd_normalize(simd_quatf(vector: SIMD4(v[3], v[4], v[5], v[6])))) }
            if v.count == 15, k.hasPrefix("bones_"), let m = modelKeys[String(k.dropFirst(6))] { boneOffsets[m] = v }
            if k == "look", v.count == look.count { look = v }
        }
    }
    static func save() {
        var j: [String: [Float]] = ["look": look]
        for (k, m) in modelKeys {
            if let p = place[m] { j[k] = [p.pos.x, p.pos.y, p.pos.z, p.rot.vector.x, p.rot.vector.y, p.rot.vector.z, p.rot.vector.w] }
            if let b = boneOffsets[m] { j["bones_" + k] = b }
        }
        try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]).write(to: savedURL)
    }
    private static let loaded: Void = loadSaved()
    static var smooth = 1
    private var mirror: SIMD3<Float> { left ? SIMD3(1, 1, 1) : SIMD3(-1, 1, 1) }

    private static var cached: ([SIMD3<Float>], [[Int]])?
    private static func load() -> ([SIMD3<Float>], [[Int]])? {
        if let c = cached { return c }
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("hands/hand.obj"),
              let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        var v: [SIMD3<Float>] = [], f: [[Int]] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ")
            if p.first == "v", p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) { v.append(SIMD3(x, y, z)) }
            if p.first == "f" { f.append(p.dropFirst().compactMap { Int($0.split(separator: "/")[0]).map { $0 - 1 } }) }
        }
        guard !v.isEmpty, f.allSatisfy({ $0.count >= 3 && $0.allSatisfy(v.indices.contains) }) else { return nil }
        cached = (v, f)
        return cached
    }

    /// `controller`: the controller mesh this hand holds (in grip space), used to close the fingers onto its handle.
    init?(hand: Int, model: HeadsetModel, controller: SCNNode?) {
        guard let (verts, faces) = HandModel.load() else { return nil }
        _ = HandModel.loaded
        left = hand == 0
        meshModel = model.controllerMesh
        let m = left ? SIMD3<Float>(1, 1, 1) : SIMD3<Float>(-1, 1, 1)   // right hand: mirror the left mesh
        rest = verts.map { $0 * m }
        var idx: [Int32] = []
        for f in faces { for i in 1..<f.count - 1 { idx += (left ? [f[0], f[i], f[i + 1]] : [f[0], f[i + 1], f[i]]).map(Int32.init) } }
        element = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        // Remove the extended wrist geometry entirely when the arm experiment is off.
        let handIndices = stride(from: 0, to: idx.count, by: 3).flatMap { t -> [Int32] in
            (t..<(t + 3)).allSatisfy { verts[Int(idx[$0])].y <= Self.wrist.y + 0.035 } ? Array(idx[t..<(t + 3)]) : []
        }
        handElement = SCNGeometryElement(indices: handIndices, primitiveType: .triangles)
        var openIndices: [Int32] = []
        for t in stride(from: 0, to: idx.count, by: 3) {
            if !(t..<(t + 3)).allSatisfy({ verts[Int(idx[$0])].y > 0.619 }) { openIndices += Array(idx[t..<(t + 3)]) }
        }
        torsoElement = SCNGeometryElement(indices: openIndices, primitiveType: .triangles)
        torsoTriangles = openIndices
        var n = [SIMD3<Float>](repeating: .zero, count: rest.count)
        for t in stride(from: 0, to: idx.count, by: 3) {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            let fn = simd_cross(rest[b] - rest[a], rest[c] - rest[a])
            n[a] += fn; n[b] += fn; n[c] += fn
        }
        restN = n.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }

        // bones: 0 palm (root), 1-12 fingers (3 each, pinky..index), 13-15 thumb
        let j = HandModel.fingers.map { $0.map { $0 * m } }, wr = HandModel.wrist * m
        joints = j; wristPos = wr
        var b = [Bone(parent: -1, pivot: wr, segs: [(wr, HandModel.forearm * m)] + j.map { (wr, $0[0]) })]
        let palm = SIMD3<Float>(left ? -1 : 1, 0, 0)                          // fingers curl toward it
        let pad = simd_normalize(SIMD3<Float>(left ? -0.8 : 0.8, 0, -0.6))   // thumb pad: toward the palm and index
        for (fi, f) in j.enumerated() {
            for k in 0..<3 {
                var bone = Bone(parent: k == 0 ? 0 : b.count - 1, pivot: f[k], segs: [(f[k], f[k + 1])])
                let dir = simd_normalize(f[k + 1] - f[k])
                bone.axis = simd_normalize(simd_cross(dir, fi == 4 ? pad : palm))
                if fi == 4 { bone.limit = k == 0 ? -0.2...0.9 : 0...(k == 1 ? 0.9 : 1.2); bone.free = k < 2 }   // CMC and MCP swing; IP hinges
                else { bone.limit = 0...[1.6, 1.8, 1.3][k] }
                b.append(bone)
            }
        }
        bones = b
        // skin: the two nearest bones by distance to their segments, inverse-distance weighted (sharp falloff)
        func dist(_ p: SIMD3<Float>, _ s: (SIMD3<Float>, SIMD3<Float>)) -> Float {
            let d = s.1 - s.0, t = simd_clamp(simd_dot(p - s.0, d) / simd_dot(d, d), 0, 1)
            return simd_distance(p, s.0 + d * t)
        }
        skin = rest.map { p in
            let w = b.enumerated().map { (i, bone) in (i, 1 / pow(max(1e-4, bone.segs.map { dist(p, $0) }.min()!), 6)) }.sorted { $0.1 > $1.1 }
            return (w[0].0, w[1].0, w[0].1 / (w[0].1 + w[1].1))
        }
        // fade toward the arm: solid over the fingers and palm, gone a few centimetres past the wrist
        var d = Data(capacity: rest.count * 16)
        for p in rest {
            let t = simd_clamp((p.y - (wr.y - 0.02)) / 0.05, 0, 1), a = 1 - t * t * (3 - 2 * t)
            withUnsafeBytes(of: SIMD4<Float>(1, 1, 1, a)) { d.append(contentsOf: $0) }
        }
        let debugColors = ProcessInfo.processInfo.environment["HAND_DEBUG_COLORS"] != nil   // dev renders: one colour per finger
        if debugColors {
            d = Data(capacity: rest.count * 16)
            let pal: [SIMD4<Float>] = [SIMD4(0.6, 0.6, 0.6, 1), SIMD4(0.9, 0.2, 0.2, 1), SIMD4(0.95, 0.55, 0.1, 1), SIMD4(0.95, 0.9, 0.2, 1), SIMD4(0.2, 0.85, 0.3, 1), SIMD4(0.2, 0.4, 1, 1)]
            for (bone, _, _) in skin { withUnsafeBytes(of: pal[bone == 0 ? 0 : 1 + (bone - 1) / 3]) { d.append(contentsOf: $0) } }
        }
        colors = d
        var visible = d
        for i in rest.indices {
            var alpha: Float = 1
            withUnsafeBytes(of: &alpha) { visible.replaceSubrange((i * 16 + 12)..<(i * 16 + 16), with: $0) }
        }
        armColors = visible
        material = SCNMaterial()
        material.lightingModel = .lambert   // (constant lighting leaves the shader's view vector empty)
        material.diffuse.contents = NSColor.white
        material.blendMode = .alpha
        material.transparencyMode = .singleLayer
        if !debugColors { applyLook() }
        let pl = HandModel.place[model.controllerMesh] ?? HandModel.place[.quest2]!
        let v = pl.rot.vector   // mirrored across grip x for the right hand
        node.simdOrientation = left ? pl.rot : simd_quatf(vector: SIMD4(v.x, -v.y, -v.z, v.w))
        node.simdPosition = pl.pos * mirror
        placement = node.simdTransform
        node.renderingOrder = 150   // after UI panels, before pointers; transparent hands stay visible
        node.castsShadow = false
        if let controller { fitGrasp(controller) }
        apply()
    }

    /// Original flat hand appearance. Only the default grey tone is translucent.
    static func configureSkin(_ material: SCNMaterial, tone: String) {
        let original = tone == "Original"
        let color = skinColor(tone)
        if !original {   // skin colours: lit, softly shiny skin (not flat-shaded)
            material.shaderModifiers = nil
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.roughness.contents = NSNumber(value: 0.42); material.metalness.contents = NSNumber(value: 0)
            material.emission.contents = NSColor.black
            material.transparency = 1; material.blendMode = .replace; material.isDoubleSided = false
            material.readsFromDepthBuffer = true; material.writesToDepthBuffer = true
            return
        }
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor.white
        material.emission.contents = NSColor.black
        material.specular.contents = NSColor.black
        material.transparency = 1
        material.blendMode = original ? .alpha : .replace
        material.transparencyMode = .singleLayer
        material.isDoubleSided = false
        material.readsFromDepthBuffer = true; material.writesToDepthBuffer = !original
        material.shaderModifiers = [.fragment: """
            #pragma arguments
            float3 fillRGB;
            float3 edgeRGB;
            float fillA;
            float edgeA;
            float edgeW;
            float defaultTone;
            #pragma transparent
            #pragma body
            float rim = 1.0 - abs(dot(normalize(_surface.normal), normalize(_surface.view)));
            float edge = smoothstep(1.0 - 0.2 * edgeW, 1.0 - 0.02 * edgeW, rim) * defaultTone;
            float a = defaultTone > 0.5 ? _surface.diffuse.a * mix(fillA, edgeA, edge) : 1.0;
            float3 c = mix(fillRGB, edgeRGB, edge);
            _output.color = float4(c * a, a);
            """]
        let fill = original ? SIMD3<Float>(look[0], look[1], look[2]) : SIMD3(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent))
        material.setValue(NSValue(scnVector3: SCNVector3(fill)), forKey: "fillRGB")
        material.setValue(NSValue(scnVector3: SCNVector3(look[3], look[4], look[5])), forKey: "edgeRGB")
        material.setValue(NSNumber(value: original ? look[6] : 1), forKey: "fillA")
        material.setValue(NSNumber(value: original ? look[7] : 1), forKey: "edgeA")
        material.setValue(NSNumber(value: look[8]), forKey: "edgeW")
        material.setValue(NSNumber(value: original ? Float(1) : Float(0)), forKey: "defaultTone")
    }
    func applyLook() { Self.configureSkin(material, tone: skinTone) }

    // MARK: pose
    private func worldMatrices() -> [simd_float4x4] {
        var m = [simd_float4x4](repeating: matrix_identity_float4x4, count: bones.count)
        for (i, b) in bones.enumerated() where b.parent >= 0 {
            var t = matrix_identity_float4x4; t.columns.3 = SIMD4(b.pivot, 1)
            var ti = matrix_identity_float4x4; ti.columns.3 = SIMD4(-b.pivot, 1)
            m[i] = m[b.parent] * t * simd_float4x4(b.q) * ti
        }
        return m
    }
    private func posed(_ m: [simd_float4x4], _ p: SIMD3<Float>, _ bone: Int) -> SIMD3<Float> { let r = m[bone] * SIMD4(p, 1); return SIMD3(r.x, r.y, r.z) }
    private func hinge(_ bi: Int, _ angle: Float) {
        let q = simd_quatf(angle: simd_clamp(angle, bones[bi].limit.lowerBound, bones[bi].limit.upperBound), axis: bones[bi].axis)
        // lower fingers' knuckles also fan sideways (about the palm normal) so they can wrap a handle crossing the palm
        let f = (bi - 1) / 3
        bones[bi].q = bi >= 1 && bi <= 7 && (bi - 1) % 3 == 0 ? simd_quatf(angle: spread[f], axis: SIMD3(left ? -1 : 1, 0, 0)) * q : q
    }
    private var spread: [Float] = [0, 0, 0]
    /// Curl a finger (0 open .. 1 fist) about its knuckle hinges.
    private func curl(_ finger: Int, _ c: Float) {
        for k in 0..<3 { hinge(1 + finger * 3 + k, c * [1.3, 1.6, 1.1][k]) }
    }
    /// Close pinky/ring/middle around the controller's handle.
    private func fitGrasp(_ controller: SCNNode) {
        let sdf = ControllerSurface(controller), toGrip = node.simdTransform
        guard !sdf.empty else { return }
        func outside(_ p: SIMD3<Float>) -> Float { let g = toGrip * SIMD4(p, 1); return sdf.distance(SIMD3(g.x, g.y, g.z)) }
        // Each lower finger closes around the real controller surface: the knuckle angles that keep every phalanx
        // (~6.5 mm radius) out of the shell, rest the middle and tip pads on it, and otherwise curl as far as they can
        // (a hand holding something wraps until it touches).
        for f in 0..<3 {
            let bi = 1 + f * 3, j = joints[f]
            var best: (cost: Float, a: [Float], sp: Float) = (.infinity, [0.9, 1.3, 0.9], 0)
            for sp in stride(from: Float(-0.45), through: 0.45, by: 0.15) { spread[f] = sp
            for a1 in stride(from: Float(0), through: 1.5, by: 0.1) {
                for a2 in stride(from: Float(0.2), through: 1.8, by: 0.1) { for k3: Float in [0.5, 0.75, 1.0] {
                    let a = [a1, a2, min(1.3, a2 * k3)]
                    for k in 0..<3 { hinge(bi + k, a[k]) }
                    let m = worldMatrices()
                    var cost: Float = 0, touch: Float = 0
                    for k in 0..<3 {
                        let s = posed(m, j[k], k == 0 ? 0 : bi + k - 1), e = posed(m, j[k + 1], bi + k)
                        for t in stride(from: Float(0.25), through: 1, by: 0.25) { cost += 4 * max(0, 0.0065 - outside(s + (e - s) * t)) }
                        if k > 0 { touch += abs(outside((s + e) / 2) - 0.0065) }
                        if k == 2 { touch += abs(outside(e) - 0.0065) }
                    }
                    cost += 0.2 * min(touch, 0.06) - 0.004 * (a[0] + a[1] + a[2]) + 0.01 * abs(sp)   // touching, else keep curling; little fanning
                    if cost < best.cost { best = (cost, a, sp) }
                } }
            } }
            spread[f] = best.sp
            grasp[f] = best.a
            if ProcessInfo.processInfo.environment["HAND_DEBUG"] != nil { print("grasp", f, best) }
            for k in 0..<3 { hinge(bi + k, 0) }
        }
    }
    /// Cyclic coordinate descent: bend `chain` (root first) so its last segment's end reaches `target` (mesh space).
    /// Hinged joints rotate only about their axis within limits; a `free` joint swings toward the target (clamped).
    private func reach(_ chain: [Int], tip: SIMD3<Float>, _ target: SIMD3<Float>) {
        for _ in 0..<40 {
            for bi in chain.reversed() {
                let m = worldMatrices(), pivot = posed(m, bones[bi].pivot, bones[bi].parent), end = posed(m, tip, chain.last!)
                var a = end - pivot, b = target - pivot
                let pr = simd_quatf(m[bones[bi].parent])
                if bones[bi].free {
                    guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { continue }
                    let d = simd_quatf(from: simd_normalize(a), to: simd_normalize(b))
                    var q = simd_slerp(simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), pr.inverse * d * pr, 0.8) * bones[bi].q
                    let cap: Float = bi == 13 ? 1.4 : 0.8   // CMC swings widely, MCP a little (it also flexes)
                    if q.angle > cap { q = simd_quatf(angle: cap, axis: q.axis) }
                    bones[bi].q = q
                } else {
                    let ax = pr.act(bones[bi].axis)
                    a -= ax * simd_dot(a, ax); b -= ax * simd_dot(b, ax)
                    guard simd_length(a) > 1e-5, simd_length(b) > 1e-5 else { continue }
                    let ang = atan2(simd_dot(simd_cross(simd_normalize(a), simd_normalize(b)), ax), simd_dot(simd_normalize(a), simd_normalize(b)))
                    let cur = bones[bi].q.angle * (simd_dot(bones[bi].q.axis, bones[bi].axis) < 0 ? -1 : 1)
                    hinge(bi, cur + ang)
                }
            }
        }
    }

    /// Thumb and index targets in grip space, from the controller mesh (nil: no mesh, use plain curls).
    struct Targets { var stick, rest, trigger: SIMD3<Float>; var buttons: [Int: SIMD3<Float>] }
    /// Pose from the controller state. `targets` come from the animated controller (trigger moves as it's pulled).
    /// `poke`: a hand near the menu straightens its index to touch it. Every joint eases toward its new pose
    /// (~60 ms), so fingers glide onto the trigger and buttons instead of snapping.
    func update(_ h: VR4Hand, targets: Targets?, poke: Bool = false) {
        let b = h.buttons
        func on(_ f: Int) -> Bool { b & UInt32(f) != 0 }
        let key: [Float] = [h.trigger, h.squeeze, h.stick_x, h.stick_y, Float(b & 0x1ff), poke ? 1 : 0] + (targets.map { [$0.trigger.y, $0.trigger.z] } ?? [])
        if key != poseKey {
            poseKey = key
            for i in bones.indices { bones[i].q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
            for f in 0..<3 { for k in 0..<3 { hinge(1 + f * 3 + k, grasp[f][k] + 0.07 * h.squeeze * Float(k + 1) / 2) } }   // always wrapped; squeezing only tightens
            let toMesh = simd_inverse(node.simdTransform)
            func mesh(_ p: SIMD3<Float>) -> SIMD3<Float> { let r = toMesh * SIMD4(p, 1); return SIMD3(r.x, r.y, r.z) }
            if !poke, on(VR4_BTN_TRIGGER_TOUCH) || h.trigger > 0.05, let t = targets { reach([10, 11, 12], tip: joints[3][3], mesh(t.trigger)) }
            else { curl(3, 0.04) }   // lifted off the trigger, or poking the menu: point
            if let t = targets {
                let thumb: SIMD3<Float>
                if let pressed = t.buttons.first(where: { on($0.key) }) { thumb = pressed.value - SIMD3(0, 0.004, 0) }   // pressing it down
                else if on(VR4_BTN_STICK_TOUCH) || on(VR4_BTN_STICK_CLICK) { thumb = t.stick + SIMD3(h.stick_x, 0, -h.stick_y) * 0.008 }
                else if on(VR4_BTN_THUMB_TOUCH) || poke { thumb = t.rest }
                else { thumb = t.rest + SIMD3(0, 0.014, 0.004) }   // resting flat just above the face
                let touching = b & UInt32(VR4_BTN_A | VR4_BTN_B | VR4_BTN_X | VR4_BTN_Y | VR4_BTN_STICK_TOUCH | VR4_BTN_STICK_CLICK | VR4_BTN_THUMB_TOUCH) != 0 || poke
                reach(touching ? [13, 14, 15] : [13, 14], tip: joints[4][3], mesh(thumb))   // not touching: a flat thumb (straight tip joint)
            }
            if let off = HandModel.boneOffsets[meshModel] {   // manual tweaks from the tuner, about each joint's hinge
                for (i, a) in off.enumerated() where a != 0 && i + 1 < bones.count { bones[i + 1].q = simd_quatf(angle: a, axis: bones[i + 1].axis) * bones[i + 1].q }
            }
            target = bones.map(\.q)
        }
        let now = CACurrentMediaTime(), dt = Float(min(0.1, now - lastStep)); lastStep = now
        var moving = shown.count != target.count
        if moving { shown = target }
        let a = 1 - exp(-dt * 16)
        for i in shown.indices {
            let t = simd_dot(shown[i].vector, target[i].vector) < 0 ? simd_quatf(vector: -target[i].vector) : target[i]
            let n = simd_slerp(shown[i], t, a)
            if simd_length(n.vector - shown[i].vector) > 1e-4 { moving = true }
            shown[i] = n
        }
        guard moving else { return }
        for i in bones.indices { bones[i].q = shown[i] }
        apply()
    }
    private var target: [simd_quatf] = [], shown: [simd_quatf] = [], lastStep: CFTimeInterval = 0

    // MARK: hand tracking
    /// Pose the hand from the headset's 26 tracked joints (world space; OpenXR order). The mesh is placed by the
    /// wrist and knuckles, sized to the hand, and each finger bone turns to point along its tracked bone.
    func track(_ j: [SIMD3<Float>]) {
        let wr = wristPos
        func basis(_ w: SIMD3<Float>, _ m: SIMD3<Float>, _ i: SIMD3<Float>, _ p: SIMD3<Float>) -> simd_float3x3 {
            let e1 = simd_normalize(m - w), a = i - p, e2 = simd_normalize(a - e1 * simd_dot(a, e1))
            return simd_float3x3(e1, e2, simd_cross(e1, e2))
        }
        let bm = basis(wr, joints[2][0], joints[3][0], joints[0][0]), bt = basis(j[1], j[12], j[7], j[22])
        let r = bt * bm.transpose, s = simd_distance(j[12], j[1]) / simd_distance(joints[2][0], wr)
        var m = simd_float4x4(SIMD4(r.columns.0 * s, 0), SIMD4(r.columns.1 * s, 0), SIMD4(r.columns.2 * s, 0), SIMD4(0, 0, 0, 1))
        m.columns.3 = SIMD4(j[1] - (r * wr) * s, 1)
        node.simdTransform = m
        let tracked = [[22, 23, 24, 25], [17, 18, 19, 20], [12, 13, 14, 15], [7, 8, 9, 10], [2, 3, 4, 5]]
        for i in bones.indices { bones[i].q = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) }
        for (fi, idx) in tracked.enumerated() {
            for k in 0..<3 {
                let bi = 1 + fi * 3 + k, w = worldMatrices()[bones[bi].parent]
                let rp = simd_float3x3(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z), SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z), SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z))
                let want = rp.transpose * (r.transpose * (j[idx[k + 1]] - j[idx[k]])), rest = joints[fi][k + 1] - joints[fi][k]
                guard simd_length(want) > 1e-5 else { continue }
                bones[bi].q = simd_quatf(from: simd_normalize(rest), to: simd_normalize(want))
            }
        }
        isTracked = true; poseKey = []; shown = []
        apply()
    }
    private(set) var isTracked = false
    /// The mesh's own rest joints in OpenXR order (tests; metacarpals sit at the wrist, palm between wrist and middle knuckle).
    static func restJoints(left: Bool) -> [SIMD3<Float>] {
        let m = left ? SIMD3<Float>(1, 1, 1) : SIMD3<Float>(-1, 1, 1), f = fingers.map { $0.map { $0 * m } }, w = wrist * m
        var j = [(w + f[2][0]) / 2, w] + f[4]
        for fi in [3, 2, 1, 0] { j += [w] + f[fi] }
        return j
    }
    /// Back on the controller: its placement and grasp return.
    func untrack() { guard isTracked else { return }; isTracked = false; node.simdTransform = placement; poseKey = []; shown = [] }

    /// Index fingertip pad in grip space (the menu's direct touch tracks it); thumb pad likewise.
    private(set) var indexTip = SIMD3<Float>.zero, thumbTip = SIMD3<Float>.zero

    private func apply() {
        let m = worldMatrices()
        let tip = posed(m, joints[3][3] + simd_normalize(joints[3][3] - joints[3][2]) * 0.004, 12), tg = node.simdTransform * SIMD4(tip, 1)
        indexTip = SIMD3(tg.x, tg.y, tg.z)
        let th = node.simdTransform * SIMD4(posed(m, joints[4][3], 15), 1)
        thumbTip = SIMD3(th.x, th.y, th.z)
        var v = [SIMD3<Float>](), n = [SIMD3<Float>]()
        v.reserveCapacity(rest.count); n.reserveCapacity(rest.count)
        for (i, p) in rest.enumerated() {
            let (a, b, w) = skin[i]
            let pa = m[a] * SIMD4(p, 1), pb = m[b] * SIMD4(p, 1), q = pa * w + pb * (1 - w)
            var vertex = SIMD3(q.x, q.y, q.z)
            let na = m[a] * SIMD4(restN[i], 0), nb = m[b] * SIMD4(restN[i], 0), r = na * w + nb * (1 - w)
            var normal = simd_normalize(SIMD3(r.x, r.y, r.z))
            if showArms, p.y > wristPos.y, let elbow = armElbow, let shoulder = armShoulder {
                // Forearm and upper-arm bones share blended weights around the elbow.
                let bindElbow = SIMD3<Float>(0.013, 0.32, 0.0072) * mirror
                let fore = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(elbow - wristPos))
                let upper = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(shoulder - elbow))
                var lowerOffset = p - wristPos, upperOffset = p - bindElbow
                lowerOffset.y *= simd_length(elbow - wristPos) / (0.32 - wristPos.y)
                upperOffset.y *= simd_length(shoulder - elbow) / 0.30
                let lowerPoint = wristPos + fore.act(lowerOffset)
                let upperPoint = elbow + upper.act(upperOffset)
                let t = simd_clamp((p.y - 0.295) / 0.05, 0, 1), upperWeight = t * t * (3 - 2 * t)
                let start = simd_clamp((p.y - wristPos.y) / 0.045, 0, 1), armWeight = start * start * (3 - 2 * start)
                let skinned = lowerPoint * (1 - upperWeight) + upperPoint * upperWeight
                let skinnedNormal = fore.act(restN[i]) * (1 - upperWeight) + upper.act(restN[i]) * upperWeight
                vertex = vertex * (1 - armWeight) + skinned * armWeight
                normal = simd_normalize(normal * (1 - armWeight) + skinnedNormal * armWeight)
            }
            v.append(vertex); n.append(normal)
        }
        posedVertices = v
        shoulderVertices = rest.indices.filter { rest[$0].y > 0.619 }.map { v[$0] }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v.map { SCNVector3($0) }), SCNGeometrySource(normals: n.map { SCNVector3($0) }),
                                      SCNGeometrySource(data: showArms ? armColors : colors, semantic: .color, vectorCount: rest.count, usesFloatComponents: true,
                                                        componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)],
                            elements: [showArms ? (showTorso ? torsoElement : element) : handElement])
        g.materials = [material]
        // The mesh changes with each pose, so subdivision rebuilds its topology
        // on the render thread each frame. Keep smooth vertex normals without
        // the CPU subdivision that dominated the controller-motion profile.
        g.subdivisionLevel = 0
        node.geometry = g
    }
}

/// Tracked hands (controllers put down) as controller input: the pinch is the trigger, the laser aims from the
/// shoulder through the pinch point (Horizon OS style) and only shows while thumb and index are poised to pinch.
/// The left palm turned to your face + pinch is the menu button.
enum HandGesture {
    private static var pinched = [false, false]   // link queue only
    static func hand(_ j: [VR4Pose], head: VR4Pose, left: Bool, was: VR4Hand) -> VR4Hand {
        func p(_ i: Int) -> SIMD3<Float> { SIMD3(j[i].px, j[i].py, j[i].pz) }
        let i = left ? 0 : 1, h = SIMD3(head.px, head.py, head.pz)
        let gap = simd_distance(p(5), p(10))   // thumb tip to index tip
        pinched[i] = pinched[i] ? gap < 0.035 : gap < 0.02   // hysteresis: closes at 2 cm, opens past 3.5 cm
        let palm = simd_quatf(ix: j[0].qx, iy: j[0].qy, iz: j[0].qz, r: j[0].qw)
        let facing = simd_dot(palm.act(SIMD3(0, -1, 0)), simd_normalize(h - p(0)))   // palm normal is -y
        // shoulder: below and beside the head, turned with it (yaw only)
        let hq = simd_quatf(ix: head.qx, iy: head.qy, iz: head.qz, r: head.qw), f = hq.act(SIMD3<Float>(0, 0, -1))
        let yaw = simd_quatf(angle: atan2(-f.x, -f.z), axis: SIMD3(0, 1, 0))
        let shoulder = h + yaw.act(SIMD3(left ? -0.17 : 0.17, -0.22, 0.05))
        let origin = (p(3) + p(7)) / 2, dir = simd_normalize(origin - shoulder)
        let aimQ = simd_quatf(from: SIMD3(0, 0, -1), to: dir)
        var out = VR4Hand()
        out.flags = UInt32(VR4_HAND_ACTIVE | VR4_HAND_POSE_VALID | VR4_HAND_TRACKED)
        if facing < 0.3 && (gap < 0.07 || pinched[i]) { out.flags |= UInt32(VR4_HAND_PINCH_READY) }
        out.aim = VR4Pose(px: origin.x, py: origin.y, pz: origin.z, qx: aimQ.imag.x, qy: aimQ.imag.y, qz: aimQ.imag.z, qw: aimQ.real)
        out.grip = j[0]
        out.trigger = pinched[i] ? 1 : max(0, min(0.5, (0.07 - gap) / 0.1))
        if left && facing > 0.6 && pinched[i] { out.buttons = UInt32(VR4_BTN_MENU); out.trigger = 0 }
        return out
    }
}

/// Signed distance to a controller's surface (positive outside): distance to the nearest mesh vertex (5 mm hash grid),
/// negative where the point is inside the solid (a 2.5 mm voxel fill: rays along z, filled between crossing pairs).
struct ControllerSurface {
    private var cells: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
    private var solid = Set<SIMD3<Int32>>()
    var empty: Bool { cells.isEmpty }
    private static let cell: Float = 0.005, vox: Float = 0.0025
    private static func key(_ p: SIMD3<Float>, _ s: Float = cell) -> SIMD3<Int32> { SIMD3<Int32>((p / s).rounded(.down)) }
    init(_ controller: SCNNode) {
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        controller.enumerateHierarchy { n, _ in
            guard let g = n.geometry, let vs = g.sources(for: .vertex).first, vs.bytesPerComponent == 4 else { return }
            let pts: [SIMD3<Float>] = vs.data.withUnsafeBytes { raw in (0..<vs.vectorCount).map { i in let o = vs.dataOffset + i * vs.dataStride
                return n.simdConvertPosition(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self), raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                                   raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)), to: controller) } }
            for p in pts { cells[ControllerSurface.key(p), default: []].append(p) }
            for el in g.elements where el.primitiveType == .triangles {
                el.data.withUnsafeBytes { raw in
                    func ix(_ i: Int) -> Int { el.bytesPerIndex == 4 ? Int(raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                        : el.bytesPerIndex == 2 ? Int(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)) : Int(raw.load(fromByteOffset: i, as: UInt8.self)) }
                    for t in 0..<el.primitiveCount {
                        let a = ix(t * 3), b = ix(t * 3 + 1), c = ix(t * 3 + 2)
                        if a < pts.count, b < pts.count, c < pts.count { tris.append((pts[a], pts[b], pts[c])) }
                    }
                }
            }
        }
        // bucket triangles by xy voxel column, then fill each column between pairs of crossings along z
        let v = ControllerSurface.vox
        var cols: [SIMD2<Int32>: [Int]] = [:]
        for (i, t) in tris.enumerated() {
            let lo = simd_min(t.0, simd_min(t.1, t.2)), hi = simd_max(t.0, simd_max(t.1, t.2))
            for x in Int32((lo.x / v).rounded(.down))...Int32((hi.x / v).rounded(.down)) {
                for y in Int32((lo.y / v).rounded(.down))...Int32((hi.y / v).rounded(.down)) { cols[SIMD2(x, y), default: []].append(i) }
            }
        }
        for (k, list) in cols {
            let px = (Float(k.x) + 0.5) * v, py = (Float(k.y) + 0.5) * v
            var zs: [Float] = []
            for i in list {   // where the vertical line through (px, py) crosses the triangle (barycentric in xy)
                let (a, b, c) = tris[i]
                let d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
                guard abs(d) > 1e-12 else { continue }
                let l1 = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / d, l2 = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / d, l3 = 1 - l1 - l2
                if l1 >= 0, l2 >= 0, l3 >= 0 { zs.append(l1 * a.z + l2 * b.z + l3 * c.z) }
            }
            zs.sort()
            for j in stride(from: 0, to: zs.count - 1, by: 2) {
                for z in Int32((zs[j] / v).rounded(.down))...Int32((zs[j + 1] / v).rounded(.down)) { solid.insert(SIMD3(k.x, k.y, z)) }
            }
        }
    }
    func distance(_ p: SIMD3<Float>) -> Float {
        let k = ControllerSurface.key(p)
        var best = Float.infinity
        for dx in -2...2 { for dy in -2...2 { for dz in -2...2 {
            guard let list = cells[k &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
            for q in list { best = min(best, simd_distance_squared(p, q)) }
        } } }
        let d = best == .infinity ? 1 : best.squareRoot()
        return solid.contains(ControllerSurface.key(p, ControllerSurface.vox)) ? -d : d
    }
}

/// Moves the controller's buttons, trigger, grip and stick like the real one (WebXR Input Profiles: each
/// `<part>_value` node is blended between its `_min` and `_max` siblings), and reads where the fingers go.
final class ControllerRig {
    let root: SCNNode
    private var parts: [(value: SCNNode, min: SCNNode, max: SCNNode)] = []
    private let names: [String]
    init(_ root: SCNNode, hand: Int) {
        self.root = root
        let face = hand == 0 ? ["x_button", "y_button"] : ["a_button", "b_button"]
        names = ["xr_standard_trigger_pressed", "xr_standard_squeeze_pressed", "xr_standard_thumbstick_pressed",
                 "xr_standard_thumbstick_xaxis_pressed", "xr_standard_thumbstick_yaxis_pressed"] + face.map { $0 + "_pressed" }
        for n in names {
            if let v = root.childNode(withName: n + "_value", recursively: true), let lo = root.childNode(withName: n + "_min", recursively: true),
               let hi = root.childNode(withName: n + "_max", recursively: true) { parts.append((v, lo, hi)) }
            else { parts.append((SCNNode(), SCNNode(), SCNNode())) }   // procedural fallback mesh: nothing to move
        }
        buttonBits = hand == 0 ? [VR4_BTN_X, VR4_BTN_Y] : [VR4_BTN_A, VR4_BTN_B]
        faceNames = face
    }
    private let buttonBits: [Int], faceNames: [String]

    func update(_ h: VR4Hand) {
        func on(_ f: Int) -> Bool { h.buttons & UInt32(f) != 0 }
        // WebXR y axis is down-positive; OpenXR stick_y is up-positive
        let values: [Float] = [h.trigger, h.squeeze, on(VR4_BTN_STICK_CLICK) ? 1 : 0, (h.stick_x + 1) / 2, (1 - h.stick_y) / 2]
            + buttonBits.map { on($0) ? 1 : 0 }
        for (p, v) in zip(parts, values) {
            let a = simd_clamp(v, 0, 1)
            p.value.simdPosition = simd_mix(p.min.simdPosition, p.max.simdPosition, SIMD3(repeating: a))
            p.value.simdOrientation = simd_slerp(p.min.simdOrientation, p.max.simdOrientation, a)
        }
    }

    /// Fingertip targets in grip space: top of the stick / thumbrest / face buttons, front of the trigger.
    func targets() -> HandModel.Targets? {
        func top(_ name: String, up: Float = 0.009) -> SIMD3<Float>? {
            guard let n = root.childNode(withName: name, recursively: true) else { return nil }
            let (lo, hi) = n.boundingBox
            return n.simdConvertPosition(SIMD3(Float(lo.x + hi.x) / 2, Float(hi.y), Float(lo.z + hi.z) / 2), to: root) + SIMD3(0, up, 0)
        }
        guard let stick = top("thumbstick", up: 0.007), let trig = root.childNode(withName: "trigger", recursively: true) else { return nil }
        let (lo, hi) = trig.boundingBox
        let trigger = trig.simdConvertPosition(SIMD3(Float(lo.x + hi.x) / 2, Float(lo.y + hi.y) / 2, Float(lo.z)), to: root) + SIMD3(0, 0, -0.006)
        var buttons: [Int: SIMD3<Float>] = [:]
        for (bit, name) in zip(buttonBits, faceNames) { buttons[bit] = top(name) }
        return .init(stick: stick, rest: top("thumbrest_pressed_value") ?? stick, trigger: trigger, buttons: buttons)
    }
}
