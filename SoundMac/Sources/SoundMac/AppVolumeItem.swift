import AppKit

struct AppVolumeItem: Identifiable {
    let id: pid_t
    let persistenceKey: String
    let name: String
    let icon: NSImage?
    var volume: Double
    var isMuted: Bool
}
