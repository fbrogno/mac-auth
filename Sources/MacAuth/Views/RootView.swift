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
        .environment(\.protectScreen, model.settings.protectScreen)
        .background(WindowConfigurator(isMainWindow: true))
        .sheet(item: $model.sheet) { sheet in SheetRouter(model: model, sheet: sheet).environment(\.protectScreen, model.settings.protectScreen) }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert?.message ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.phase == .firstRun || model.phase == .unlocked else { return false }
            ImportFlow.handle(urls: urls, model: model)
            return true
        }
        .task { await model.start() }
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
        case .review(let session): ReviewSheet(model: model, session: session)
        case .restoreBackup: RestoreSheet(model: model)
        case .exportBackup: ExportBackupSheet(model: model)
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
    static func openImages() async -> [URL] {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.message = String(localized: "Wähle einen Screenshot oder ein Foto mit dem QR-Code. Das Bild wird nicht gespeichert.")
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.urls : []) }
        }
    }

    static func openBackup() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: BackupFile.fileExtension) ?? .data, .json, .data]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = String(localized: "Wähle eine MacAuth-Backup-Datei.")
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }

    static func saveBackup(suggestedName: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: BackupFile.fileExtension) ?? .data]
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            panel.message = String(localized: "Wähle, wo das verschlüsselte Backup liegen soll.")
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
}

/// Entry points of the import paths (file panel, drop, paste, typed link).
@MainActor
enum ImportFlow {
    static func chooseImages(model: AppModel) async {
        let urls = await FilePanels.openImages()
        guard !urls.isEmpty else { return }
        present(await model.importer.ingest(files: urls, model: model), model: model)
    }

    static func handle(urls: [URL], model: AppModel) {
        let images = urls.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) ?? false }
        guard !images.isEmpty else { return }
        Task { present(await model.importer.ingest(files: images, model: model), model: model) }
    }

    static func handle(text: String, model: AppModel) {
        present(model.importer.ingest(text: text, model: model), model: model)
    }

    static func paste(model: AppModel) {
        Task { present(await model.importer.ingestPasteboard(model: model), model: model) }
    }

    /// A finished session opens the review sheet; otherwise the importer sheet shows progress or the problem.
    static func present(_ session: ImportSession?, model: AppModel) {
        if let session {
            model.sheet = .review(session)
        } else if model.importer.progress != nil || model.importer.notice != nil {
            if case .importer = model.sheet { return }
            model.sheet = .importer
        }
    }
}
