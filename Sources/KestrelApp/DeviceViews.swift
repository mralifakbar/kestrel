import SwiftUI
import KestrelCore

struct SoundView: View {
    @EnvironmentObject var audio: AudioController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Sound", subtitle: "Output, microphone and per-app volume")
            HStack(alignment: .top, spacing: 14) {
                Panel("Output", icon: "speaker.wave.2") {
                    Picker("Device", selection: Binding(get: { audio.defaultOutput }, set: { audio.setDefault($0, input: false) })) {
                        ForEach(audio.outputs) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button { audio.toggleOutputMute() } label: { Image(systemName: audio.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.buttonStyle(.borderless)
                        Slider(value: Binding(get: { Double(audio.outputVolume) }, set: { audio.setOutputVolume(Float($0)) }), in: 0...1)
                        Text(Fmt.percent(Double(audio.outputVolume))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!audio.outputVolumeSettable)
                    if !audio.outputVolumeSettable { Text("This device doesn't support software volume.").font(.caption).foregroundStyle(.secondary) }
                }
                Panel("Microphone", icon: "mic") {
                    Picker("Device", selection: Binding(get: { audio.defaultInput }, set: { audio.setDefault($0, input: true) })) {
                        ForEach(audio.inputs) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Image(systemName: "mic.fill").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(audio.inputVolume) }, set: { audio.setInputVolume(Float($0)) }), in: 0...1)
                        Text(Fmt.percent(Double(audio.inputVolume))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                    .disabled(!audio.inputVolumeSettable)
                }
            }
            Panel("Apps", icon: "app.badge", accessory: { Button { audio.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless) }) {
                if audio.apps.isEmpty { Text("No apps are using audio right now.").foregroundStyle(.secondary) }
                ForEach(audio.apps) { a in
                    HStack(spacing: 10) {
                        AppIcon(path: a.bundlePath, size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.name).lineLimit(1)
                            Text(a.isPlaying ? "Playing" : "Idle").font(.caption2).foregroundStyle(a.isPlaying ? Theme.good : .secondary)
                        }
                        .frame(width: 180, alignment: .leading)
                        Button { audio.toggleMute(a) } label: { Image(systemName: audio.isMuted(a) ? "speaker.slash.fill" : "speaker.wave.2") }.buttonStyle(.borderless)
                        Slider(value: Binding(get: { Double(audio.volume(for: a)) }, set: { audio.setVolume(Float($0), for: a) }), in: 0...1)
                        Text(Fmt.percent(Double(audio.volume(for: a)))).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                if let e = audio.lastError { Text(e).font(.caption).foregroundStyle(Theme.strain) }
                Text("Per-app volume uses macOS audio taps (macOS 14.4+). The first change asks for permission to capture system audio; nothing is recorded or stored.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { audio.refresh(); audio.startPolling() }
        .onDisappear { audio.stopPolling() }
    }
}

struct BluetoothView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Bluetooth", subtitle: "\(model.bluetooth.filter(\.connected).count) connected devices")
            if model.bluetooth.isEmpty { Panel { Text("Looking for devices…").foregroundStyle(.secondary) } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(model.bluetooth) { d in
                    Panel {
                        HStack {
                            Image(systemName: icon(d.kind)).font(.title2).frame(width: 30).foregroundStyle(d.connected ? Theme.color(.cpu) : .secondary)
                            VStack(alignment: .leading) {
                                Text(d.name).font(.headline).lineLimit(1)
                                Text(d.connected ? LocalizedStringKey(d.kind) : "Not connected").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if let b = d.battery { battery("Battery", b) }
                        if let b = d.batteryLeft { battery("Left", b) }
                        if let b = d.batteryRight { battery("Right", b) }
                        if let b = d.batteryCase { battery("Case", b) }
                    }
                    .opacity(d.connected ? 1 : 0.6)
                }
            }
        }
    }

    func battery(_ label: LocalizedStringKey, _ v: Int) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
            Meter(value: Double(v) / 100, color: v < 20 ? Theme.strain : Theme.color(.battery), height: 6)
            Text("\(v)%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
        }
    }

    func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case let k where k.contains("keyboard"): "keyboard"
        case let k where k.contains("mouse"): "computermouse"
        case let k where k.contains("trackpad"): "rectangle.and.hand.point.up.left"
        case let k where k.contains("head") || k.contains("airpods"): "airpodspro"
        case let k where k.contains("controller"): "gamecontroller"
        case let k where k.contains("speaker"): "hifispeaker"
        case let k where k.contains("phone"): "iphone"
        default: "dot.radiowaves.left.and.right"
        }
    }
}
