import AppKit
import AuthCore
import SwiftUI

extension Color {
    /// `#RRGGBB` or `RRGGBB`; falls back to grey.
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// A colour that differs between light and dark appearance.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }
}

/// Monogram colours: dark enough for white letters in light mode, a touch lighter in dark mode.
enum MonogramPalette {
    private static let hexes = ["4F46E5", "2563EB", "0369A1", "0F766E", "15803D", "B45309", "C2410C", "4D7C0F",
                                "BE185D", "7E22CE", "6D28D9", "475569", "7C5A2B", "0E7490"]

    static func color(for key: String) -> Color {
        // FNV-1a, so the colour is stable across launches (Swift's hashValue is randomised).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.lowercased().utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let hex = hexes[Int(hash % UInt64(hexes.count))]
        let base = Color(hex: hex)
        return .dynamic(light: base, dark: Color(nsColor: NSColor(base).blended(withFraction: 0.18, of: .white) ?? NSColor(base)))
    }

    static func letters(for account: Account) -> String {
        let source = account.issuer.isEmpty ? account.name : account.issuer
        let words = source.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String((words.first ?? "?").prefix(2)).uppercased()
    }

    static func key(for account: Account) -> String { account.issuer.isEmpty ? account.name : account.issuer }
}

struct MonogramTile: View {
    let account: Account
    var size: CGFloat = 44

    var body: some View {
        Text(MonogramPalette.letters(for: account))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(MonogramPalette.color(for: MonogramPalette.key(for: account)), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct CountdownRing: View {
    let remaining: Int
    let period: Int
    var size: CGFloat = 28
    var showsNumber = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var urgent: Bool { remaining <= 5 }

    var body: some View {
        // Each tick moves the ring to where it will be one second later; the linear animation fills the gap.
        let target = max(0, Double(remaining - 1)) / Double(max(period, 1))
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: size > 24 ? 3 : 2.5)
            Circle()
                .trim(from: 0, to: target)
                .stroke(urgent ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: size > 24 ? 3 : 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion || remaining == period ? nil : .linear(duration: 1), value: target)
            if showsNumber {
                Text("\(remaining)")
                    .font(.system(size: size * 0.36, weight: .medium).monospacedDigit())
                    .foregroundStyle(urgent ? Color.red : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared clock

private struct FixedNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// Set by the documentation renderer so images are reproducible.
    var fixedNow: Date? {
        get { self[FixedNowKey.self] }
        set { self[FixedNowKey.self] = newValue }
    }
}

/// One shared once-per-second clock for everything below it (not a timer per card). SwiftUI stops
/// the schedule while the window is not visible.
struct Ticker<Content: View>: View {
    @Environment(\.fixedNow) private var fixedNow
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let fixedNow {
            content(fixedNow)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), by: 1)) { context in
                content(context.date)
            }
        }
    }
}

// MARK: - Sheet scaffold

/// Common frame for sheets: title, optional subtitle, content, footer buttons.
struct SheetScaffold<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 480
    var contentPadding = true
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
            content.padding(.horizontal, contentPadding ? 24 : 0).padding(.bottom, contentPadding ? 18 : 0)
            Divider()
            HStack(spacing: 10) {
                footer
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: width)
        .background(.background)
        .background(WindowConfigurator(isMainWindow: false))
    }
}
