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
                Button("Montage…") { app.openMontage() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(app.photos.count < 2)
                Button("Export…") { app.exportAll() }
                    .keyboardShortcut("e")
                    .disabled(app.photos.isEmpty || app.isExporting)
            }
        }
    }
}
