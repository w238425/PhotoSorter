import SwiftUI

@main
struct PhotoSorterApp: App {
    @StateObject private var service = PhotoLibraryService()

    init() {
        // 原型向量是用户纠错的积累，启动就载入，第一次分类就能用上
        TagEngine.shared.warmupPrototypes()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
        }
    }
}
