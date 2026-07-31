import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.soundmac.app", category: "AudioEngine")

/// Owns a *fixed-size pool* of Core Audio "process taps", combined once into a
/// private aggregate device alongside the real default output device, and
/// mixes the tapped streams back together in a realtime IOProc — applying
/// each app's independent volume/mute before the sound reaches the speakers.
///
/// The aggregate device's tap *count* never changes after startup: every slot
/// is created up front pointed at our own (silent) process, and apps are
/// assigned to a free slot by re-pointing that slot's existing tap at the real
/// target process (via `kAudioTapPropertyDescription`), never by creating a
/// new tap object or resizing the aggregate's tap list at runtime.
final class AudioEngine {
    private struct Slot {
        let tapObjectID: AudioObjectID
        let tapUID: String
        let description: CATapDescription
        var assignedPID: pid_t?
    }

    private static let slotCount = 12

    private let queue = DispatchQueue(label: "com.soundmac.audioengine")
    private let gainLock = NSLock()

    // Guarded by gainLock; read from the realtime IOProc. Index-aligned with `slots`.
    private var slotOrder: [pid_t?] = []
    private var gains: [pid_t: Float] = [:]
    // Set once per slot assignment (not on every volume/mute change), so a new
    // app's tap fades in smoothly instead of appearing at full computed gain
    // the instant it's mixed in.
    private var rampStartAt: [pid_t: Date] = [:]
    private static let rampDuration: TimeInterval = 0.12

    // Only touched on `queue`.
    private var slots: [Slot] = []
    private var selfProcessObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var currentOutputUID: String?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        queue.async { [weak self] in
            self?.setupPoolAndAggregate()
            self?.watchDefaultOutputDevice()
        }
    }

    deinit {
        removeDefaultOutputDeviceListener()
        queue.sync {
            tearDownAggregateDevice()
            for slot in slots {
                AudioHardwareDestroyProcessTap(slot.tapObjectID)
            }
        }
    }

    func sync(processes: [AudioProcessInfo]) {
        queue.async { [weak self] in
            self?.syncOnQueue(processes: processes)
        }
    }

    func setVolume(_ volume: Float, for pid: pid_t) {
        gainLock.lock()
        gains[pid] = volume
        gainLock.unlock()
    }

    func setMuted(_ muted: Bool, for pid: pid_t) {
        gainLock.lock()
        if muted {
            gains[pid] = 0
        }
        gainLock.unlock()
    }

    // MARK: - Slot assignment (queue-confined)

    private func syncOnQueue(processes: [AudioProcessInfo]) {
        guard !slots.isEmpty else { return }

        let currentPIDs = Set(processes.map { $0.id })
        let assignedPIDs = Set(slots.compactMap { $0.assignedPID })

        let toRelease = assignedPIDs.subtracting(currentPIDs)
        let toAssign = processes.filter { !assignedPIDs.contains($0.id) }

        for pid in toRelease {
            releaseSlot(for: pid)
        }

        for process in toAssign {
            assignSlot(to: process)
        }

        publishSlotOrder()
    }

    private func assignSlot(to process: AudioProcessInfo) {
        guard let index = slots.firstIndex(where: { $0.assignedPID == nil }) else {
            log.error("no free tap slot for \(process.displayName, privacy: .public); increase slotCount")
            return
        }

        let slot = slots[index]
        slot.description.processes = [process.processObjectID]
        slot.description.muteBehavior = .unmuted // unmuted first — see finalizeMute below

        let status = setDescription(slot.description, on: slot.tapObjectID)
        guard status == noErr else {
            log.error("failed to assign slot to \(process.displayName, privacy: .public) (status \(status, privacy: .public))")
            return
        }

        slots[index].assignedPID = process.id

        gainLock.lock()
        rampStartAt[process.id] = Date()
        gainLock.unlock()

        log.info("assigned slot \(index, privacy: .public) to \(process.displayName, privacy: .public)")

        // Give the slot a moment to actually start flowing through the mixer
        // before muting the app's original output, so there's a brief overlap
        // instead of a gap of silence. Kept short on purpose: the original
        // plays at its natural (not gain-adjusted) volume during this window,
        // so a long overlap is audible as "loud, then drops to my saved
        // volume" — a handful of IO cycles is enough for the tap to be live.
        queue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.finalizeMute(atSlot: index, expectedPID: process.id)
        }
    }

    private func finalizeMute(atSlot index: Int, expectedPID: pid_t) {
        guard index < slots.count, slots[index].assignedPID == expectedPID else { return }
        slots[index].description.muteBehavior = .muted
        let status = setDescription(slots[index].description, on: slots[index].tapObjectID)
        if status != noErr {
            log.error("failed to finalize mute for slot \(index, privacy: .public) (status \(status, privacy: .public))")
        }
    }

    private func releaseSlot(for pid: pid_t) {
        guard let index = slots.firstIndex(where: { $0.assignedPID == pid }) else { return }

        slots[index].description.processes = [selfProcessObjectID]
        slots[index].description.muteBehavior = .unmuted
        _ = setDescription(slots[index].description, on: slots[index].tapObjectID)
        slots[index].assignedPID = nil

        gainLock.lock()
        gains.removeValue(forKey: pid)
        rampStartAt.removeValue(forKey: pid)
        gainLock.unlock()

        log.info("released slot \(index, privacy: .public) (was pid \(pid, privacy: .public))")
    }

    private func publishSlotOrder() {
        let order = slots.map { $0.assignedPID }
        gainLock.lock()
        slotOrder = order
        for case let pid? in order where gains[pid] == nil {
            gains[pid] = 1.0
        }
        gainLock.unlock()
    }

    // MARK: - One-time setup

    private func setupPoolAndAggregate() {
        guard let ownID = translateSelfToProcessObjectID() else {
            log.error("could not resolve own process object ID")
            return
        }
        selfProcessObjectID = ownID

        var createdSlots: [Slot] = []
        for _ in 0..<Self.slotCount {
            guard let slot = createSlotTap() else { continue }
            createdSlots.append(slot)
        }
        guard !createdSlots.isEmpty else {
            log.error("failed to create any tap slots")
            return
        }
        slots = createdSlots
        log.info("created \(createdSlots.count, privacy: .public) tap slot(s)")

        createAggregateDevice()
    }

    /// (Re)creates the aggregate device + IOProc against whatever the current
    /// default output device is, reusing the existing slot taps as-is. Safe to
    /// call again later (e.g. when the user switches audio output devices).
    private func createAggregateDevice() {
        guard let outputUID = defaultOutputDeviceUID() else {
            log.error("could not resolve default output device UID")
            return
        }
        currentOutputUID = outputUID

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "SoundMac Aggregate",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: slots.map { [kAudioSubTapUIDKey: $0.tapUID] },
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var newAggregateID: AudioObjectID = 0
        let createStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard createStatus == noErr else {
            log.error("failed to create aggregate device (status \(createStatus, privacy: .public))")
            return
        }
        aggregateDeviceID = newAggregateID
        log.info("created aggregate device id=\(newAggregateID, privacy: .public) with \(self.slots.count, privacy: .public) fixed slot(s), outputUID=\(outputUID, privacy: .public)")

        let gainLock = self.gainLock
        var loggedFirstCallback = false
        let mixBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            if !loggedFirstCallback {
                loggedFirstCallback = true
                log.info("IOProc firing: inputBuffers=\(inInputData.pointee.mNumberBuffers, privacy: .public) outputBuffers=\(outOutputData.pointee.mNumberBuffers, privacy: .public)")
            }
            self.mix(inInputData: inInputData, outOutputData: outOutputData, gainLock: gainLock)
        }

        var newIOProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil, mixBlock)
        guard ioStatus == noErr, let newIOProcID else {
            log.error("failed to create IO proc (status \(ioStatus, privacy: .public))")
            return
        }
        ioProcID = newIOProcID
        let startStatus = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        log.info("AudioDeviceStart status=\(startStatus, privacy: .public)")
    }

    private func tearDownAggregateDevice() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    // MARK: - Output device switching

    /// The aggregate device renders to a *fixed* physical sub-device chosen at
    /// creation time — it doesn't automatically follow the system default output
    /// (e.g. switching from headphones to speakers and back). Without this,
    /// audio keeps going out the old device until SoundMac quits. Rebuilds the
    /// aggregate device (only that — slot taps are untouched) whenever the
    /// system default output actually changes.
    private func watchDefaultOutputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }
        defaultOutputListenerBlock = block
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status != noErr {
            log.error("failed to register default output device listener (status \(status, privacy: .public))")
        }
    }

    private func removeDefaultOutputDeviceListener() {
        guard let block = defaultOutputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        defaultOutputListenerBlock = nil
    }

    private func handleDefaultOutputDeviceChanged() {
        guard let newOutputUID = defaultOutputDeviceUID(), newOutputUID != currentOutputUID else { return }
        log.info("default output device changed to \(newOutputUID, privacy: .public); rebuilding aggregate device")
        tearDownAggregateDevice()
        createAggregateDevice()
    }

    private func createSlotTap() -> Slot? {
        let description = CATapDescription()
        description.name = "SoundMac Slot"
        description.processes = [selfProcessObjectID]
        description.isMixdown = true
        description.isMono = false
        description.isExclusive = false
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapObjectID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapObjectID)
        guard status == noErr else {
            log.error("failed to create slot tap (status \(status, privacy: .public))")
            return nil
        }
        guard let uid = tapUIDString(for: tapObjectID) else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            return nil
        }
        return Slot(tapObjectID: tapObjectID, tapUID: uid, description: description, assignedPID: nil)
    }

    /// Sums each slot's (already stereo-mixed-down) samples into the shared output,
    /// scaled by that app's current gain, then writes the result to the real device.
    /// Unassigned slots point at our own silent process, so they contribute silence
    /// even without an explicit gain check.
    private func mix(inInputData: UnsafePointer<AudioBufferList>, outOutputData: UnsafeMutablePointer<AudioBufferList>, gainLock: NSLock) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)

        gainLock.lock()
        let order = slotOrder
        let gainByPID = gains
        let rampStartByPID = rampStartAt
        gainLock.unlock()

        let now = Date()
        let slotCount = order.count
        guard slotCount > 0, inputBuffers.count > 0, outputBuffers.count > 0, inputBuffers.count % slotCount == 0 else { return }

        let channelsPerSlot = inputBuffers.count / slotCount

        for slotIndex in 0..<slotCount {
            guard let pid = order[slotIndex] else { continue }
            var gain = gainByPID[pid] ?? 1.0
            guard gain > 0 else { continue }

            if let rampStart = rampStartByPID[pid] {
                let elapsed = now.timeIntervalSince(rampStart)
                let rampFactor = min(1.0, max(0.0, elapsed / Self.rampDuration))
                gain *= Float(rampFactor)
                guard gain > 0 else { continue }
            }

            for channel in 0..<channelsPerSlot {
                let inputIndex = slotIndex * channelsPerSlot + channel
                let outputIndex = channel % outputBuffers.count
                guard let src = inputBuffers[inputIndex].mData?.assumingMemoryBound(to: Float.self),
                      let dst = outputBuffers[outputIndex].mData?.assumingMemoryBound(to: Float.self) else { continue }

                let frameCount = min(
                    Int(inputBuffers[inputIndex].mDataByteSize),
                    Int(outputBuffers[outputIndex].mDataByteSize)
                ) / MemoryLayout<Float>.size

                for frame in 0..<frameCount {
                    dst[frame] += src[frame] * gain
                }
            }
        }
    }

    // MARK: - Core Audio property helpers

    private func setDescription(_ description: CATapDescription, on tapObjectID: AudioObjectID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size)
        var unmanaged = Unmanaged.passUnretained(description)
        return withUnsafeMutablePointer(to: &unmanaged) { ptr -> OSStatus in
            AudioObjectSetPropertyData(tapObjectID, &address, 0, nil, size, ptr)
        }
    }

    private func tapUIDString(for tapObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func translateSelfToProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var objectID: AudioObjectID = 0
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { qualifierPtr -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), qualifierPtr, &dataSize, &objectID)
        }
        guard status == noErr, objectID != 0 else { return nil }
        return objectID
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard deviceStatus == noErr, deviceID != 0 else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
