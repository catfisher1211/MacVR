import AppKit
import Foundation

/// MACVR_HOME (tests only): run as a brand-new user, with the Wine wrapper and app data under that folder.
let macvrHome = ProcessInfo.processInfo.environment["MACVR_HOME"].map { URL(fileURLWithPath: $0) }
let appSupport: URL = {
    let u = (macvrHome?.appendingPathComponent("Library/Application Support")
             ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]).appendingPathComponent("VR4Mac")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

/// All settings are strings: "On"/"Off" for toggles, the option text otherwise.
final class Settings: ObservableObject {
    /// `info`: one plain sentence under the label in the headset's Settings (also searched).
    struct Item { let key, label: String; let options: [String]; let def: String; var advanced = false; var info = "" }
    static let offOn = ["Off", "On"]
    static let schema: [(String, [Item])] = [
        ("Experimental", [
            Item(key: "hand_tracking", label: "Hand Tracking", options: offOn, def: "On", info: "Use your hands without controllers."),
            Item(key: "show_arms", label: "Show arms", options: offOn, def: "Off", info: "Arms on your hands, plus avatar options."),
            Item(key: "avatar_skin", label: "Skin colour", options: ["Original", "Grey", "Light", "Medium", "Tan", "Brown", "Deep"], def: "Original", info: ""),   // or a picked "#RRGGBB"
            Item(key: "show_body", label: "Show body", options: offOn, def: "Off", info: "A torso under your arms."),
            Item(key: "home_mirror", label: "Home mirror", options: offOn, def: "Off", info: "See your avatar in a mirror.")]),
        ("Updates", [Item(key: "auto_updates", label: "Automatic Updates", options: offOn, def: "On", info: "Installs updates while you're not playing."),
                     Item(key: "update_channel", label: "Update Channel", options: ["Public", "Beta"], def: "Public", info: "Beta gets new features first.")]),
        ("General", [Item(key: "render_scale", label: "Render Resolution", options: ["50%", "75%", "100%", "125%", "150%"], def: "100%",
                          info: "Higher is sharper, lower is smoother."),
                     Item(key: "refresh_rate", label: "Headset Refresh Rate", options: ["72", "80", "90", "120"], def: "72", info: ""),
                     Item(key: "wifi_play", label: "Wi-Fi Play", options: offOn, def: "On",
                          info: "Pair once over USB, then play without the cable.")]),
        ("Play Area", [Item(key: "home_style", label: "3D Home", options: ["Room 1107", "Kleeblatt"], def: "Room 1107", info: ""),
                       Item(key: "floor_grid", label: "Show Floor Grid", options: offOn, def: "On", info: ""),
                       Item(key: "environment", label: "Home Environment",
                            options: ["Void", "Golden Bay", "Venice Sunset", "Rooftop Night", "Kloofendal Sky", "Lilienstein", "Starry Night",
                                      "Forest", "Snowy Park", "Fireside", "Sky On Fire", "Harbour Sunset", "Moonless Night"], def: "Golden Bay")]),
        ("Dashboard", [
            Item(key: "menu_style", label: "Menu Style", options: ["Quest", "SteamVR"], def: "Quest",
                 info: ""),
            Item(key: "direct_touch", label: "Direct Touch", options: offOn, def: "On",
                 info: "Tap the menu with your finger."),
            Item(key: "dashboard_position", label: "Dashboard Position", options: ["NEAR", "MIDDLE", "FAR"], def: "NEAR", info: ""),
            Item(key: "show_power", label: "Show Power Options", options: offOn, def: "On", info: ""),
            Item(key: "ui_curved", label: "Curved UI", options: offOn, def: "On", info: ""),
            Item(key: "show_desktop_tabs", label: "Show Desktop Tabs", options: offOn, def: "On", info: ""),
            Item(key: "show_settings_tab", label: "Show Settings Tab", options: offOn, def: "On",
                 info: ""),
            Item(key: "dnd", label: "Do Not Disturb", options: offOn, def: "Off", info: ""),
            Item(key: "system_button", label: "Also Open Menu With B / Y", options: offOn, def: "Off", info: ""),
            Item(key: "controller_model", label: "Controller Model", options: ["Auto", "Quest 1", "Quest 2", "Quest 3"], def: "Auto",
                 info: ""),
        ]),
        ("Accessibility", [
            Item(key: "text_size", label: "Text Size", options: ["Default", "Large", "Largest"], def: "Default", info: ""),
            Item(key: "high_contrast", label: "High Contrast", options: offOn, def: "Off", info: ""),
            Item(key: "reduce_motion", label: "Reduce Motion", options: offOn, def: "Off", info: ""),
            Item(key: "left_handed", label: "Left-Handed Layout", options: offOn, def: "Off",
                 info: ""),
        ]),
        ("Video", [Item(key: "bitrate", label: "Stream Bitrate (Mbps)", options: ["Auto", "20", "40", "60", "100", "150"], def: "Auto",
                        info: "Higher is sharper, lower is steadier."),
                   Item(key: "codec", label: "Video Codec", options: ["H.264", "HEVC"], def: "H.264", info: "HEVC looks better. Applies on reconnect."),
                   Item(key: "perf_hud", label: "Performance Overlay", options: offOn, def: "Off", info: ""),
                   Item(key: "theater_screen", label: "Theater Screen", options: ["Small", "Medium", "Large", "IMAX"], def: "Large", info: ""),
                   Item(key: "theater_curved", label: "Curved Theater Screen", options: offOn, def: "On", info: ""),
                   Item(key: "theater_lights", label: "Theater Lights", options: ["Dark", "Dim", "Home"], def: "Dark",
                        info: "")]),
        ("Developer", [Item(key: "show_fps", label: "Show FPS In Headset", options: offOn, def: "Off", advanced: true, info: "")]),
    ]
    static let items = Dictionary(uniqueKeysWithValues: schema.flatMap { $0.1 }.map { ($0.key, $0) })

    private let url = appSupport.appendingPathComponent("settings.json")
    private let lock = NSLock()
    @Published private(set) var values: [String: String]
    var onChange: () -> Void = {}

    init() {
        var v = Settings.items.mapValues { $0.def }
        if let d = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: String].self, from: d) {
            for (k, x) in saved where Settings.items[k]?.options.contains(x) == true { v[k] = x }
        }
        values = v
    }

    subscript(_ k: String) -> String { lock.lock(); defer { lock.unlock() }; return values[k] ?? "" }
    func bool(_ k: String) -> Bool { self[k] == "On" }
    func int(_ k: String) -> Int { Int(self[k].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0 }

    /// Avatar settings that only apply (and only show) while Show arms is on.
    static let avatarKeys: Set = ["avatar_skin", "show_body", "home_mirror"]
    /// Hands/arms colour: a picked "#RRGGBB", an older preset name, or Original (the default grey).
    static func skinColor(_ name: String) -> NSColor {
        let tones: [String: (CGFloat, CGFloat, CGFloat)] = ["Grey": (0.56, 0.58, 0.62), "Light": (0.96, 0.77, 0.64), "Medium": (0.80, 0.57, 0.40), "Tan": (0.65, 0.40, 0.25), "Brown": (0.43, 0.24, 0.14), "Deep": (0.24, 0.12, 0.08)]
        if name.hasPrefix("#"), let v = UInt32(name.dropFirst(), radix: 16) {   // custom tone from the skin picker
            return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        let rgb = tones[name] ?? (0.17, 0.18, 0.2)
        return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    func set(_ k: String, _ v: String) {
        let customSkin = k == "avatar_skin" && v.count == 7 && v.hasPrefix("#") && UInt32(v.dropFirst(), radix: 16) != nil   // skin picker: #RRGGBB
        guard customSkin || Settings.items[k]?.options.contains(v) == true else { return }
        let apply = { [self] in
            lock.lock(); values[k] = v; let snap = values; lock.unlock()
            try? JSONEncoder().encode(snap).write(to: url)
            onChange()
        }
        Thread.isMainThread ? apply() : DispatchQueue.main.async(execute: apply)
    }
    func cycle(_ k: String) {
        guard let o = Settings.items[k]?.options, let i = o.firstIndex(of: self[k]) else { return }
        set(k, o[(i + 1) % o.count])
    }
}
