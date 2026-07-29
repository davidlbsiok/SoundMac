import SwiftUI

struct SoundboardView: View {
    @ObservedObject var viewModel: SoundboardViewModel
    @StateObject private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SoundMac")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if viewModel.items.isEmpty {
                Text("No apps playing audio")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.items) { item in
                        AppVolumeRow(
                            item: item,
                            onVolumeChange: { viewModel.setVolume($0, for: item.id) },
                            onToggleMute: { viewModel.toggleMute(for: item.id) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.set($0) }
            ))
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Button("Quit SoundMac") {
                NSApplication.shared.terminate(nil)
            }
            .padding(10)
        }
        .frame(width: 280)
    }
}

private struct AppVolumeRow: View {
    let item: AppVolumeItem
    let onVolumeChange: (Double) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                Slider(
                    value: Binding(
                        get: { item.volume },
                        set: onVolumeChange
                    ),
                    in: 0...1
                )
                .disabled(item.isMuted)
            }

            Button(action: onToggleMute) {
                Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
        }
    }
}
