import AppKit
import AuthCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `MacAuth --render-docs <dir>` writes the documentation images from the real views with demo data,
/// light and dark, German (and the main view in English). The vault is never opened. Then the process exits.
///
/// The English images come from the same binary started again with `-AppleLanguages (en)`; translations only
/// exist in the built app bundle.
@MainActor
enum DocRenderer {
    private static let size = CGSize(width: 1200, height: 720)

    static func render(to dir: String) {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        let englishOnly = ProcessInfo.processInfo.environment["MACAUTH_RENDER_LANG"] == "en"
        let only = ProcessInfo.processInfo.environment["MACAUTH_RENDER_ONLY"]?.split(separator: ",").map(String.init)

        for scheme in [ColorScheme.light, .dark] {
            let tag = scheme == .light ? "light" : "dark"
            let suffix = englishOnly ? "-en" : ""
            func want(_ name: String) -> Bool { only == nil || only!.contains(name) }

            if want("main-grid") {
                let model = demoModel(.unlocked)
                window(RootView(model: model), model: model, scheme: scheme, size: size, to: url.appendingPathComponent("main-grid-\(tag)\(suffix).png"))
            }
            if englishOnly { continue }
            if want("main-list") {
                let model = demoModel(.unlocked)
                model.settings.listMode = true
                window(RootView(model: model), model: model, scheme: scheme, size: size, to: url.appendingPathComponent("main-list-\(tag).png"))
            }
            if want("search") {
                let model = demoModel(.unlocked)
                model.search = "pro"
                model.selection = model.visibleAccounts.first?.id
                window(RootView(model: model), model: model, scheme: scheme, size: size, to: url.appendingPathComponent("search-\(tag).png"))
            }
            if want("first-run") {
                let model = demoModel(.firstRun)
                window(RootView(model: model), model: model, scheme: scheme, size: size, to: url.appendingPathComponent("first-run-\(tag).png"))
            }
            if want("locked") {
                let model = demoModel(.locked)
                window(RootView(model: model), model: model, scheme: scheme, size: size, to: url.appendingPathComponent("locked-\(tag).png"))
            }
            if want("import-review") {
                let model = demoModel(.unlocked)
                let session = model.makeSession(source: .google, accounts: DemoData.reviewAccounts,
                                                skipped: ["Altdienst (alt@beispiel.example)"])
                sheet(ReviewSheet(model: model, session: session), scheme: scheme, to: url.appendingPathComponent("import-review-\(tag).png"))
            }
            if want("add") {
                let model = demoModel(.unlocked)
                var prefill = DemoData.reviewAccounts[1]
                prefill.groupID = nil
                sheet(AccountFormSheet(model: model, editing: nil, prefill: prefill), scheme: scheme, to: url.appendingPathComponent("add-\(tag).png"))
            }
            if want("export-backup") {
                let model = demoModel(.unlocked)
                sheet(ExportBackupSheet(model: model, previewPassword: "Sommerwiese-Kaffee-42"), scheme: scheme,
                      to: url.appendingPathComponent("export-backup-\(tag).png"))
            }
            if want("settings") {
                let model = demoModel(.unlocked)
                sheet(SettingsView(model: model, updater: nil), scheme: scheme, to: url.appendingPathComponent("settings-\(tag).png"))
            }
            if want("settings") {
                let model = demoModel(.unlocked)
                sheet(SettingsView(model: model, updater: nil, initialTab: 1), scheme: scheme, to: url.appendingPathComponent("settings-general-\(tag).png"))
            }
            if want("transfer") {
                let model = demoModel(.unlocked)
                sheet(TransferSheet(model: model, preselected: nil), scheme: scheme, to: url.appendingPathComponent("transfer-\(tag).png"))
            }
        }

        if !englishOnly, only == nil { renderEnglish(to: dir) }
        print("Bilder geschrieben nach \(url.path)")
    }

    private static func demoModel(_ phase: AppModel.Phase) -> AppModel {
        let suite = "com.fbrogno.macauth.render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.lastAccountChange = 2
        settings.lastBackupExport = 1
        switch phase {
        case .firstRun: return AppModel(demoPhase: phase, accounts: [], groups: AccountGroup.makeDefaults(), settings: settings)
        case .locked: return AppModel(demoPhase: phase, accounts: [], groups: [], settings: settings)
        default: return AppModel(demoPhase: phase, accounts: DemoData.accounts, groups: DemoData.groups, settings: settings)
        }
    }

    /// Starts this binary again in English for the main view, and waits.
    private static func renderEnglish(to dir: String) {
        guard let executable = Bundle.main.executablePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--render-docs", dir, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        process.environment = ProcessInfo.processInfo.environment.merging(["MACAUTH_RENDER_LANG": "en"]) { $1 }
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("Konnte \(executable) nicht starten: \(error)\n".utf8))
            return
        }
        process.waitUntilExit()
    }

    // MARK: Capturing

    private static func window(_ root: RootView, model: AppModel, scheme: ColorScheme, size: CGSize, to file: URL) {
        let shot = ZStack(alignment: .topLeading) {
            root
            if model.phase != .unlocked { TrafficLights().padding(.top, 20).padding(.leading, 14) }
        }
        .frame(width: size.width, height: size.height)
        sheet(shot, scheme: scheme, to: file, padding: 36)
    }

    private static func sheet(_ content: some View, scheme: ColorScheme, to file: URL, padding: CGFloat = 40) {
        let hosting = NSHostingView(rootView: content
            .environment(\.fixedNow, DemoData.now)
            .environment(\.controlActiveState, .key)
            .toggleStyle(DocSwitchStyle(dark: scheme == .dark))
            .environment(\.colorScheme, scheme))
        let window = RenderWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        placeInvisibly(window)
        window.makeKeyAndOrderFront(nil)
        settle(0.4)
        let fitted = hosting.fittingSize
        window.setContentSize(fitted)
        hosting.frame = NSRect(origin: .zero, size: fitted)
        settle()
        defer { window.orderOut(nil) }
        guard let image = capture(hosting) else {
            FileHandle.standardError.write(Data("Konnte \(file.lastPathComponent) nicht rendern\n".utf8))
            return
        }
        write(Backdrop(image: image, scheme: scheme, padding: padding), to: file)
    }

    /// On a screen but fully transparent: macOS stops drawing windows that are far off screen.
    private static func placeInvisibly(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        window.setFrameOrigin(origin)
    }

    private static func settle(_ seconds: Double = 0.5) {
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    }

    private static func capture(_ view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ view: some View, to file: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            FileHandle.standardError.write(Data("Konnte \(file.lastPathComponent) nicht schreiben\n".utf8))
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// A window that stays where it is put, also far off screen.
private final class RenderWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

/// The captured window with rounded corners and a shadow on a calm backdrop.
private struct Backdrop: View {
    let image: NSImage
    let scheme: ColorScheme
    var padding: CGFloat = 36

    var body: some View {
        let dark = scheme == .dark
        Image(nsImage: image)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.1)))
            .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 22, y: 10)
            .padding(padding)
            .background(dark ? Color(red: 0.08, green: 0.09, blue: 0.12) : Color(red: 0.90, green: 0.92, blue: 0.95))
    }
}


/// A switch drawn in SwiftUI in the colours of an active window. The system switch is drawn grey in a window
/// that is not frontmost, which is how an off-screen capture sees it; on and off would hardly differ.
private struct DocSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    var dark = false

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color(red: 0.04, green: 0.52, blue: 1.0) : (dark ? Color.white.opacity(0.18) : Color.black.opacity(0.15)))
                Circle().fill(Color.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            }
            .frame(width: 38, height: 22)
            .opacity(enabled ? 1 : 0.45)
        }
    }
}
