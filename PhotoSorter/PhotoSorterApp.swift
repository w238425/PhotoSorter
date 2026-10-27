import SwiftUI

@main
struct PhotoSorterApp: App {
    @StateObject private var service = PhotoLibraryService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
        }
    }
}
