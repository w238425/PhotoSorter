import SwiftUI

/// 扫描页：授权 → 勾选相册（含共享相册）→ 开扫 → 进度
struct ScanView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            Group {
                if !svc.authorized {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)
                        Text("需要完整照片访问权限\n用于读取相册与创建分类相册")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("授权照片访问") { svc.requestAuth() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    albumList
                }
            }
            .navigationTitle("写真分类助手")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
        }
    }

    private var albumList: some View {
        List {
            Section("选择要扫描的相册") {
                ForEach(svc.albums) { album in
                    HStack {
                        Image(systemName: album.isShared ? "icloud.and.arrow.down" : "photo.on.rectangle")
                            .foregroundColor(album.isShared ? .blue : .secondary)
                        Text(album.title)
                        Spacer()
                        Text("\(album.count)")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                        toggleFor(album)
                    }
                }
            }

            Section("选项") {
                Toggle("允许联网拉取 iCloud 照片", isOn: $svc.allowNetwork)
                if !svc.allowNetwork {
                    Text("将只分析已缓存的照片，零流量零新增占用")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }

            Section {
                Button {
                    svc.startScan()
                } label: {
                    if svc.scanning {
                        HStack { ProgressView(); Text("分析中…") }
                    } else {
                        Text("开始扫描分析")
                    }
                }
                .disabled(svc.scanning || svc.selectedAlbumIDs.isEmpty)

                if svc.scanning || svc.progress > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: svc.progress)
                        Text(svc.statusText).font(.footnote).foregroundColor(.secondary)
                    }
                }

                if svc.hasData {
                    Label("已有数据：\(svc.photos.count) 张照片 / \(svc.sets.count) 套",
                          systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.footnote)
                }
            } header: {
                Text("扫描")
            } footer: {
                Text("分析全程在本机完成，照片不上传。 iCloud 共享相册默认只用缩略图分析，不拉原图。")
            }
        }
    }

    private func toggleFor(_ album: AlbumInfo) -> some View {
        Toggle("", isOn: Binding(
            get: { svc.selectedAlbumIDs.contains(album.id) },
            set: { on in
                if on { svc.selectedAlbumIDs.insert(album.id) }
                else { svc.selectedAlbumIDs.remove(album.id) }
            }
        ))
        .labelsHidden()
    }
}
