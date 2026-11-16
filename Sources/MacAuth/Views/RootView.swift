import AppKit
import AuthCore
import SwiftUI
import UniformTypeIdentifiers

private struct ProtectScreenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var protectScreen: Bool {
        get { self[ProtectScreenKey.self] }
        set { self[ProtectScreenKey.self] = newValue }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    /// Optional: the documentation renderer passes an updater with an invented pending update.
    var updater: UpdaterModel?

    var body: some View {
        ZStack {
            switch model.phase {
            case .loading: Color(nsColor: .windowBackgroundColor)
            case .firstRun: FirstRunView(model: model)
            case .locked: LockedView(model: model)
            case .unlocked: MainView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .environment(updater)
        .environment(\.protectScreen, model.settings.protectScreen)
        .background(WindowConfigurator(isMainWindow: true))
        .sheet(item: $model.sheet) { sheet in SheetRouter(model: model, sheet: sheet).environment(\.protectScreen, model.settings.protectScreen) }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert?.message ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.phase == .firstRun || model.phase == .unlocked, model.sheet == nil else { return false }
            ImportFlow.handle(urls: urls, model: model)
            return true
        }
        .overlay {
            if let busy = model.busyText ?? (model.importer.isReading ? String(localized: "Bild wird gelesen …") : nil) {
                ProgressView(busy)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task {
            if model.isDemo {
                model.input.start()
                if Entry.isDemo { model.demoHotKeySelfTest() }
            }
            await model.start()
        }
    }
}

struct SheetRouter: View {
    @Bindable var model: AppModel
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .add: AccountFormSheet(model: model, editing: nil)
        case .edit(let id): AccountFormSheet(model: model, editing: model.account(id))
        case .importer: ImportSheet(model: model)
        case .microsoftGuide: ImportSheet(model: model, initialGuide: .microsoft)
        case .review(let session): ReviewSheet(model: model, session: session)
        case .restoreBackup(let preset, let replace): RestoreSheet(model: model, preset: preset, replace: replace)
        case .rescue: RescueSheet(model: model)
        case .exportBackup: ExportBackupSheet(model: model)
        case .exportPlain: PlainExportSheet(model: model)
        case .transfer(let ids): TransferSheet(model: model, preselected: ids)
        case .newGroup: GroupSheet(model: model, existing: nil)
        case .editGroup(let id): GroupSheet(model: model, existing: model.group(id))
        case .confirmDelete(let id): DeleteAccountSheet(model: model, id: id)
        }
    }
}

/// Applies window-level settings: minimum size, remembered frame, exclusion from screen capture.
struct WindowConfigurator: NSViewRepresentable {
    let isMainWindow: Bool
    @Environment(\.protectScreen) private var protect

    final class Anchor: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.onWindow = { configure($0) }
        return view
    }

    func updateNSView(_ nsView: Anchor, context: Context) {
        nsView.onWindow = { configure($0) }
        if let window = nsView.window { configure(window) }
    }

    private func configure(_ window: NSWindow) {
        window.sharingType = protect ? .none : .readOnly
        guard isMainWindow else { return }
        window.minSize = NSSize(width: 760, height: 520)
        if window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("MacAuthMainWindow") }
    }
}

@MainActor
enum FilePanels {
    /// Panels that are open right now. `cancelAll()` closes them when the vault locks, so no open/save panel
    /// stays on screen over the lock screen (and none answers into a state it was not started in).
    private static var open: [NSSavePanel] = []

    private static func run(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            open.append(panel)
            panel.begin { response in
                open.removeAll { $0 === panel }
                continuation.resume(returning: response)
            }
        }
    }

    /// Closes every open panel as if the user had pressed "Cancel".
    static func cancelAll() {
        for panel in open { panel.cancel(nil) }
    }

    static func openImages() async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Wähle einen Screenshot oder ein Foto mit dem QR-Code. Das Bild wird nicht gespeichert.")
        return await run(panel) == .OK ? panel.urls : []
    }

    static func openBackup() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: BackupFile.fileExtension) ?? .data, .json, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Wähle eine MacAuth-Backup-Datei.")
        return await run(panel) == .OK ? panel.url : nil
    }

    /// Export file of another authenticator (Aegis, 2FAS, Ente Auth, otpauth list), the Android database of
    /// Microsoft Authenticator (`PhoneFactor`, a file without extension) or a MacAuth backup.
    static func openImportFile() async -> URL? {
        let panel = NSOpenPanel()
        // Detection is by content, so any file may be chosen; the listed types only make the common ones easy to find.
        panel.allowedContentTypes = [UTType(filenameExtension: BackupFile.fileExtension) ?? .data, .json, .commaSeparatedText, .plainText, .text,
                                     UTType(filenameExtension: "2fas") ?? .data, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Wähle eine unverschlüsselte Exportdatei (Aegis, 2FAS, Ente Auth, Bitwarden, andOTP, CSV), die Datenbank „PhoneFactor“ aus Microsoft Authenticator oder eine MacAuth-Sicherung.")
        return await run(panel) == .OK ? panel.url : nil
    }

    /// Plain-text export for another app. The panel opens first; the file content is built only after a location was
    /// chosen (and the lock generation is still the same), never while the panel is open.
    static func savePlainExport(suggestedName: String, type: UTType) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.message = String(localized: "Achtung: Diese Datei enthält alle Schlüssel im Klartext. Speichere sie nicht in einem Cloud-Ordner und lösche sie nach dem Import.")
        return await run(panel) == .OK ? panel.url : nil
    }

    static func saveBackup(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: BackupFile.fileExtension) ?? .data]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.message = String(localized: "Wähle, wo das verschlüsselte Backup liegen soll.")
        return await run(panel) == .OK ? panel.url : nil
    }
}

/// Entry points of the import paths (file panel, drop, paste, typed link). Every path that waits (panel, file read,
/// image decoding) remembers the state it started in and drops its result if the app was locked meanwhile.
@MainActor
enum ImportFlow {
    static func chooseImages(model: AppModel) async {
        let ticket = model.ticket
        let urls = await FilePanels.openImages()
        guard !urls.isEmpty, model.isCurrent(ticket) else { return }
        present(await model.importer.ingest(files: urls, model: model), model: model, ticket: ticket)
    }

    static func chooseFile(model: AppModel) async {
        let ticket = model.ticket
        guard let url = await FilePanels.openImportFile(), model.isCurrent(ticket) else { return }
        await importFile(url, model: model, ticket: ticket)
    }

    /// Dropped files: images are QR screenshots, everything else goes through the file detector.
    static func handle(urls: [URL], model: AppModel) {
        let ticket = model.ticket
        let isImage: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) ?? false }
        let images = urls.filter(isImage)
        if !images.isEmpty {
            Task { present(await model.importer.ingest(files: images, model: model), model: model, ticket: ticket) }
        } else if let file = urls.first {
            Task { await importFile(file, model: model, ticket: ticket) }
        }
    }

    static func handle(text: String, model: AppModel) {
        let ticket = model.ticket
        present(model.importer.ingest(text: text, model: model), model: model, ticket: ticket)
    }

    static func paste(model: AppModel) {
        let ticket = model.ticket
        Task { present(await model.importer.ingestPasteboard(model: model), model: model, ticket: ticket) }
    }

    /// Reads the file off the main thread, recognises its format and opens the matching next step.
    static func importFile(_ url: URL, model: AppModel, ticket: Ticket) async {
        // Reading and recognising the file (possibly large) happens off the main actor, with a progress indicator.
        model.setBusy(String(localized: "Datei wird gelesen …"))
        let loaded: Result<(Data, ImportDetection), Error> = await Task.detached(priority: .userInitiated) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
                return .success((data, try ImportDetector.detect(data)))
            } catch let error as ImportError {
                return .failure(error)
            } catch {
                return .failure(BackupError.ioFailure(error.localizedDescription))
            }
        }.value
        model.setBusy(nil)
        guard model.isCurrent(ticket) else { return }
        do {
            let (data, detection) = try loaded.get()
            switch detection {
            case .accounts(let result):
                let skipped = result.skipped.map { "\($0.label) – \($0.reason.localizedText)" }
                // Never an empty review sheet: nothing usable and nothing to explain means "no codes found".
                if result.hasNothingToReview {
                    let message = result.mayBeIncomplete
                        ? String(localized: "In dieser Datenbank steht kein Konto. Sie wurde im laufenden Betrieb kopiert: Die Konten stehen vermutlich noch in der Begleitdatei „PhoneFactor-wal“. Führe die Dateien vorher zusammen, die Anleitung steht in der README. Es wurde nichts importiert.")
                        : result.rowsWithoutCode > 0
                        ? String(localized: "In dieser Datei steht bei keinem der \(result.rowsWithoutCode) Einträge ein Code für die Zwei-Faktor-Anmeldung. Es wurde nichts importiert.")
                        : String(localized: "In dieser Datei wurde kein Code für die Zwei-Faktor-Anmeldung gefunden. Es wurde nichts importiert.")
                    model.alert = AppAlert(title: String(localized: "Keine Codes gefunden"), message: message)
                    return
                }
                let delivery: ImportSession.Delivery = [.applePasswordsCSV, .genericCSV, .bitwarden].contains(result.format) ? .passwordFile : .file
                let session = model.makeSession(source: .file, delivery: delivery, accounts: result.accounts, skipped: skipped, groups: result.groups,
                                                format: result.format, rowsWithoutCode: result.rowsWithoutCode,
                                                mayBeIncomplete: result.mayBeIncomplete)
                model.sheet = .review(session)
            case .googleMigration(let links):
                present(model.importer.ingest(links, delivery: .file, model: model), model: model, ticket: ticket)
            case .macauthBackup:
                model.sheet = .restoreBackup(preset: BackupPreset(name: url.lastPathComponent, data: data), replace: false)
            }
        } catch {
            model.alert = AppAlert(title: String(localized: "Datei lässt sich nicht importieren"), message: ErrorText.message(for: error))
        }
    }

    /// A finished session opens the review sheet; otherwise the importer sheet shows progress or the problem.
    static func present(_ session: ImportSession?, model: AppModel, ticket: Ticket) {
        guard model.isCurrent(ticket) else { return }
        if let session {
            model.sheet = .review(session)
        } else if model.importer.progress != nil || model.importer.notice != nil {
            if model.sheet?.isImportGuide == true { return }
            model.sheet = .importer
        }
    }
}
