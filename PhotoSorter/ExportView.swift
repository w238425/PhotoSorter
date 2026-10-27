import SwiftUI
import Photos

/// 输出页：生成引用相册 / 重复照片检测删除 / 半自动导出到共享相册
struct ExportView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var message: String?
    @State private var duplicates: [[String]] = []
    @State private var keepChoice: [Int: String] = [:]   // 重复组下标 -> 保留的照片ID
    @State private var shareItems: [Any]? = nil
    @State private var exportingSet: PhotoSet? = nil

    var body: some View {
        NavigationView {
            List {
                albumsSection
                duplicatesSection
                shareSection
                if let message {
                    Section { Text(message).font(.footnote).foregroundColor(.orange) }
                }
            }
            .navigationTitle("输出")
            .sheet(isPresented: Binding(get: { shareItems != nil },
                                        set: { if !$0 { shareItems = nil } })) {
                if let items = shareItems { ShareSheet(items: items) }
            }
        }
    }

    // MARK: 生成引用相册

    private var albumsSection: some View {
        Section("① 生成引用相册（照片本体不动，仅建相册引用）") {
            Button("按套生成（≥3 张的套，整套不散）") {
                let sets = svc.sets.filter { $0.photoIDs.count >= 3 }
                generateSequentially(titles: sets.map { "分类-\($0.name)" },
                                     photoLists: sets.map { $0.photoIDs })
            }
            Button("按分级生成（写真/暴露/非常暴露）") {
                generateSequentially(
                    titles: ["分类-写真", "分类-暴露写真", "分类-非常暴露"],
                    photoLists: [
                        ids(level: .portrait), ids(level: .revealing), ids(level: .explicit)
                    ]
                )
            }
            Button("好看-高 精选相册（跨套）") {
                let ids = svc.photos
                    .filter { svc.goodTier($0.value.scores) == "高" }
                    .sorted { $0.value.scores.aesthetic > $1.value.scores.aesthetic }
                    .map { $0.key }
                generateSequentially(titles: ["分类-好看-高"], photoLists: [ids])
            }
            Button("肤色-高 相册") {
                let ids = svc.photos
                    .filter { svc.skinTier($0.value.scores.skinRatio) == "高" }
                    .map { $0.key }
                generateSequentially(titles: ["分类-肤色-高"], photoLists: [ids])
            }
        }
    }

    private func ids(level: ExposureLevel) -> [String] {
        svc.photos.filter { $0.value.level == level }.keys.sorted()
    }

    private func generateSequentially(titles: [String], photoLists: [[String]]) {
        guard !titles.isEmpty else { return }
        message = "正在创建「\(titles[0])」…"
        let service = svc
        func step(_ i: Int) {
            guard i < titles.count else {
                message = "✅ 完成：已创建/更新 \(titles.count) 个相册"
                return
            }
            service.createAlbum(named: titles[i], photoIDs: photoLists[i]) { err in
                if let err { message = "❌ \(titles[i])：\(err)"; return }
                step(i + 1)
            }
        }
        step(0)
    }

    // MARK: 查重删除

    private var duplicatesSection: some View {
        Section("② 重复照片（仅限本人图库，删除需系统确认）") {
            Button("检测重复照片") {
                duplicates = svc.findDuplicateGroups()
                keepChoice = [:]
                message = duplicates.isEmpty ? "未发现重复照片" : "发现 \(duplicates.count) 组重复"
            }
            ForEach(duplicates.indices, id: \.self) { gi in
                let group = duplicates[gi]
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(gi + 1) 组 · \(group.count) 张 · 点选要保留的一张")
                        .font(.footnote).foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(group, id: \.self) { pid in
                                if let asset = svc.assets[pid] {
                                    ThumbView(asset: asset, side: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(keepChoice[gi] == pid ? Color.green : .clear, lineWidth: 3)
                                        )
                                        .onTapGesture { keepChoice[gi] = pid }
                                }
                            }
                        }
                    }
                    Button("删除本组其余 \(group.count - 1) 张", role: .destructive) {
                        deleteDuplicates(group: group, index: gi)
                    }
                    .font(.footnote)
                    .disabled(keepChoice[gi] == nil)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func deleteDuplicates(group: [String], index: Int) {
        guard let keep = keepChoice[index] else { return }
        let toDelete = group.filter { $0 != keep }
        message = "请在系统弹窗中确认删除…"
        svc.delete(ids: toDelete) { err in
            if let err {
                message = "❌ 删除失败：\(err)"
            } else {
                duplicates.remove(at: index)
                message = "✅ 已删除 \(toDelete.count) 张重复照片"
            }
        }
    }

    // MARK: 半自动导出共享相册

    private var shareSection: some View {
        Section("③ 半自动导出到 iCloud 共享相册") {
            Menu("选择要导出的套…") {
                ForEach(svc.sets.filter { $0.photoIDs.count >= 2 }) { set in
                    Button("\(set.name)（\(set.photoIDs.count)张）") {
                        exportingSet = set
                        exportSet(set)
                    }
                }
            }
            Text("说明：App 会拉起系统分享面板并选好整套照片，你只需选目标共享相册确认（约两下点击）。")
                .font(.footnote).foregroundColor(.secondary)
        }
    }

    private func exportSet(_ set: PhotoSet) {
        let assets = set.photoIDs.compactMap { svc.assets[$0] }
        guard !assets.isEmpty else { return }
        shareItems = assets
    }
}
