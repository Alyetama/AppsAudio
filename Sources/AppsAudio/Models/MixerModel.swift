import AppKit
import CoreAudio
import Combine
import Foundation

/// Persisted per-app preference. Absent = app plays untouched at full volume.
struct AppSetting: Codable {
    var gain: Float    // 0...1
    var muted: Bool

    /// Effective linear gain applied at the speakers.
    var effectiveGain: Float { muted ? 0 : gain }

    /// Whether this app needs to be routed through the engine at all.
    var isControlled: Bool { muted || gain < 0.999 }
}

/// All audio-producing processes belonging to one app, shown as a single row.
struct AppGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let processes: [AudioProcess]

    var representative: AudioProcess { processes[0] }
    var icon: NSImage? { representative.icon }
}

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var processes: [AudioProcess] = []
    @Published private(set) var settings: [String: AppSetting] = [:]

    private let engine = TapEngine()
    private var refreshTimer: Timer?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var saveWorkItem: DispatchWorkItem?
    private let defaultsKey = "AppsAudio.settings.v1"

    init() {
        loadSettings()
        refresh()
        startRefreshTimer()
        observeDefaultOutputDevice()
        reconcileEngine()
    }

    // MARK: Discovery

    func refresh() {
        let discovered = AudioProcessEnumerator.runningOutputProcesses()
            .filter { $0.bundleID != Bundle.main.bundleIdentifier }  // never route ourselves
        if discovered != processes {
            processes = discovered
            reconcileEngine()
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Audio processes collapsed to one row per app (helpers merged).
    var groups: [AppGroup] {
        Dictionary(grouping: processes, by: \.id)
            .map { AppGroup(id: $0.key, name: $0.value[0].name, processes: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Controls

    func setting(for group: AppGroup) -> AppSetting {
        settings[group.id] ?? AppSetting(gain: 1.0, muted: false)
    }

    func setGain(_ gain: Float, for group: AppGroup) {
        var s = setting(for: group)
        s.gain = max(0, min(1, gain))
        update(s, forID: group.id)
    }

    func setMuted(_ muted: Bool, for group: AppGroup) {
        var s = setting(for: group)
        s.muted = muted
        update(s, forID: group.id)
    }

    func toggleMuted(for group: AppGroup) {
        setMuted(!setting(for: group).muted, for: group)
    }

    func resetAll() {
        settings.removeAll()
        saveSettingsNow()
        reconcileEngine()
    }

    private func update(_ setting: AppSetting, forID id: String) {
        if setting.isControlled {
            settings[id] = setting
        } else {
            settings.removeValue(forKey: id)  // back to untouched
        }
        reconcileEngine()      // audio reacts immediately
        scheduleSave()         // disk write is debounced (slider drags churn)
    }

    /// Feed the engine the current set of apps that need routing.
    private func reconcileEngine() {
        let controlled: [ControlledApp] = processes.compactMap { process in
            guard let s = settings[process.id], s.isControlled else { return nil }
            return ControlledApp(process: process, gain: s.effectiveGain)
        }
        engine.setControlledApps(controlled)
    }

    // MARK: Default output device changes

    private func observeDefaultOutputDevice() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.engine.rebuildForDefaultOutputChange() }
        }
        defaultOutputListener = block
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main, block)
    }

    // MARK: Persistence

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AppSetting].self, from: data)
        else { return }
        settings = decoded
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveSettingsNow() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveSettingsNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: Teardown

    func shutdown() {
        saveSettingsNow()   // flush any pending debounced write
        refreshTimer?.invalidate()
        if let block = defaultOutputListener {
            var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(CA.system, &addr, DispatchQueue.main, block)
        }
        engine.shutdown()
    }
}
