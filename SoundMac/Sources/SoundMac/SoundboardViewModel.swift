import Combine
import Foundation

final class SoundboardViewModel: ObservableObject {
    @Published var items: [AppVolumeItem] = []

    private let discovery = ProcessDiscovery()
    private let engine = AudioEngine()
    private let settings = SettingsStore()
    private var cancellable: AnyCancellable?

    init() {
        cancellable = discovery.$activeProcesses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] processes in
                self?.merge(processes)
                self?.engine.sync(processes: processes)
            }
        discovery.start()
    }

    deinit {
        discovery.stop()
    }

    private func merge(_ processes: [AudioProcessInfo]) {
        let existingByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = processes.map { process in
            if let existing = existingByID[process.id] {
                return existing
            }

            let key = Self.persistenceKey(for: process)
            let volume = settings.volume(for: key) ?? 1.0
            let isMuted = settings.isMuted(for: key)

            engine.setVolume(Float(volume), for: process.id)
            engine.setMuted(isMuted, for: process.id)

            return AppVolumeItem(id: process.id, persistenceKey: key, name: process.displayName, icon: process.icon, volume: volume, isMuted: isMuted)
        }
    }

    private static func persistenceKey(for process: AudioProcessInfo) -> String {
        process.bundleID ?? process.displayName
    }

    func setVolume(_ volume: Double, for id: pid_t) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].volume = volume
        engine.setVolume(Float(volume), for: id)
        settings.setVolume(volume, for: items[index].persistenceKey)
    }

    func toggleMute(for id: pid_t) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isMuted.toggle()
        engine.setMuted(items[index].isMuted, for: id)
        if !items[index].isMuted {
            engine.setVolume(Float(items[index].volume), for: id)
        }
        settings.setMuted(items[index].isMuted, for: items[index].persistenceKey)
    }
}
