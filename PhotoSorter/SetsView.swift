import SwiftUI
import Photos

/// 套图页：按套浏览，长按照片可移入其他套 / 移出套
struct SetsView: View {
    @EnvironmentObject var svc: PhotoLibraryService

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        NavigationView {
            Group {
                if svc.sets.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(visibleSets) { set in
                                NavigationLink(destination: SetDetailView(setID: set.id)) {
                                    SetCardView(set: set)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("套图")
        }
    }

    private var visibleSets: [PhotoSet] {
        svc.sets.filter { !$0.photoIDs.isEmpty }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundColor(.secondary)
            Text("还没有数据，请先到「扫描」页分析").foregroundColor(.secondary)
        }
    }
}

// MARK: - 套卡片

private struct SetCardView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    let set: PhotoSet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cover = set.coverID, let asset = svc.assets[cover] {
                ThumbView(asset: asset, side: 160)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Text(set.name).font(.subheadline.bold())
                Spacer()
                LevelBadge(level: set.level)
            }
            Text("\(set.photoIDs.count) 张")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - 套详情

struct SetDetailView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    let setID: Int

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    private var set: PhotoSet? { svc.sets.first { $0.id == setID } }

    var body: some View {
        ScrollView {
            if let set {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(set.photoIDs, id: \.self) { pid in
                        if let asset = svc.assets[pid] {
                            photoCell(pid: pid, asset: asset)
                        }
                    }
                }
                .padding()
            } else {
                Text("该套不存在").foregroundColor(.secondary)
            }
        }
        .navigationTitle(set?.name ?? "套详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func photoCell(pid: String, asset: PHAsset) -> some View {
        VStack(spacing: 2) {
            ThumbView(asset: asset, side: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                if let p = svc.photos[pid] {
                    LevelBadge(level: p.level)
                    if p.scores.hasFilter { Text("🎨").font(.caption2) }
                    if p.parts.contains(.undetermined) { Text("？").font(.caption2).foregroundColor(.secondary) }
                }
            }
            .frame(height: 18)
        }
        .contextMenu {
            Menu("移入其他套…") {
                ForEach(svc.sets.filter { $0.id != setID && !$0.photoIDs.isEmpty }) { target in
                    Button(target.name) { svc.movePhoto(pid, toSet: target.id) }
                }
            }
            Button("从本套移出", role: .destructive) { svc.removePhotoFromSet(pid) }
            Menu("手动设定分级…") {
                ForEach(ExposureLevel.allCases) { lv in
                    Button(lv.label) { svc.setLevel(pid, level: lv) }
                }
            }
        }
    }
}
