import SwiftUI

@main
struct MarmaladeApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        Window("Marmalade", id: "main") {
            ContentView()
                .environmentObject(app)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Photos…") { app.addPhotosPanel() }
                    .keyboardShortcut("o")
                Button("Add LUT…") { app.addLUTPanel() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Export…") { app.exportAll() }
                    .keyboardShortcut("e")
                    .disabled(app.photos.isEmpty || app.isExporting)
            }
        }
    }
}
