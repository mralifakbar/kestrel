import SwiftUI
import UniformTypeIdentifiers
import KestrelCore

struct ShareMenu: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu {
            Button("Save share image (light)…") { save(.light) }
            Button("Save share image (dark)…") { save(.dark) }
            Button("Copy share image") { copy(.dark) }
            Divider()
            Button("Copy dashboard as text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ShareText.make(model.snapshot), forType: .string)
            }
        } label: { Image(systemName: "square.and.arrow.up") }
        .help("Share")
    }

    @MainActor func image(_ scheme: ColorScheme) -> NSImage? {
        let r = ImageRenderer(content: ShareCard(snapshot: model.snapshot, cpu: model.series["cpu"]?.values ?? [], mem: model.series["mem"]?.values ?? [])
            .environment(\.colorScheme, scheme))
        r.proposedSize = .init(width: 1200, height: 630)
        r.scale = 1
        return r.nsImage
    }

    @MainActor func save(_ scheme: ColorScheme) {
        guard let img = image(scheme), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = "kestrel-\(scheme == .dark ? "dark" : "light").png"
        if p.runModal() == .OK, let url = p.url { try? png.write(to: url) }
    }

    @MainActor func copy(_ scheme: ColorScheme) {
        guard let img = image(scheme) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}

enum ShareText {
    static func make(_ s: SystemSnapshot) -> String {
        var l = ["\(s.model) · \(s.chip) · up \(Fmt.duration(s.uptime))",
                 "CPU \(Fmt.percent(s.cpu.total)) · load \(String(format: "%.2f", s.cpu.load1))",
                 "Memory \(Fmt.bytes(s.memory.used)) / \(Fmt.bytes(s.memory.total)) · pressure \(s.memory.pressureName)",
                 "GPU \(Fmt.percent(s.gpu.utilization))",
                 "Network ↓\(Fmt.rate(s.network.inBps)) ↑\(Fmt.rate(s.network.outBps))",
                 "Disk R \(Fmt.rate(s.disk.readBps)) W \(Fmt.rate(s.disk.writeBps))"]
        if s.thermals.cpuC > 0 { l.append("CPU \(Fmt.temp(s.thermals.cpuC)) · GPU \(Fmt.temp(s.thermals.gpuC))") }
        if s.power.available { l.append("Power \(Fmt.watts(s.power.systemWatts > 0 ? s.power.systemWatts : s.power.packageWatts))") }
        if s.battery.present { l.append("Battery \(Fmt.percent(s.battery.percent)) · health \(Fmt.percent(s.battery.health))") }
        l.append("Top apps: " + s.apps.prefix(5).map { "\($0.name) \(Fmt.cpu($0.cpu, cores: s.cpu.coreCount))" }.joined(separator: ", "))
        return l.joined(separator: "\n")
    }
}

/// 1200 × 630 card for sharing.
struct ShareCard: View {
    var snapshot: SystemSnapshot
    var cpu: [Double]
    var mem: [Double]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = snapshot
        let bg = scheme == .dark ? Color(red: 0.07, green: 0.08, blue: 0.10) : Color(red: 0.96, green: 0.96, blue: 0.97)
        let card = scheme == .dark ? Color.white.opacity(0.06) : Color.white
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.model).font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("\(s.chip) · \(Fmt.bytes(s.memory.total)) · up \(Fmt.duration(s.uptime))").font(.system(size: 22)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Kestrel", systemImage: "gauge.with.dots.needle.67percent").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                tile("CPU", Fmt.percent(s.cpu.total), s.cpu.total, Theme.color(.cpu, palette: .colorful), card)
                tile("Memory", Fmt.bytes(s.memory.used), s.memory.usedFraction, Theme.color(.memory, palette: .colorful), card)
                tile("GPU", Fmt.percent(s.gpu.utilization), s.gpu.utilization, Theme.color(.gpu, palette: .colorful), card)
                tile("Temp", Fmt.temp(s.thermals.cpuC), s.thermals.cpuC / 110, Theme.color(.temperature, palette: .colorful), card)
            }
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CPU · last minutes").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                    Sparkline(values: cpu, color: Theme.color(.cpu, palette: .colorful), maxValue: 1, lineWidth: 3).frame(height: 120)
                }
                .padding(24).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 20).fill(card))
                VStack(alignment: .leading, spacing: 10) {
                    Text("Busiest apps").font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(s.apps.prefix(4)) { a in
                        HStack { Text(a.name).lineLimit(1); Spacer(); Text(Fmt.cpu(a.cpu, cores: s.cpu.coreCount)).monospacedDigit() }.font(.system(size: 20))
                    }
                }
                .padding(24).frame(width: 420).background(RoundedRectangle(cornerRadius: 20).fill(card))
            }
        }
        .padding(48)
        .frame(width: 1200, height: 630, alignment: .topLeading)
        .background(bg)
        .foregroundStyle(scheme == .dark ? .white : .black)
    }

    func tile(_ t: String, _ v: String, _ f: Double, _ c: Color, _ card: Color) -> some View {
        HStack(spacing: 18) {
            ZStack { Ring(value: f, color: c, lineWidth: 12) }.frame(width: 70, height: 70)
            VStack(alignment: .leading) {
                Text(t).font(.system(size: 18, weight: .semibold)).foregroundStyle(.secondary)
                Text(v).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(22).frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 20).fill(card))
    }
}
