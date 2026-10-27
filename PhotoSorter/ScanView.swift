import SwiftUI
import Photos

/// 相册选择页（sheet 呈现）：只显示「本地」与 iCloud 共享相册，
/// 第三方 App 建的相册默认隐藏。可分批勾选相册增量分析。
struct AlbumPickerView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            Group {
                if !svc.authorized {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 46))
                            .foregroundColor(.blue)
                        Text("需要照片访问权限\n用于读取本地图库与 iCloud 共享相册\n照片不会上传")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("授权照片访问") { svc.requestAuth() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    List {
                        if !localAlbums.isEmpty {
                            Section("本机") {
                                ForEach(localAlbums) { album in albumRow(album) }
                            }
                        }
                        Section {
                            if sharedAlbums.isEmpty {
                                Text("未发现 iCloud 共享相册")
                                    .foregroundColor(.secondary)
                                    .font(.footnote)
                            } else {
                                ForEach(sharedAlbums) { album in albumRow(album) }
                            }
                        } header: {
                            Text("ICLOUD 共享相册")
                        } footer: {
                            Text("共享相册为只读：可以浏览、复制、分享原图，但无法删除或移动。")
                        }

                        Section("选项") {
                            Toggle("显示其他相册（醒图/微信等第三方）", isOn: $svc.showUserAlbums)
                            Toggle("允许联网拉取 iCloud 照片", isOn: $svc.allowNetwork)
                            if !svc.allowNetwork {
                                Text("只分析已在本机的照片，零流量")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                        }

                        Section {
                            Button {
                                svc.startScan()
                                dismiss()
                            } label: {
                                if svc.scanning {
                                    HStack { ProgressView(); Text("分析中…") }
                                } else {
                                    Text(selectedCount > 0
                                         ? "分析已选 \(selectedCount) 个相册"
                                         : "请先选择相册")
                                }
                            }
                            .disabled(svc.scanning || svc.selectedAlbumIDs.isEmpty)

                            if svc.scanning || svc.progress > 0 {
                                VStack(alignment: .leading, spacing: 6) {
                                    ProgressView(value: svc.progress)
                                    Text(svc.statusText)
                                        .font(.footnote).foregroundColor(.secondary)
                                }
                            }
                            if svc.hasData {
                                Label("已有数据：\(svc.photos.count) 张照片 / \(svc.sets.count) 套",
                                      systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green).font(.footnote)
                            }
                        } header: {
                            Text("分析")
                        } footer: {
                            Text("分析按相册逐个进行，可随时中断，下次进来只分析没分析过的照片。\n"
                                 + "注意：读取 iCloud 照片会触发系统下载缓存（App 无法主动清理）。")
                        }
                    }
                }
            }
            .navigationTitle("选择相册")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
        }
    }

    private var localAlbums: [AlbumInfo] {
        svc.visibleAlbums.filter { !$0.isShared }
    }
    private var sharedAlbums: [AlbumInfo] {
        svc.visibleAlbums.filter { $0.isShared }
    }
    private var selectedCount: Int { svc.selectedAlbumIDs.count }

    private func albumRow(_ album: AlbumInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: album.isShared ? "icloud.and.arrow.down" : "photo.on.rectangle")
                .foregroundColor(album.isShared ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                Text("\(album.count) 张")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { svc.selectedAlbumIDs.contains(album.id) },
                set: { on in
                    if on { svc.selectedAlbumIDs.insert(album.id) }
                    else { svc.selectedAlbumIDs.remove(album.id) }
                }))
            .labelsHidden()
        }
    }
}
