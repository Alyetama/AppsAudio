import CoreAudio
import Foundation
import os

/// One audio-producing process whose speaker output we re-render at a custom gain.
struct ControlledApp {
    let process: AudioProcess
    /// Effective linear gain, 0...1. A muted app is simply gain 0.
    let gain: Float
}

/// Real-time state read by the IOProc. Guarded by a tiny unfair lock; the
/// IOProc only *tries* the lock, so the control thread never blocks audio.
final class RenderState {
    var lock = os_unfair_lock_s()
    /// Per-tap gains, in the same order as the aggregate device's tap list.
    var gains: [Float] = []
    /// The output device presents Float32 samples (the format we mix in).
    var outputIsFloat32 = true
}

private struct TapRef {
    let tapID: AudioObjectID
    let uuid: String
}

/// Routes selected apps' audio through a private aggregate device so each can be
/// volume-adjusted or muted at the speakers — while the source app keeps
/// producing audio, so recorders still capture it.
///
/// Taps are keyed by CoreAudio process **object ID**, not by app bundle: this
/// makes each of an app's audio helpers tappable independently, and a helper
/// that dies and respawns (new object ID) is transparently re-tapped.
final class TapEngine {
    private let renderState = RenderState()

    private var aggregateDevice: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    private var taps: [AudioObjectID: TapRef] = [:]
    private var order: [AudioObjectID] = []
    private var outputDevice: AudioObjectID = 0

    // MARK: Public API

    /// Reconcile the set of controlled processes. Adding/removing a tap rebuilds
    /// the aggregate tap list; changing only gains is a cheap real-time update.
    func setControlledApps(_ apps: [ControlledApp]) {
        let desiredIDs = apps.map(\.process.objectID)
        let desiredSet = Set(desiredIDs)
        let currentSet = Set(order)

        let toRemove = currentSet.subtracting(desiredSet)
        let toAdd = desiredIDs.filter { !currentSet.contains($0) }
        let byObject = Dictionary(apps.map { ($0.process.objectID, $0) }, uniquingKeysWith: { a, _ in a })

        let membershipChanged = !toRemove.isEmpty || !toAdd.isEmpty

        if membershipChanged {
            ensureAggregate()

            for objectID in toRemove {
                if let ref = taps.removeValue(forKey: objectID) {
                    AudioHardwareDestroyProcessTap(ref.tapID)
                }
            }
            for objectID in toAdd {
                guard let app = byObject[objectID], let ref = createTap(for: app.process) else { continue }
                taps[objectID] = ref
            }
            // Keep desired order, dropping any that failed to create.
            order = desiredIDs.filter { taps[$0] != nil }

            pushTapList()
            updateGains(byObject)

            if order.isEmpty {
                teardownAggregate()
            } else {
                startIfNeeded()
            }
        } else {
            updateGains(byObject)
        }
    }

    /// Rebuild everything against the current default output device (e.g. after
    /// the user switches speakers/headphones), preserving the controlled set.
    func rebuildForDefaultOutputChange() {
        guard !order.isEmpty else { return }
        let previousOrder = order
        // Recreate the aggregate around the new output device; taps survive.
        stop()
        if aggregateDevice != 0 {
            if let ioProcID { AudioDeviceDestroyIOProcID(aggregateDevice, ioProcID) }
            ioProcID = nil
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            aggregateDevice = 0
        }
        ensureAggregate()
        order = previousOrder.filter { taps[$0] != nil }
        pushTapList()
        startIfNeeded()
    }

    func shutdown() {
        stop()
        if aggregateDevice != 0, let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDevice, ioProcID)
        }
        for ref in taps.values {
            AudioHardwareDestroyProcessTap(ref.tapID)
        }
        taps.removeAll()
        order.removeAll()
        if aggregateDevice != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            aggregateDevice = 0
        }
        ioProcID = nil
    }

    // MARK: Aggregate device lifecycle

    private func ensureAggregate() {
        if aggregateDevice != 0 { return }
        outputDevice = CA.defaultOutputDevice
        guard outputDevice != 0, let outUID = CA.deviceUID(outputDevice) else { return }

        let aggUID = "com.fcatus.appsaudio." + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppsAudio",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[String]]()
        ]

        var aggID: AudioObjectID = 0
        let err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr, aggID != 0 else {
            NSLog("AppsAudio: failed to create aggregate device (\(err))")
            return
        }
        aggregateDevice = aggID
        updateOutputFormat()

        var procID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcID(
            aggID, TapEngine.renderProc, Unmanaged.passUnretained(self).toOpaque(), &procID)
        if procErr == noErr { ioProcID = procID } else {
            NSLog("AppsAudio: failed to create IOProc (\(procErr))")
        }
    }

    /// Detect whether the output stream is Float32; if not, the IOProc leaves it
    /// silent rather than reinterpreting foreign sample formats as floats.
    private func updateOutputFormat() {
        let asbd = CA.value(
            aggregateDevice, kAudioDevicePropertyStreamFormat,
            kAudioObjectPropertyScopeOutput, default: AudioStreamBasicDescription())
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
        os_unfair_lock_lock(&renderState.lock)
        renderState.outputIsFloat32 = isFloat
        os_unfair_lock_unlock(&renderState.lock)
        if !isFloat {
            NSLog("AppsAudio: output device is not Float32 — routed apps will be silent")
        }
    }

    private func teardownAggregate() {
        stop()
        if aggregateDevice != 0, let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDevice, ioProcID)
        }
        if aggregateDevice != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
        }
        aggregateDevice = 0
        ioProcID = nil
    }

    private func startIfNeeded() {
        guard aggregateDevice != 0, ioProcID != nil, !running, !order.isEmpty else { return }
        if AudioDeviceStart(aggregateDevice, ioProcID) == noErr { running = true }
    }

    private func stop() {
        guard running, aggregateDevice != 0, let ioProcID else { return }
        AudioDeviceStop(aggregateDevice, ioProcID)
        running = false
    }

    // MARK: Taps

    private func createTap(for process: AudioProcess) -> TapRef? {
        let uuid = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: [process.objectID])
        description.name = "AppsAudio-\(process.id)-\(process.objectID)"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .muted   // silence the app's own output; we re-render it

        var tapID: AudioObjectID = 0
        let err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr, tapID != 0 else {
            NSLog("AppsAudio: failed to create tap for \(process.name) (\(err))")
            return nil
        }
        return TapRef(tapID: tapID, uuid: uuid.uuidString)
    }

    /// Push the current tap ordering onto the live aggregate device.
    private func pushTapList() {
        guard aggregateDevice != 0 else { return }
        let wasRunning = running
        stop()

        var addr = CA.address(kAudioAggregateDevicePropertyTapList)
        let cfList = order.compactMap { taps[$0]?.uuid } as CFArray
        // The property value is a CFArrayRef: pass a pointer to the pointer.
        var opaque = Unmanaged.passUnretained(cfList).toOpaque()
        let size = UInt32(MemoryLayout<UnsafeRawPointer>.size)
        let err = withUnsafePointer(to: &opaque) { ptr in
            AudioObjectSetPropertyData(aggregateDevice, &addr, 0, nil, size, ptr)
        }
        if err != noErr {
            NSLog("AppsAudio: failed to set tap list (\(err))")
        }

        if wasRunning && !order.isEmpty { startIfNeeded() }
    }

    private func updateGains(_ byObject: [AudioObjectID: ControlledApp]) {
        let gains = order.map { byObject[$0]?.gain ?? 1.0 }
        os_unfair_lock_lock(&renderState.lock)
        renderState.gains = gains
        os_unfair_lock_unlock(&renderState.lock)
    }

    // MARK: Real-time render

    private static let renderProc: AudioDeviceIOProc = {
        (_, _, inInputData, _, outOutputData, _, clientData) -> OSStatus in
        guard let clientData else { return noErr }
        let engine = Unmanaged<TapEngine>.fromOpaque(clientData).takeUnretainedValue()
        let state = engine.renderState

        let out = UnsafeMutableAudioBufferListPointer(outOutputData)
        // Start from silence so untapped cycles are clean.
        for i in 0..<out.count {
            if let d = out[i].mData { memset(d, 0, Int(out[i].mDataByteSize)) }
        }

        guard os_unfair_lock_trylock(&state.lock) else { return noErr }
        let gains = state.gains
        let isFloat = state.outputIsFloat32
        os_unfair_lock_unlock(&state.lock)

        guard isFloat else { return noErr }   // non-Float32 output: leave silent
        guard let outBuf = out.first, let outData = outBuf.mData else { return noErr }
        let outCh = Int(outBuf.mNumberChannels)
        guard outCh > 0 else { return noErr }
        let outPtr = outData.assumingMemoryBound(to: Float32.self)
        let outFrames = Int(outBuf.mDataByteSize) / (MemoryLayout<Float32>.size * outCh)

        let input = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inInputData))
        let tapCount = min(input.count, gains.count)
        for t in 0..<tapCount {
            let g = gains[t]
            if g == 0 { continue }
            let inBuf = input[t]
            guard let inData = inBuf.mData else { continue }
            let inCh = Int(inBuf.mNumberChannels)
            guard inCh > 0 else { continue }
            let inPtr = inData.assumingMemoryBound(to: Float32.self)
            let inFrames = Int(inBuf.mDataByteSize) / (MemoryLayout<Float32>.size * inCh)
            let frames = min(inFrames, outFrames)
            let channels = min(inCh, outCh)
            for f in 0..<frames {
                for c in 0..<channels {
                    outPtr[f * outCh + c] += inPtr[f * inCh + c] * g
                }
            }
        }
        return noErr
    }
}
