import SwiftUI
import Charts

/// A small caption over a monospaced value, with an optional detail line.
struct StatView: View {
    let title: String
    let value: String?
    var detail: String?
    var tint: Color?
    var valueFont: Font = .system(.callout, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? MenuBarMode.placeholder).font(valueFont).foregroundStyle(tint ?? .primary)
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Back", systemImage: "chevron.left") }
            .buttonStyle(.borderless)
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.subheadline).bold().foregroundStyle(.secondary)
    }
}

/// Makes a plain button look like a list row that highlights on hover.
struct HoverRowStyle: ButtonStyle {
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(verticalPadding: verticalPadding) { configuration.label }
    }

    private struct HoverRow<Content: View>: View {
        let verticalPadding: CGFloat
        @ViewBuilder let content: () -> Content
        @State private var hovering = false

        var body: some View {
            content()
                .padding(.vertical, verticalPadding)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A tiny chart of a metric's peaks, without axes.
struct Sparkline: View {
    let points: [HistoryPoint]

    var body: some View {
        Chart(points) { p in
            LineMark(x: .value("Time", p.t), y: .value("Value", p.max), series: .value("Segment", p.segment))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .foregroundStyle(Color.accentColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartLegend(.hidden)
    }
}

/// A clickable row: icon, title and subtitle, last-hour sparkline, current value.
struct MetricRow<Accessory: View>: View {
    let metric: Metric
    let value: Double?
    let subtitle: String?
    let history: [HistoryPoint]
    let fahrenheit: Bool
    let action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: metric.symbol)
                    .frame(width: 22)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title).font(.body)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    accessory()
                }
                Spacer()
                Sparkline(points: history)
                    .frame(width: 70, height: 22)
                Text(value.map { metric.unit.format($0, fahrenheit: fahrenheit) } ?? MenuBarMode.placeholder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 52, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(HoverRowStyle())
    }

    private var tint: Color { value.map { metric.tint(for: $0) } ?? .secondary }
}

extension MetricRow where Accessory == EmptyView {
    init(metric: Metric, value: Double?, subtitle: String?, history: [HistoryPoint], fahrenheit: Bool,
         action: @escaping () -> Void) {
        self.init(metric: metric, value: value, subtitle: subtitle, history: history, fahrenheit: fahrenheit,
                  action: action) { EmptyView() }
    }
}
