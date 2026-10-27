import SwiftUI

/// 只读的、带精细分类的共享相册浏览器：写真 / 标签 / 部位 / 全部 / 视频
struct ContentView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var showPicker = false

    var body: some View {
        TabView {
            PortraitView()
                .tabItem { Label("写真", systemImage: "person.crop.rectangle") }
            TagsView()
                .tabItem { Label("标签", systemImage: "tag") }
            PartsView()
                .tabItem { Label("部位", systemImage: "figure.stand") }
            AllPhotosView()
                .tabItem { Label("全部", systemImage: "square.grid.3x3") }
            VideoView()
                .tabItem { Label("视频", systemImage: "video") }
        }
        .sheet(isPresented: $showPicker) { AlbumPickerView() }
        .onAppear {
            if svc.authorized && !svc.hasData && svc.albums.isEmpty {
                showPicker = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAlbumPicker)) { _ in
            showPicker = true
        }
    }
}

extension Notification.Name {
    static let openAlbumPicker = Notification.Name("PhotoSorter.openAlbumPicker")
}
