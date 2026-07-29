import Foundation

/// Remembers each app's last volume/mute (keyed by bundle ID, since a pid is
/// different every relaunch) so levels survive quitting and reopening SoundMac.
final class SettingsStore {
    private static let volumesKey = "com.soundmac.app.volumes"
    private static let mutesKey = "com.soundmac.app.mutes"

    private let defaults = UserDefaults.standard

    func volume(for key: String) -> Double? {
        let volumes = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double]
        return volumes?[key]
    }

    func isMuted(for key: String) -> Bool {
        let mutes = defaults.dictionary(forKey: Self.mutesKey) as? [String: Bool]
        return mutes?[key] ?? false
    }

    func setVolume(_ volume: Double, for key: String) {
        var volumes = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        volumes[key] = volume
        defaults.set(volumes, forKey: Self.volumesKey)
    }

    func setMuted(_ muted: Bool, for key: String) {
        var mutes = defaults.dictionary(forKey: Self.mutesKey) as? [String: Bool] ?? [:]
        mutes[key] = muted
        defaults.set(mutes, forKey: Self.mutesKey)
    }
}
