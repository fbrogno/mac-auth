import AuthCore
import SwiftUI

/// Everything a card or row needs to draw itself for one clock tick.
struct AccountDisplay {
    let account: Account
    let code: String
    let groupedCode: String
    let nextCode: String?
    let remaining: Int
    let groupName: String?

    init(account: Account, now: Date, groupName: String?) {
        self.account = account
        let raw = (try? account.code(at: now)) ?? ""
        code = raw
        groupedCode = raw.isEmpty ? "— — —" : OTP.grouped(raw)
        remaining = account.remainingSeconds(at: now)
        let urgent = account.kind == .totp && remaining <= 5
        nextCode = urgent ? (try? account.nextCode(at: now)).map(OTP.grouped) : nil
        self.groupName = groupName
    }

    var urgent: Bool { account.kind == .totp && remaining <= 5 }

    var accessibilitySummary: String {
        let label = account.issuer.isEmpty ? account.name : "\(account.issuer), \(account.name)"
        let spokenCode = groupedCode
        if account.kind == .totp {
            let left = Measurement(value: Double(remaining), unit: UnitDuration.seconds).formatted(.measurement(width: .wide, usage: .asProvided))
            return String(localized: "\(label), Code \(spokenCode), noch \(left)")
        }
        return String(localized: "\(label), Code \(spokenCode)")
    }
}

struct AccountCard: View {
    let display: AccountDisplay
    let groupColor: Color?
    let badge: Int?
    let isSelected: Bool
    let isCopied: Bool
    let revealCode: Bool
    let onCopy: () -> Void
    let onNextHOTP: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var account: Account { display.account }
    private var codeVisible: Bool { revealCode || hovering || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                MonogramTile(account: account)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge { NumberBadge(number: badge).offset(x: 7, y: 7).transition(.scale.combined(with: .opacity)) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(account.issuer.isEmpty ? account.name : account.issuer)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if account.pinned {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        }
                    }
                    if !account.issuer.isEmpty {
                        Text(account.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if account.kind == .totp {
                    CountdownRing(remaining: display.remaining, period: account.period)
                }
            }
            ZStack(alignment: .leading) {
                codeRow.opacity(isCopied ? 0 : 1)
                if isCopied {
                    Label("Kopiert", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(height: 34, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(background)
        .overlay(alignment: .leading) {
            if let groupColor {
                Capsule().fill(groupColor).frame(width: 3).padding(.vertical, 14).padding(.leading, 5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.06), radius: hovering ? 9 : 2.5, y: hovering ? 4 : 1)
        .offset(y: hovering && !reduceMotion ? -1.5 : 0)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: hovering)
        .animation(reduceMotion ? nil : .spring(duration: 0.38, bounce: 0.3), value: isCopied)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .onTapGesture(perform: onCopy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Kopieren"), onCopy)
    }

    private var codeRow: some View {
        HStack(alignment: .center) {
            if account.kind == .hotp {
                Text(codeVisible ? display.groupedCode : "••• •••")
                    .font(.system(size: 28, weight: .medium).monospacedDigit())
                Spacer(minLength: 6)
                Button(action: onNextHOTP) {
                    Label("Nächster Code", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
            } else {
                Text(codeVisible ? display.groupedCode : "••• •••")
                    .font(.system(size: 28, weight: .medium).monospacedDigit())
                    .foregroundStyle(display.urgent ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: display.code)
                Spacer(minLength: 6)
                if let next = display.nextCode, codeVisible {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Danach").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(next).font(.system(size: 13, weight: .regular, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var background: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            if isCopied { Rectangle().fill(Color.green.opacity(0.13)) }
            else if isSelected { Rectangle().fill(Color.accentColor.opacity(0.07)) }
        }
    }

    private var borderColor: Color {
        if isCopied { return .green.opacity(0.7) }
        if isSelected { return .accentColor }
        return Color.primary.opacity(0.09)
    }
}

/// Small "⌘1" plaque shown while ⌘ is held.
struct NumberBadge: View {
    let number: Int

    var body: some View {
        Text("⌘\(number)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

struct AccountRow: View {
    let display: AccountDisplay
    let groupColor: Color?
    let badge: Int?
    let isSelected: Bool
    let isCopied: Bool
    let revealCode: Bool
    let onCopy: () -> Void
    let onNextHOTP: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var account: Account { display.account }
    private var codeVisible: Bool { revealCode || hovering || isSelected }

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(groupColor ?? .clear).frame(width: 3, height: 22)
            MonogramTile(account: account, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    if let badge { NumberBadge(number: badge).offset(x: 8, y: 7) }
                }
            HStack(spacing: 6) {
                Text(account.issuer.isEmpty ? account.name : account.issuer).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if !account.issuer.isEmpty {
                    Text(account.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if account.pinned { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.orange) }
            }
            Spacer(minLength: 8)
            if isCopied {
                Label("Kopiert", systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.green)
            } else {
                if let next = display.nextCode, codeVisible {
                    Text(next).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Text(codeVisible ? display.groupedCode : "••• •••")
                    .font(.system(size: 19, weight: .medium).monospacedDigit())
                    .foregroundStyle(display.urgent ? Color.red : Color.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: display.code)
            }
            if account.kind == .totp {
                CountdownRing(remaining: display.remaining, period: account.period, size: 22, showsNumber: false)
            } else {
                Button(action: onNextHOTP) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(Text("Nächster Code"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(
            isCopied ? Color.green.opacity(0.14) : isSelected ? Color.accentColor.opacity(0.14) : hovering ? Color.primary.opacity(0.05) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: hovering)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.25), value: isCopied)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .onTapGesture(perform: onCopy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Kopieren"), onCopy)
    }
}
