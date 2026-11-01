import SwiftUI
import AppKit
import KestrelCore

enum Palette: String, CaseIterable, Identifiable {
    case colorful, monochrome, accessible
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self { case .colorful: "Colorful"; case .monochrome: "Monochrome"; case .accessible: "Accessible" }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, neural, networkIn, networkOut, diskRead, diskWrite, power, temperature, battery, fan
    var id: String { rawValue }
}

struct Theme {
    static var palette: Palette { Palette(rawValue: UserDefaults.standard.string(forKey: "palette") ?? "") ?? .colorful }
    static var compact: Bool { UserDefaults.standard.bool(forKey: "compact") }

    static func color(_ m: Metric, palette: Palette = Theme.palette) -> Color {
        switch palette {
        case .monochrome:
            switch m {
            case .networkOut, .diskWrite: return Color.primary.opacity(0.45)
            default: return Color.primary.opacity(0.85)
            }
        case .accessible:
            // Okabe–Ito, distinguishable with common colour-vision deficiencies.
            switch m {
            case .cpu: return Color(red: 0.00, green: 0.45, blue: 0.70)
            case .memory: return Color(red: 0.80, green: 0.47, blue: 0.65)
            case .gpu: return Color(red: 0.90, green: 0.62, blue: 0.00)
            case .neural: return Color(red: 0.34, green: 0.71, blue: 0.91)
            case .networkIn, .diskRead: return Color(red: 0.00, green: 0.62, blue: 0.45)
            case .networkOut, .diskWrite: return Color(red: 0.84, green: 0.37, blue: 0.00)
            case .power, .battery: return Color(red: 0.94, green: 0.89, blue: 0.26)
            case .temperature, .fan: return Color(red: 0.84, green: 0.37, blue: 0.00)
            }
        case .colorful:
            switch m {
            case .cpu: return Color(red: 0.22, green: 0.56, blue: 1.0)
            case .memory: return Color(red: 0.62, green: 0.40, blue: 0.98)
            case .gpu: return Color(red: 0.98, green: 0.36, blue: 0.62)
            case .neural: return Color(red: 0.20, green: 0.80, blue: 0.80)
            case .networkIn: return Color(red: 0.20, green: 0.78, blue: 0.45)
            case .networkOut: return Color(red: 1.0, green: 0.62, blue: 0.20)
            case .diskRead: return Color(red: 0.25, green: 0.70, blue: 0.95)
            case .diskWrite: return Color(red: 0.96, green: 0.42, blue: 0.35)
            case .power: return Color(red: 1.0, green: 0.78, blue: 0.20)
            case .temperature: return Color(red: 1.0, green: 0.45, blue: 0.25)
            case .battery: return Color(red: 0.30, green: 0.82, blue: 0.40)
            case .fan: return Color(red: 0.45, green: 0.75, blue: 0.95)
            }
        }
    }

    static var strain: Color { palette == .accessible ? Color(red: 0.84, green: 0.37, blue: 0.0) : Color(red: 0.95, green: 0.26, blue: 0.24) }
    static var warn: Color { palette == .accessible ? Color(red: 0.90, green: 0.62, blue: 0.0) : .orange }
    static var good: Color { palette == .accessible ? Color(red: 0.0, green: 0.62, blue: 0.45) : Color(red: 0.25, green: 0.78, blue: 0.45) }

    static func level(_ fraction: Double, base: Color) -> Color {
        fraction >= 0.9 ? strain : fraction >= 0.75 ? warn : base
    }
}

// MARK: - Building blocks

struct Panel<Content: View, Accessory: View>: View {
    var title: LocalizedStringKey?
    var icon: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @AppStorage("compact") private var compact = false

    init(_ title: LocalizedStringKey? = nil, icon: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.accessory = accessory(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if title != nil || !(accessory is EmptyView) {
                HStack(spacing: 6) {
                    if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                    if let title { Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(.secondary) }
                    Spacer()
                    accessory
                }
            }
            content
        }
        .padding(compact ? 10 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double? = nil
    var fill = true
    var lineWidth: CGFloat = 1.5
    var capacity: Int? = nil

    var body: some View {
        Canvas { ctx, size in
            let pts = points(in: size)
            guard pts.count > 1 else { return }
            var line = Path()
            line.addLines(pts)
            if fill {
                var area = line
                area.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
                area.addLine(to: CGPoint(x: pts[0].x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let mx = max(maxValue ?? (values.max() ?? 1), 0.000001)
        let n = max(capacity ?? values.count, values.count)
        let step = size.width / CGFloat(max(n - 1, 1))
        let offset = CGFloat(n - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: offset + CGFloat(i) * step, y: size.height - CGFloat(min(max(v, 0) / mx, 1)) * (size.height - lineWidth) - lineWidth / 2)
        }
    }
}

/// Two series drawn mirrored around a centre line (e.g. download above, upload below).
struct MirrorGraph: View {
    var up: [Double]
    var down: [Double]
    var upColor: Color
    var downColor: Color
    var body: some View {
        let mx = max(up.max() ?? 0, down.max() ?? 0, 1)
        VStack(spacing: 1) {
            Sparkline(values: up, color: upColor, maxValue: mx)
            Sparkline(values: down, color: downColor, maxValue: mx).scaleEffect(x: 1, y: -1)
        }
    }
}

struct Ring: View {
    var value: Double
    var color: Color
    var lineWidth: CGFloat = 9
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(value, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct Meter: View {
    var value: Double
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(height, g.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

struct Segment: Identifiable {
    var id: String { label }
    var label: String
    var value: Double
    var color: Color
}

struct SegmentBar: View {
    var segments: [Segment]
    var total: Double
    var height: CGFloat = 12
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3).fill(s.color)
                        .frame(width: max(0, g.size.width * CGFloat(s.value / max(total, 1)) - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
    }
}

struct Figure: View {
    var label: LocalizedStringKey
    var value: String
    var color: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(.body, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FigureGrid: View {
    var items: [(LocalizedStringKey, String, Color?)]
    var columns = 3
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns), alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in Figure(label: it.0, value: it.1, color: it.2) }
        }
    }
}

struct Pill: View {
    var text: LocalizedStringKey
    var color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
    }
}

struct BigNumber: View {
    var value: String
    var caption: LocalizedStringKey
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func app(_ path: String?) -> NSImage {
        let key = path ?? "__exec"
        if let c = cache[key] { return c }
        let img: NSImage
        if let path { img = NSWorkspace.shared.icon(forFile: path) }
        else { img = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage() }
        img.size = NSSize(width: 32, height: 32)
        cache[key] = img
        return img
    }
}

struct AppIcon: View {
    var path: String?
    var system = false
    var size: CGFloat = 18
    var body: some View {
        if path == nil {
            Image(systemName: system ? "apple.logo" : "terminal").font(.system(size: size * 0.7)).frame(width: size, height: size).foregroundStyle(.secondary)
        } else {
            Image(nsImage: Icons.app(path)).resizable().frame(width: size, height: size)
        }
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ cond: Bool, _ transform: (Self) -> T) -> some View {
        if cond { transform(self) } else { self }
    }
}
