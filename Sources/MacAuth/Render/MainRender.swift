import SwiftUI

/// Stand-in for the window chrome in documentation images: the system split view and toolbar are
/// not drawn when a window is captured off screen, so the renderer composes the same views by hand.
extension MainView {
    var documentationBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TrafficLights()
                Spacer()
                SearchField(text: .constant(model.search), focus: $focus, onKey: { _ in .ignored }, onSubmit: {})
                    .frame(width: 300)
                Spacer()
                Picker("Darstellung", selection: .constant(model.settings.listMode)) {
                    Label("Raster", systemImage: "square.grid.2x2").tag(false)
                    Label("Liste", systemImage: "list.bullet").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 84)
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 24)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 14).frame(height: 52)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 215)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                Divider()
                content
            }
        }
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(["FF5F57", "FEBC2E", "28C840"], id: \.self) { hex in
                Circle().fill(Color(hex: hex)).frame(width: 12, height: 12)
            }
        }
        .padding(.leading, 4)
        .accessibilityHidden(true)
    }
}
