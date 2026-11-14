import AuthCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var groupToDelete: AccountGroup?
    @State private var dropTarget: UUID?

    var body: some View {
        List(selection: $model.sidebar) {
            Section {
                Label("Alle", systemImage: "key.horizontal")
                    .badge(model.count(for: .all))
                    .tag(SidebarItem.all)
                Label {
                    Text("Favoriten")
                } icon: {
                    Image(systemName: "star").foregroundStyle(.orange)
                }
                .badge(model.count(for: .favorites))
                .tag(SidebarItem.favorites)
            }
            Section("Gruppen") {
                ForEach(model.groups) { group in
                    Label {
                        Text(group.name)
                    } icon: {
                        Image(systemName: group.symbol).foregroundStyle(Color(hex: group.colour))
                    }
                    .badge(model.count(for: .group(group.id)))
                    .tag(SidebarItem.group(group.id))
                    .listRowBackground(dropTarget == group.id ? Color.accentColor.opacity(0.25) : nil)
                    .dropDestination(for: String.self) { items, _ in
                        guard let id = items.compactMap({ UUID(uuidString: $0) }).first else { return false }
                        model.move(id, to: group.id)
                        return true
                    } isTargeted: { targeted in
                        dropTarget = targeted ? group.id : (dropTarget == group.id ? nil : dropTarget)
                    }
                    .contextMenu {
                        Button("Gruppe bearbeiten …") { model.sheet = .editGroup(group.id) }
                        Button("Alle Konten der Gruppe übertragen …") {
                            let ids = Set(model.accounts.filter { $0.groupID == group.id }.map(\.id))
                            Task { await BackupFlow.startTransfer(model, ids: ids) }
                        }
                        Divider()
                        Button("Gruppe löschen …", role: .destructive) { groupToDelete = group }
                    }
                }
                Button {
                    model.sheet = .newGroup
                } label: {
                    Label("Gruppe", systemImage: "plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .confirmationDialog(
            Text("Gruppe „\(groupToDelete?.name ?? "")“ löschen?"),
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Abbrechen", role: .cancel) { groupToDelete = nil }
            Button("Gruppe löschen", role: .destructive) {
                if let group = groupToDelete { model.deleteGroup(group.id) }
                groupToDelete = nil
            }
        } message: {
            Text("Die Konten bleiben erhalten und sind danach in keiner Gruppe.")
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if model.settings.needsBackup(hasAccounts: !model.accounts.isEmpty) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Noch kein Backup seit der letzten Änderung", systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Backup exportieren …") { Task { await BackupFlow.startExport(model) } }
                        .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .floatingGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: Color.orange.opacity(0.25))
            }
            Button {
                model.lock()
            } label: {
                Label("Sperren", systemImage: "lock")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(model.isDemo)
            .help(Text("MacAuth sperren (⌘L)"))
        }
        .padding(10)
    }
}
