import SwiftUI
import DokkitKit

struct StateMark: View {
    let level: Level
    @ScaledMetric(relativeTo: .body) private var size = 11

    var body: some View {
        HStack(spacing: 6) {
            shape.frame(width: size, height: size)
            Text(level.word).font(.caption.weight(.medium)).foregroundStyle(Theme.color(level))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("State \(level.word)")
    }

    @ViewBuilder private var shape: some View {
        switch level {
        case .ok: RoundedRectangle(cornerRadius: 3).fill(Theme.ok)
        case .degraded: Rectangle().fill(Theme.warn).rotationEffect(.degrees(45)).scaleEffect(0.86)
        case .down: Rectangle().fill(Theme.bad)
        case .unknown, .unwatched: Rectangle().strokeBorder(Theme.mute, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
        case .other: Circle().strokeBorder(Theme.mute, lineWidth: 1.5)
        }
    }
}

struct Card<Content: View>: View {
    var title: String?
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    Text(title).font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.mute) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 44)
                Divider().overlay(Theme.line)
            }
            content
        }
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

struct RowDivider: View {
    var body: some View { Divider().overlay(Theme.line).padding(.leading, 16) }
}

struct Spark: View {
    let values: [Double?]

    var body: some View {
        let present: [Double] = values.compactMap { $0 }
        Canvas { ctx, size in
            let hi: Double = present.max() ?? 0
            guard hi > 0, !values.isEmpty else { return }
            let w: CGFloat = size.width / CGFloat(values.count)
            for (i, item) in values.enumerated() {
                guard let v = item else { continue }
                let h: CGFloat = max(2, size.height * CGFloat(v / hi))
                let rect = CGRect(x: CGFloat(i) * w + 0.5, y: size.height - h, width: max(1, w - 1), height: h)
                ctx.fill(Path(rect), with: .color(Theme.mute.opacity(0.6)))
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chart of the last \(values.count) hours")
        .accessibilityValue(present.last.map { "latest \(Int($0.rounded()))" } ?? "")
    }
}

struct Tag: View {
    let text: String
    var warn = false

    var body: some View {
        Text(text)
            .font(.caption).foregroundStyle(warn ? Theme.warn : Theme.mute)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(warn ? Theme.warn.opacity(0.15) : Theme.chip, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct Notice: View {
    let title: String
    let text: String
    var systemImage = "tray"

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(Theme.mute).accessibilityHidden(true)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(Theme.mute).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct AgeBanner: View {
    let freshness: Freshness

    private var label: String {
        let prefix = freshness.isWarning ? "Warning. " : ""
        return prefix + freshness.text + ". " + (freshness.detail ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(freshness.text, systemImage: freshness.isWarning ? "exclamationmark.triangle.fill" : "clock")
                .font(.footnote.weight(freshness.isWarning ? .semibold : .regular))
                .foregroundStyle(freshness.isWarning ? Theme.warn : Theme.mute)
            if let d = freshness.detail {
                Text(d).font(.footnote).foregroundStyle(freshness.isWarning ? Theme.warn : Theme.mute)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(freshness.isWarning ? Theme.warn.opacity(0.15) : Theme.chip, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
