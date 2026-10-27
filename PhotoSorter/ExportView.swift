import SwiftUI
import Photos

/// 输出页：单一排序序列预览 / 一键导出共享相册 / 重复照片检测删除
/// 设计：无分类文件夹，标签只作排序键，一张照片只出现一次（策划案第七节）
struct ExportView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var message: String?
    @State private var duplicates: [[String]] = []
    @State private var keepChoice: [Int: String] = [:]
    @State private var shareItems: [Any]? = nil
    @State private var mode: PhotoLibraryService.SequenceMode = .standard

    var body: some View {
        NavigationView {
            List {
                sequenceSection
                exportSection
                duplicatesSection
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

    // MARK: 最终排序序列

    private var sequence: [(tag: String, id: String)] {
        svc.buildFinalSequence(mode: mode)
    }

    private var setCount: Int {
        svc.sets.filter { $0.photoIDs.count >= 2 }.count
    }
    private var scatterCount: Int {
        let members = Set(svc.sets.flatMap { $0.photoIDs })
        return svc.photos.keys.filter { !members.contains($0) }.count
    }

    private var sequenceSection: some View {
        Section {
            Picker("排序方式", selection: $mode) {
                ForEach(PhotoLibraryService.SequenceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("最终序列：共 \(sequence.count) 张（\(setCount) 个套 + \(scatterCount) 张散图），无重复")
                    .font(.subheadline)
                Text("套图在前（套间按分级、套内按颜值）；散图殿后，按 \(mode == .aesthetic ? "颜值" : mode == .similar ? "风格堆" : "裸露段落→风格堆→颜值") 排列。每张照片只有一个位置。")
                    .font(.footnote).foregroundColor(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sequence.prefix(60).indices, id: \.self) { i in
                        let e = sequence[i]
                        VStack(spacing: 2) {
                            if let asset = svc.assets[e.id] {
                                ThumbView(asset: asset, side: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text("\(i + 1)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .accessibilityLabel("\(i + 1)：\(e.tag)")
                    }
                }
                .padding(.vertical, 2)
            }
            if sequence.count > 60 {
                Text("…预览前 60 张，导出时包含全部 \(sequence.count) 张").font(.caption).foregroundColor(.secondary)
            }

            Button("把整条序列存为本地引用相册") {
                message = "正在创建…"
                svc.createAlbum(named: "分类-整理序列", photoIDs: sequence.map { $0.id }) { err in
                    message = err.map { "❌ \($0)" } ?? "✅ 已创建「分类-整理序列」（\(sequence.count) 张，按序）"
                }
            }
        } header: { Text("① 最终排序序列") }
    }

    // MARK: 一键导出

    private var exportSection: some View {
        Section {
            Button("⬆️ 一键导出整条序列（\(sequence.count) 张）") {
                share(items: sequence.map { $0.id })
            }
            Menu("只导出散图区块…") {
                Button("散图按当前排序导出") { exportScatter() }
            }
            Menu("只导出某个套…") {
                ForEach(svc.sets.filter { $0.photoIDs.count >= 2 }) { set in
                    Button("\(set.name)（\(set.photoIDs.count)张，\(set.level.shortLabel)）") {
                        share(items: orderedSetPhotos(set))
                    }
                }
            }
            Text("说明：App 拉起系统分享面板并按序选好照片，你在面板里选目标 iCloud 共享相册确认即可（约两下点击）。同一张照片单次导出只出现一次。")
                .font(.footnote).foregroundColor(.secondary)
        } header: { Text("② 导出到 iCloud 共享相册") }
    }

    private func orderedSetPhotos(_ set: PhotoSet) -> [String] {
        var ordered = set.photoIDs.sorted { (svc.photos[$0]?.scores.aesthetic ?? 0) > (svc.photos[$1]?.scores.aesthetic ?? 0) }
        if let cover = set.coverID, let ci = ordered.firstIndex(of: cover) {
            ordered.remove(at: ci)
            ordered.insert(cover, at: 0)
        }
        return ordered
    }

    private func exportScatter() {
        let members = Set(svc.sets.flatMap { $0.photoIDs })
        let ids = sequence.map { $0.id }.filter { !members.contains($0) }
        share(items: ids)
    }

    private func share(items ids: [String]) {
        let assets = ids.compactMap { svc.assets[$0] }
        guard !assets.isEmpty else {
            message = "没有可导出的照片"; return
        }
        message = "共 \(assets.count) 张已按序选中，请在分享面板选择目标共享相册"
        shareItems = assets
    }

    // MARK: 查重删除

    private var duplicatesSection: some View {
        Section {
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
        } header: { Text("③ 重复照片（同套姿势变化不算重复；删除需系统确认）") }
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
}
