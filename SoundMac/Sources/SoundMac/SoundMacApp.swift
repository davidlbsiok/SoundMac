import SwiftUI

@main
struct SoundMacApp: App {
    @StateObject private var viewModel = SoundboardViewModel()

    var body: some Scene {
        MenuBarExtra("SoundMac", systemImage: "slider.horizontal.3") {
            SoundboardView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
