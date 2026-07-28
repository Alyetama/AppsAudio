import AppKit
import CoreAudio
import Darwin
import Foundation

/// An audio-producing process discovered through the CoreAudio HAL.
struct AudioProcess: Identifiable, Hashable {
    /// The CoreAudio process object ID (stable while the process lives).
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String

    /// The owning app (resolved from a helper/renderer child), used for icon + identity.
    let ownerPID: pid_t
    let ownerBundleID: String

    /// Stable identity for SwiftUI / persistence: prefer the owning app's bundle ID.
    var id: String {
        if !ownerBundleID.isEmpty { return ownerBundleID }
        if !bundleID.isEmpty { return bundleID }
        return "pid:\(pid)"
    }

    /// App icons are cached by identity so SwiftUI redraws don't hit
    /// NSRunningApplication on every frame. Accessed on the main thread only.
    private static var iconCache: [String: NSImage] = [:]

    var icon: NSImage? {
        if let cached = Self.iconCache[id] { return cached }
        let resolved: NSImage? = {
            if ownerPID > 0, let app = NSRunningApplication(processIdentifier: ownerPID) {
                return app.icon
            }
            if !ownerBundleID.isEmpty,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: ownerBundleID).first {
                return app.icon
            }
            return nil
        }()
        if let resolved { Self.iconCache[id] = resolved }
        return resolved
    }
}

enum AudioProcessEnumerator {
    /// All processes that are currently producing output audio.
    static func runningOutputProcesses() -> [AudioProcess] {
        let ids = CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
        var processes: [AudioProcess] = []
        for objectID in ids {
            // Only keep processes actually emitting audio to an output device.
            let isOutput: UInt32 = CA.value(objectID, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard isOutput != 0 else { continue }

            let pid: pid_t = CA.value(objectID, kAudioProcessPropertyPID, default: -1)
            let bundleID = CA.string(objectID, kAudioProcessPropertyBundleID) ?? ""
            let owner = resolveOwner(pid: pid, bundleID: bundleID)

            processes.append(AudioProcess(
                objectID: objectID, pid: pid, bundleID: bundleID,
                name: owner.name, ownerPID: owner.pid, ownerBundleID: owner.bundleID))
        }
        // Keep every audio-producing process object (an app may have several
        // helpers); the model groups them by app for display, and the engine
        // taps each object so muting silences all of an app's helpers.
        return processes.sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.objectID < $1.objectID
        }
    }

    /// Map an audio-producing process (often an Electron/Chromium *helper* child)
    /// back to the real app the user recognizes — its name, pid, and bundle ID.
    private static func resolveOwner(pid: pid_t, bundleID: String)
        -> (name: String, pid: pid_t, bundleID: String) {

        // 1. Walk the parent-process chain: a helper's ancestor is the main app,
        //    which *is* registered as an NSRunningApplication.
        var current = pid
        var hops = 0
        while current > 1, hops < 12 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy != .prohibited,
               let name = app.localizedName, !name.isEmpty {
                return (name, current, app.bundleIdentifier ?? bundleID)
            }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
            hops += 1
        }

        // 2. Strip helper-ish suffixes off the bundle ID and look up that app.
        if !bundleID.isEmpty {
            let parentBundle = strippingHelperSuffix(bundleID)
            if parentBundle != bundleID,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: parentBundle).first,
               let name = app.localizedName, !name.isEmpty {
                return (name, app.processIdentifier, parentBundle)
            }
            // 3. Last resort: derive a readable name from the bundle ID itself.
            let comps = strippingHelperSuffix(bundleID).components(separatedBy: ".")
            if let last = comps.last, !last.isEmpty {
                return (last.capitalized, -1, bundleID)
            }
            return (bundleID, -1, bundleID)
        }

        return ("Unknown (pid \(pid))", -1, "")
    }

    /// Remove trailing Chromium/Electron helper components from a bundle ID.
    /// e.g. "dev.vencord.vesktop.helper" -> "dev.vencord.vesktop".
    private static func strippingHelperSuffix(_ bundleID: String) -> String {
        // Only strip clearly-helper components — avoid eating legitimate suffixes.
        let noise: Set<String> = ["gpu", "renderer"]
        var comps = bundleID.components(separatedBy: ".")
        while let last = comps.last, comps.count > 2,
              noise.contains(last.lowercased()) || last.lowercased().contains("helper") {
            comps.removeLast()
        }
        return comps.isEmpty ? bundleID : comps.joined(separator: ".")
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, 4, &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
