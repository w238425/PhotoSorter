import SwiftUI
import Photos

/// 分类页 v3：写真 / 部位 / 精细标签 三维度
struct ClassifyView: View {
    @EnvironmentObject var svc: PhotoLibraryService

    enum Dimension: String, CaseIterable {
        case portrait = "写真"
        case parts = "部位"
        case tags = "标签"
    }

    @State private var dimension: Dimension = .portrait
    @State private var portraitFilter = 0    // 0=全部 1=写真 2=非写真
    @State private var partFilter: BodyPart? = .face
    @State private var tagFilter: String? = nil

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("维度", selection: $dimension) {
                    ForEach(Dimension.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                filterBar
                    .padding(.vertical, 8)

                if filteredIDs.isEmpty {
                    Spacer()
                    Text("该条件下没有照片").foregroundColor(.secondary)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(filteredIDs, id: \.self) { pid in
                                if let asset = svc.assets[pid] {
                                    cell(pid: pid, asset: asset)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("分类")
        }
    }

    // MARK: 筛选条

    @ViewBuilder
    private var filterBar: some View {
        switch dimension {
        case .portrait:
            Picker("", selection: $portraitFilter) {
                Text("全部").tag(0)
                Text("写真").tag(1)
                Text("非写真").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        case .parts:
            Picker("", selection: $partFilter) {
                Text("全部").tag(BodyPart?.none)
                ForEach(BodyPart.allCases) { p in Text(p.rawValue).tag(BodyPart?.some(p)) }
            }
            .pickerStyle(.menu)
        case .tags:
            tagChips
        }
    }

    /// 标签 chip 流（按照片数量降序）
    private var tagChips: some View {
        let counts = tagCounts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(counts, id: \.0) { tag, count in
                    Button {
                        tagFilter = tagFilter == tag ? nil : tag
                    } label: {
                        Text("\(tag) \(count)")
                            .font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(tagFilter == tag ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private var tagCounts: [(String, Int)] {
        var c: [String: Int] = [:]
        for p in svc.photos.values { for t in p.tags { c[t, default: 0] += 1 } }
        return c.sorted { $0.value > $1.value }
    }

    // MARK: 数据

    private var filteredIDs: [String] {
        switch dimension {
        case .portrait:
            let list = svc.photos.filter {
                portraitFilter == 0
                    || (portraitFilter == 1 && $0.value.level != .normal)
                    || (portraitFilter == 2 && $0.value.level == .normal)
            }
            return list.keys.sorted()
        case .parts:
            return svc.photos
                .filter { partFilter == nil || $0.value.parts.contains(partFilter!) }
                .keys.sorted()
        case .tags:
            guard let tf = tagFilter else {
                return svc.photos.filter { !$0.value.tags.isEmpty }.keys.sorted()
            }
            return svc.photos
                .filter { $0.value.tags.contains(tf) }
                .sorted { $0.value.scores.aesthetic > $1.value.scores.aesthetic }
                .map { $0.key }
        }
    }

    // MARK: 单元格

    @ViewBuilder
    private func cell(pid: String, asset: PHAsset) -> some View {
        VStack(spacing: 2) {
            ThumbView(asset: asset, side: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let p = svc.photos[pid] {
                HStack(spacing: 4) {
                    if dimension == .parts {
                        ForEach(p.parts, id: \.self) { part in
                            Text(part.rawValue).font(.caption2).foregroundColor(.secondary)
                        }
                    } else if dimension == .tags {
                        Text(p.tags.isEmpty ? "无标签" : p.tags.prefix(2).joined(separator: "·"))
                            .font(.caption2).foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        LevelBadge(level: p.level)
                    }
                    if p.scores.hasFilter { Text("🎨").font(.caption2) }
                }.frame(height: 18)
            }
        }
        .contextMenu {
            if dimension == .portrait {
                Button("手动设为写真") { svc.setLevel(pid, level: .portrait) }
                Button("手动设为非写真") { svc.setLevel(pid, level: .normal) }
            }
            if let p = svc.photos[pid] {
                Text(String(format: "颜值 %.2f · 肤色 %.0f%% · 清晰度 %.2f",
                            p.scores.aesthetic, p.scores.skinRatio * 100, p.scores.sharpness))
            }
        }
    }
}
