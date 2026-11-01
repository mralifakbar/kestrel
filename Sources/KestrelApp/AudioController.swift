import Foundation
import AppKit
import CoreAudio
import AudioToolbox

struct AudioDevice: Identifiable, Hashable {
    var id: AudioObjectID
    var uid: String
    var name: String
}

struct AudioApp: Identifiable, Hashable {
    var id: String { key }
    var key: String            // bundle id or "pid:N"
    var name: String
    var bundlePath: String?
    var pid: pid_t
    var objectIDs: [AudioObjectID]
    var isPlaying: Bool
}

// MARK: - Core Audio helpers

enum CA {
    static func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, default d: T) -> T {
        var addr = address(sel, scope, el)
        var v = d
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : d
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, _ value: T) -> Bool {
        var addr = address(sel, scope, el)
        var v = value
        return AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    static func has(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = address(sel, scope, el)
        return AudioObjectHasProperty(obj, &addr)
    }

    static func settable(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = address(sel, scope, el)
        var s: DarwinBoolean = false
        return AudioObjectHasProperty(obj, &addr) && AudioObjectIsPropertySettable(obj, &addr, &s) == noErr && s.boolValue
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(sel, scope)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr, let s = v?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func array(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func channelCount(_ dev: AudioObjectID, input: Bool) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Controller

@MainActor
final class AudioController: ObservableObject {
    static let shared = AudioController()

    @Published var outputs: [AudioDevice] = []
    @Published var inputs: [AudioDevice] = []
    @Published var defaultOutput: AudioObjectID = 0
    @Published var defaultInput: AudioObjectID = 0
    @Published var outputVolume: Float = 0
    @Published var inputVolume: Float = 0
    @Published var outputMuted = false
    @Published var outputVolumeSettable = false
    @Published var inputVolumeSettable = false
    @Published var apps: [AudioApp] = []
    @Published var lastError: String?

    private var volumes: [String: Float] = (UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Float]) ?? [:]
    private var muted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "appMuted") ?? [])
    private var taps: [String: Any] = [:]   // key -> AppTap (macOS 14.4+)
    private var timer: Timer?
    private var pollers = 0

    private init() {
        refresh()
        // Re-apply saved per-app volumes whenever apps start making sound.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.pollers == 0, !(self.volumes.isEmpty && self.muted.isEmpty) { self.refresh() } }
        }
    }

    func startPolling() {
        pollers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func stopPolling() {
        pollers = max(0, pollers - 1)
        if pollers == 0 { timer?.invalidate(); timer = nil }
    }

    func refresh() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let devs = CA.array(sys, kAudioHardwarePropertyDevices)
        var outs: [AudioDevice] = [], ins: [AudioDevice] = []
        for d in devs {
            let name = CA.string(d, kAudioObjectPropertyName) ?? "Device \(d)"
            let uid = CA.string(d, kAudioDevicePropertyDeviceUID) ?? ""
            if name.hasPrefix("Kestrel-") || uid.hasPrefix("dev.kestrel.") { continue }
            if CA.channelCount(d, input: false) > 0 { outs.append(AudioDevice(id: d, uid: uid, name: name)) }
            if CA.channelCount(d, input: true) > 0 { ins.append(AudioDevice(id: d, uid: uid, name: name)) }
        }
        outputs = outs; inputs = ins
        let newOut: AudioObjectID = CA.get(sys, kAudioHardwarePropertyDefaultOutputDevice, default: 0)
        if newOut != defaultOutput && defaultOutput != 0 { rebuildTaps(outputChanged: true) }
        defaultOutput = newOut
        defaultInput = CA.get(sys, kAudioHardwarePropertyDefaultInputDevice, default: 0)
        outputVolume = volume(device: defaultOutput, scope: kAudioObjectPropertyScopeOutput)
        inputVolume = volume(device: defaultInput, scope: kAudioObjectPropertyScopeInput)
        outputVolumeSettable = volumeSettable(defaultOutput, kAudioObjectPropertyScopeOutput)
        inputVolumeSettable = volumeSettable(defaultInput, kAudioObjectPropertyScopeInput)
        outputMuted = CA.get(defaultOutput, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0
        refreshApps()
    }

    private func refreshApps() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard #available(macOS 14.2, *) else { return }
        let procs = CA.array(sys, kAudioHardwarePropertyProcessObjectList)
        var byKey: [String: AudioApp] = [:]
        let me = ProcessInfo.processInfo.processIdentifier
        for obj in procs {
            let pid: pid_t = CA.get(obj, kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != me else { continue }
            let playing: UInt32 = CA.get(obj, kAudioProcessPropertyIsRunningOutput, default: 0)
            let bundle = CA.string(obj, kAudioProcessPropertyBundleID) ?? ""
            // Fold helpers into their parent app (e.g. browser audio helpers).
            let running = NSRunningApplication(processIdentifier: pid)
            var appURL = running?.bundleURL
            if let path = running?.bundleURL?.path ?? Optional(KestrelPathFor(pid)), let r = path.range(of: ".app/") ?? path.range(of: ".app", options: .backwards) {
                appURL = URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
            }
            let outer = appURL.flatMap { Bundle(url: $0) }
            let key = outer?.bundleIdentifier ?? (bundle.isEmpty ? "pid:\(pid)" : bundle)
            let name = (outer?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (outer?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? running?.localizedName ?? (bundle.isEmpty ? "pid \(pid)" : bundle)
            var entry = byKey[key] ?? AudioApp(key: key, name: name, bundlePath: appURL?.path, pid: pid, objectIDs: [], isPlaying: false)
            entry.objectIDs.append(obj)
            entry.isPlaying = entry.isPlaying || playing != 0
            byKey[key] = entry
        }
        let keep = byKey.values.filter { $0.isPlaying || taps[$0.key] != nil || volumes[$0.key] != nil || muted.contains($0.key) }
        apps = keep.sorted { ($0.isPlaying ? 0 : 1, $0.name) < ($1.isPlaying ? 0 : 1, $1.name) }
        // Apply saved settings to apps that are now present.
        for a in apps where needsTap(a.key) && taps[a.key] == nil { applyTap(a) }
        // Drop taps for apps that went away.
        let live = Set(byKey.keys)
        for k in taps.keys where !live.contains(k) { removeTap(k) }
    }

    // MARK: device volume

    private func volume(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float {
        if CA.has(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) {
            return CA.get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, default: Float32(0))
        }
        if CA.has(device, kAudioDevicePropertyVolumeScalar, scope, 0) { return CA.get(device, kAudioDevicePropertyVolumeScalar, scope, 0, default: Float32(0)) }
        return CA.get(device, kAudioDevicePropertyVolumeScalar, scope, 1, default: Float32(0))
    }

    private func volumeSettable(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        CA.settable(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) || CA.settable(d, kAudioDevicePropertyVolumeScalar, scope, 0) || CA.settable(d, kAudioDevicePropertyVolumeScalar, scope, 1)
    }

    private func setVolume(device: AudioObjectID, scope: AudioObjectPropertyScope, _ v: Float) {
        if CA.settable(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) {
            CA.set(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, kAudioObjectPropertyElementMain, Float32(v))
        } else if CA.settable(device, kAudioDevicePropertyVolumeScalar, scope, 0) {
            CA.set(device, kAudioDevicePropertyVolumeScalar, scope, 0, Float32(v))
        } else {
            for ch: UInt32 in 1...2 { CA.set(device, kAudioDevicePropertyVolumeScalar, scope, ch, Float32(v)) }
        }
    }

    func setOutputVolume(_ v: Float) { setVolume(device: defaultOutput, scope: kAudioObjectPropertyScopeOutput, v); outputVolume = v }
    func setInputVolume(_ v: Float) { setVolume(device: defaultInput, scope: kAudioObjectPropertyScopeInput, v); inputVolume = v }
    func toggleOutputMute() {
        outputMuted.toggle()
        CA.set(defaultOutput, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, UInt32(outputMuted ? 1 : 0))
    }

    func setDefault(_ id: AudioObjectID, input: Bool) {
        CA.set(AudioObjectID(kAudioObjectSystemObject), input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, id)
        refresh()
    }

    // MARK: per-app volume

    func volume(for a: AudioApp) -> Float { volumes[a.key] ?? 1 }
    func isMuted(_ a: AudioApp) -> Bool { muted.contains(a.key) }
    private func needsTap(_ key: String) -> Bool { muted.contains(key) || (volumes[key] ?? 1) < 0.995 }

    func setVolume(_ v: Float, for a: AudioApp) {
        if v >= 0.995 { volumes[a.key] = nil } else { volumes[a.key] = v }
        save()
        updateTap(for: a)
    }

    func toggleMute(_ a: AudioApp) {
        if muted.contains(a.key) { muted.remove(a.key) } else { muted.insert(a.key) }
        save()
        updateTap(for: a)
    }

    private func save() {
        UserDefaults.standard.set(volumes, forKey: "appVolumes")
        UserDefaults.standard.set(Array(muted), forKey: "appMuted")
        objectWillChange.send()
    }

    private func gain(_ key: String) -> Float { muted.contains(key) ? 0 : (volumes[key] ?? 1) }

    private func updateTap(for a: AudioApp) {
        if needsTap(a.key) {
            if #available(macOS 14.2, *), let t = taps[a.key] as? AppTap { t.gain = gain(a.key) } else { applyTap(a) }
        } else {
            removeTap(a.key)
        }
    }

    private func applyTap(_ a: AudioApp) {
        guard #available(macOS 14.2, *) else { lastError = "Per-app volume needs macOS 14.4 or later."; return }
        guard let out = outputs.first(where: { $0.id == defaultOutput }) else { return }
        do {
            let t = try AppTap(processObjects: a.objectIDs, outputUID: out.uid, gain: gain(a.key))
            taps[a.key] = t
            lastError = nil
        } catch {
            lastError = "Couldn't control \(a.name): \(error.localizedDescription). Allow Kestrel under System Settings → Privacy & Security → Screen & System Audio Recording."
        }
    }

    private func removeTap(_ key: String) {
        if #available(macOS 14.2, *), let t = taps[key] as? AppTap { t.stop() }
        taps[key] = nil
    }

    private func rebuildTaps(outputChanged: Bool) {
        let keys = Array(taps.keys)
        keys.forEach(removeTap)
    }

    func teardown() { Array(taps.keys).forEach(removeTap) }
}

func KestrelPathFor(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

struct AudioError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Routes one app's audio through a muted process tap and plays it back at a chosen gain.
@available(macOS 14.2, *)
final class AppTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let gainBox = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    var gain: Float {
        get { gainBox.pointee }
        set { gainBox.pointee = newValue }
    }

    init(processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        gainBox.initialize(to: gain)
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "Kestrel volume"
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw AudioError(message: "tap failed (\(status))") }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kestrel-\(processObjects.first ?? 0)",
            kAudioAggregateDeviceUIDKey: "dev.kestrel.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID)
        guard status == noErr else { AudioHardwareDestroyProcessTap(tapID); throw AudioError(message: "device failed (\(status))") }

        let g = gainBox
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inInput, _, outOutput, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            let outs = UnsafeMutableAudioBufferListPointer(outOutput)
            let gain = g.pointee
            // The tap is the last input stream on the aggregate device.
            guard let src = ins.last, let sp = src.mData else {
                for o in outs { if let d = o.mData { memset(d, 0, Int(o.mDataByteSize)) } }
                return
            }
            let sIn = sp.assumingMemoryBound(to: Float.self)
            let inSamples = Int(src.mDataByteSize) / MemoryLayout<Float>.size
            let inCh = max(Int(src.mNumberChannels), 1)
            let frames = inSamples / inCh
            for o in outs {
                guard let dp = o.mData else { continue }
                let dOut = dp.assumingMemoryBound(to: Float.self)
                let outCh = max(Int(o.mNumberChannels), 1)
                let outFrames = Int(o.mDataByteSize) / MemoryLayout<Float>.size / outCh
                let n = min(frames, outFrames)
                for f in 0..<n {
                    for c in 0..<outCh {
                        dOut[f * outCh + c] = sIn[f * inCh + min(c, inCh - 1)] * gain
                    }
                }
                if n < outFrames { memset(dOut + n * outCh, 0, (outFrames - n) * outCh * MemoryLayout<Float>.size) }
            }
        }
        guard status == noErr, let procID else { cleanup(); throw AudioError(message: "IO failed (\(status))") }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { cleanup(); throw AudioError(message: "start failed (\(status))") }
    }

    func stop() { cleanup() }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        cleanup()
        // gainBox is intentionally leaked if the IO block might still run; it is tiny.
    }
}
