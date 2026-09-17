import SwiftUI

@main struct AtticApp: App {

    @Environment(\.openWindow) private var openWindow
    @AppStorage(AtticTheme.storageKey) private var themeID = AtticTheme.fallback.rawValue

    var body: some Scene {
        Window("Attic", id: "attic") {
            AtticWindow()
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        .commands {
            // Replacing rather than adding: the standard panel gives the icon
            // and a version string, and none of what decides what this app will
            // find on this particular Mac.
            CommandGroup(replacing: .appInfo) {
                Button("About Attic") { openWindow(id: "about") }
            }

            // Also in About, beside the swatches. Here because a theme is the
            // kind of thing people look for in a menu, and the About panel is
            // not where anyone thinks to check first.
            CommandGroup(after: .toolbar) {
                Menu("Theme") {
                    Picker("Theme", selection: $themeID) {
                        ForEach(AtticTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        }

        Window("About Attic", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
