import AuthCore
import SwiftUI

struct GroupSheet: View {
    @Bindable var model: AppModel
    let existing: AccountGroup?
    @State private var name: String
    @State private var symbol: String
    @State private var colour: String
    @Environment(\.dismiss) private var dismiss

    static let symbols = ["folder", "building.2", "house", "briefcase", "person", "person.2", "cart", "creditcard", "gamecontroller",
                          "gearshape", "globe", "lock", "heart", "cloud", "server.rack", "terminal", "envelope", "airplane"]
    static let colours = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#6366F1", "#8E8E93"]

    init(model: AppModel, existing: AccountGroup?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _symbol = State(initialValue: existing?.symbol ?? "folder")
        _colour = State(initialValue: existing?.colour ?? Self.colours[model.groups.count % Self.colours.count])
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetScaffold(title: existing == nil ? String(localized: "Neue Gruppe") : String(localized: "Gruppe bearbeiten"), width: 420) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Farbe").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(Self.colours, id: \.self) { hex in
                            Button { colour = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.white.opacity(colour == hex ? 0.9 : 0), lineWidth: 2))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(colour == hex ? 0.5 : 0), lineWidth: 1).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Farbe \(hex)"))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Symbol").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 9), spacing: 6) {
                        ForEach(Self.symbols, id: \.self) { name in
                            Button { symbol = name } label: {
                                Image(systemName: name)
                                    .foregroundStyle(symbol == name ? Color.white : Color(hex: colour))
                                    .frame(width: 34, height: 30)
                                    .background(symbol == name ? Color(hex: colour) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } footer: {
            Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                if var group = existing {
                    group.name = trimmed; group.symbol = symbol; group.colour = colour
                    model.updateGroup(group)
                } else {
                    let group = AccountGroup(name: trimmed, symbol: symbol, colour: colour)
                    model.addGroup(group)
                    model.sidebar = .group(group.id)
                }
                dismiss()
            } label: {
                if existing == nil { Text("Anlegen") } else { Text("Sichern") }
            }
            .keyboardShortcut(.defaultAction).primaryButtonStyle().disabled(trimmed.isEmpty)
        }
    }
}

struct DeleteAccountSheet: View {
    @Bindable var model: AppModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let account = model.account(id)
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.orange)
            Text("„\(account?.displayLabel ?? "")“ löschen?").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("Ohne diesen Code kommst du eventuell nicht mehr in dein Konto. Prüfe vorher, dass du einen anderen Zugang hast, zum Beispiel Wiederherstellungscodes, oder den Code auf einem anderen Gerät. Das Löschen lässt sich nicht rückgängig machen.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Return = cancel; "Löschen" has no shortcut. Esc still closes the sheet.
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.defaultAction).primaryButtonStyle()
                Button("Löschen", role: .destructive) { model.delete(id); dismiss() }.tint(.red)
            }
            .padding(.top, 4)
        }
        .padding(26)
        .frame(width: 400)
        .background(.background)
    }
}
