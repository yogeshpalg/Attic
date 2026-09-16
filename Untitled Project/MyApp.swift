import SwiftUI

@main struct AtticApp: App {
    var body: some Scene {
        Window("Attic", id: "attic") {
            AtticWindow()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
    }
}
