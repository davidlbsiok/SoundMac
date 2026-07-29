import AppKit
import Combine
import CoreAudio
import Darwin

struct AudioProcessInfo: Identifiable, Equatable {
    let id: pid_t
    let processObjectID: AudioObjectID
    let bundleID: String?
    let displayName: String
    let icon: NSImage?

    static func == (lhs: AudioProcessInfo, rhs: AudioProcessInfo) -> Bool {
        lhs.id == rhs.id && lhs.bundleID == rhs.bundleID
    }
}

/// Polls Core Audio's process object list to find which apps are currently
/// rendering audio output. Read-only for now — Phase 3 adds per-process taps.
final class ProcessDiscovery: ObservableObject {
    @Published private(set) var activeProcesses: [AudioProcessInfo] = []

    /// `kAudioProcessPropertyIsRunningOutput` toggles false/true constantly during
    /// completely normal playback (silence between tracks/phrases, a pause, etc.),
    /// not just when an app truly stops making sound. Reacting to every blip by
    /// tearing down and recreating that app's tap causes an audible click each
    /// time — so once an app has been seen playing audio, it stays tracked (and
    /// tapped) for as long as its process is actually alive, regardless of the
    /// instantaneous flag. It only drops out when the process really exits.
    private var timer: Timer?
    private var trackedPIDs: Set<pid_t> = []
    private var cachedInfo: [pid_t: AudioProcessInfo] = [:]

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs on the main run loop (Timer default), so the state below doesn't
    /// need extra synchronization.
    private func refresh() {
        for process in Self.fetchRunningAudioProcesses() {
            trackedPIDs.insert(process.id)
            cachedInfo[process.id] = process
        }

        trackedPIDs = trackedPIDs.filter { Self.isAlive($0) }
        cachedInfo = cachedInfo.filter { trackedPIDs.contains($0.key) }

        let processes = trackedPIDs
            .compactMap { cachedInfo[$0] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if activeProcesses != processes {
            activeProcesses = processes
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    private static func fetchRunningAudioProcesses() -> [AudioProcessInfo] {
        guard let objectIDs = processObjectList() else { return [] }

        var result: [AudioProcessInfo] = []
        for objectID in objectIDs {
            guard isRunningOutput(objectID), let pid = pid(for: objectID), pid != ownPID else { continue }

            let bundleID = bundleID(for: objectID)
            // Helper/renderer processes (e.g. Chrome's audio helper) aren't
            // registered as their own "running application" — walk up to the
            // nearest ancestor that is, so the UI shows the real app's name/icon.
            let runningApp = resolveRunningApplication(startingAt: pid)
            let name = runningApp?.localizedName ?? bundleID ?? "PID \(pid)"

            result.append(AudioProcessInfo(id: pid, processObjectID: objectID, bundleID: bundleID, displayName: name, icon: runningApp?.icon))
        }

        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func processObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs)
        guard status == noErr else { return nil }

        return objectIDs
    }

    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }

    private static func pid(for objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private static func resolveRunningApplication(startingAt pid: pid_t) -> NSRunningApplication? {
        var currentPID: pid_t? = pid
        for _ in 0..<6 {
            guard let candidate = currentPID else { break }
            if let app = NSRunningApplication(processIdentifier: candidate) {
                return app
            }
            currentPID = parentPID(of: candidate)
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_ppid > 1 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func bundleID(for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
