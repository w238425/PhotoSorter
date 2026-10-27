import SwiftUI
import Photos

/// 视频页：元数据排序（大小/画质/时长）+ 按需抽帧深度分析（裸露度/稳定度）
struct VideoView: View {
    @EnvironmentObject var svc: PhotoLibraryService

    enum SortKey: String, CaseIterable {
        case size = "按大小"
        case quality = "按画质"
        case duration = "按时长"
        case skin = "按裸露度"
        case stability = "按稳定度"
    }

    @State private var sortKey: SortKey = .size
    @State private var analyzing: Set<String> = []
    @State private var deepDone = false

    var body: some View {
        NavigationView {
            Group {
                if svc.videoAssets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash").font(.largeTitle).foregroundColor(.secondary)
                        Text("所选相册中没有视频\n（扫描时会自动收集视频元数据）")
                            .multilineTextAlignment(.center).foregroundColor(.secondary)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("视频")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Picker("", selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private var sortedItems: [VideoItem] {
        let items = Array(svc.videoItems.values)
        switch sortKey {
        case .size: return items.sorted { $0.fileSize > $1.fileSize }
        case .quality: return items.sorted { $0.pixelHeight > $1.pixelHeight }
        case .duration: return items.sorted { $0.duration > $1.duration }
        case .skin:
            return items.sorted { ($0.skinRatio > $1.skinRatio) || ($1.skinRatio < 0 && $0.skinRatio >= 0) }
        case .stability: return items.sorted { $0.stability > $1.stability }
        }
    }

    private var list: some View {
        List {
            if !deepDone {
                Section {
                    Button {
                        deepAnalyzeAll()
                    } label: {
                        Label(analyzing.isEmpty ? "深度分析全部（抽帧检测裸露度/稳定度）" : "分析中… \(analyzing.count) 个未完成",
                              systemImage: "waveform.path")
                    }
                    .disabled(!analyzing.isEmpty)
                } footer: {
                    Text("深度分析需要解码视频抽帧，较耗时；元数据（大小/画质/码率）已在扫描时自动完成。")
                }
            }

            ForEach(sortedItems) { item in
                row(item)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: VideoItem) -> some View {
        HStack(spacing: 12) {
            if let asset = svc.videoAssets[item.id] {
                ThumbView(asset: asset, side: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        Text(item.durationText)
                            .font(.caption2.bold())
                            .padding(3).background(.black.opacity(0.6)).foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .padding(3)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.qualityTier).font(.subheadline.bold())
                    Text(item.sizeMB).font(.caption).foregroundColor(.secondary)
                }
                Text(String(format: "码率 %.1f Mbps · %@", item.bitrateMbps, item.durationText))
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    if item.skinRatio >= 0 {
                        Label(svc.skinTier(item.skinRatio), systemImage: "eye")
                            .font(.caption)
                            .foregroundColor(item.skinRatio > 0.45 ? .red : item.skinRatio > 0.2 ? .orange : .green)
                    } else if analyzing.contains(item.id) {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("未深度分析").font(.caption2).foregroundColor(.secondary)
                    }
                    if item.stability >= 0 {
                        Label(item.stability > 0.7 ? "稳" : "晃", systemImage: "hand.raised")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .contextMenu {
            Button("深度分析此视频") { analyzeOne(item) }
            if item.skinRatio >= 0 {
                Text(String(format: "最高肤色占比 %.0f%% · 稳定度 %.2f", item.skinRatio * 100, item.stability))
            }
        }
    }

    // MARK: 深度分析

    private func analyzeOne(_ item: VideoItem) {
        guard let asset = svc.videoAssets[item.id], !analyzing.contains(item.id) else { return }
        analyzing.insert(item.id)
        VideoService.shared.deepAnalyze(asset: asset) { skin, stability in
            if var updated = svc.videoItems[item.id] {
                updated.skinRatio = skin
                updated.stability = stability
                svc.videoItems[item.id] = updated
            }
            analyzing.remove(item.id)
        }
    }

    private func deepAnalyzeAll() {
        for item in sortedItems where item.skinRatio < 0 {
            analyzeOne(item)
        }
        deepDone = true
    }
}
