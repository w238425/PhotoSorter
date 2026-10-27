import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("扫描", systemImage: "viewfinder") }
            SetsView()
                .tabItem { Label("套图", systemImage: "square.stack.3d.up") }
            ClassifyView()
                .tabItem { Label("分类", systemImage: "folder.badge.gearshape") }
            VideoView()
                .tabItem { Label("视频", systemImage: "video") }
            ExportView()
                .tabItem { Label("输出", systemImage: "tray.and.arrow.down") }
        }
    }
}
