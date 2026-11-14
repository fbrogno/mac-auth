import AppKit
import AuthCore
import Observation

/// Turns scanned or pasted text into accounts: collects multi-QR Google exports ("2 of 3") and
/// hands a review session to the model once everything is there.
@MainActor @Observable
final class ImportCoordinator {
    private(set) var collector = MigrationBatchCollector()
    private(set) var notice: String?
    private(set) var isReading = false

    var progress: (scanned: Int, total: Int)? {
        guard let total = collector.expectedCount, collector.scannedCount > 0 else { return nil }
        return (collector.scannedCount, total)
    }

    func reset() {
        collector.reset()
        notice = nil
    }

    /// Feeds QR payloads. Returns a session when the import is complete.
    func ingest(_ payloads: [String], model: AppModel) -> ImportSession? {
        var links: [Account] = []
        var problems: [String] = []
        var sawNew = false
        for text in payloads {
            if MigrationCodec.isMigrationURI(text) {
                do {
                    let batch = try MigrationCodec.parse(uri: text)
                    switch collector.add(batch) {
                    case .added: sawNew = true
                    case .duplicate: break
                    case .otherExport: problems.append(String(localized: "Dieser QR-Code gehört zu einem anderen Export. Scanne die Codes eines Exports nacheinander."))
                    }
                } catch {
                    problems.append(ErrorText.message(for: error))
                }
            } else if OTPAuthURI.isOTPAuthURI(text) {
                do { links.append(try OTPAuthURI.parse(text)) } catch { problems.append(ErrorText.message(for: error)) }
            } else {
                problems.append(String(localized: "Das ist kein Authenticator-Code."))
            }
        }
        notice = sawNew || !links.isEmpty ? nil : problems.first
        if !links.isEmpty {
            return model.makeSession(source: .link, accounts: links)
        }
        if collector.isComplete {
            let session = model.makeSession(source: .google, accounts: collector.accounts, skipped: collector.skipped)
            collector.reset()
            return session
        }
        return nil
    }

    /// Reads image files off the main thread and feeds the results.
    func ingest(files: [URL], model: AppModel) async -> ImportSession? {
        isReading = true
        defer { isReading = false }
        let found = await Task.detached(priority: .userInitiated) {
            files.flatMap { url -> [String] in
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                return QRDecoder.payloads(at: url)
            }
        }.value
        if found.isEmpty {
            notice = String(localized: "In diesem Bild wurde kein QR-Code gefunden.")
            return nil
        }
        return ingest(found, model: model)
    }

    /// Text typed or pasted: otpauth link or Google export link.
    func ingest(text: String, model: AppModel) -> ImportSession? {
        ingest([text.trimmingCharacters(in: .whitespacesAndNewlines)], model: model)
    }

    /// ⌘V: image first, then text.
    func ingestPasteboard(model: AppModel) async -> ImportSession? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return await ingest(files: urls, model: model)
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage], let image = images.first {
            let found = await Task.detached(priority: .userInitiated) { QRDecoder.payloads(in: image) }.value
            if found.isEmpty {
                notice = String(localized: "In diesem Bild wurde kein QR-Code gefunden.")
                return nil
            }
            return ingest(found, model: model)
        }
        if let text = pasteboard.string(forType: .string), OTPAuthURI.isOTPAuthURI(text) || MigrationCodec.isMigrationURI(text) {
            return ingest(text: text, model: model)
        }
        notice = String(localized: "In der Zwischenablage liegt kein Bild und kein otpauth-Link.")
        return nil
    }
}
