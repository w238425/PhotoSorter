import SwiftUI
import Photos

/// 分类页：按 分级 / 部位 / 好看 / 肤色 四个维度浏览，长按手动改分级
struct ClassifyView: View {
    @EnvironmentObject var svc: PhotoLibraryService

    enum Dimension: String, CaseIterable {
        case level = "分级"
        case parts = "部位"
        case good = "好看"
        case skin = "肤色"
    }

    @State private var dimension: Dimension = .level
    @State private var levelFilter: ExposureLevel? = .portrait
    @State private var partFilter: BodyPart? = .face
    @State private var goodFilter = "高"
    @State private var skinFilter = "高"

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
        case .level:
            Picker("", selection: $levelFilter) {
                Text("全部").tag(ExposureLevel?.none)
                ForEach(ExposureLevel.allCases) { lv in Text(lv.label).tag(ExposureLevel?.some(lv)) }
            }
            .pickerStyle(.menu)
        case .parts:
            Picker("", selection: $partFilter) {
                Text("全部").tag(BodyPart?.none)
                ForEach(BodyPart.allCases) { p in Text(p.rawValue).tag(BodyPart?.some(p)) }
            }
            .pickerStyle(.menu)
        case .good:
            Picker("", selection: $goodFilter) {
                ForEach(["高", "中", "低"], id: \.self) { Text("好看-\($0)").tag($0) }
            }
            .pickerStyle(.menu)
        case .skin:
            Picker("", selection: $skinFilter) {
                ForEach(["极低", "低", "中", "高"], id: \.self) { Text("肤色-\($0)").tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: 数据

    private var filteredIDs: [String] {
        switch dimension {
        case .level:
            return svc.photos.filter { levelFilter == nil || $0.value.level == levelFilter }.keys.sorted()
        case .parts:
            return svc.photos
                .filter { partFilter == nil || $0.value.parts.contains(partFilter!) }
                .keys.sorted()
        case .good:
            return svc.photos
                .filter { svc.goodTier($0.value.scores) == goodFilter }
                .sorted { $0.value.scores.aesthetic > $1.value.scores.aesthetic }
                .map { $0.key }
        case .skin:
            return svc.photos
                .filter { svc.skinTier($0.value.scores.skinRatio) == skinFilter }
                .sorted { $0.value.scores.skinRatio > $1.value.scores.skinRatio }
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
                    LevelBadge(level: p.level)
                    if p.scores.hasFilter { Text("🎨").font(.caption2) }
                }.frame(height: 18)
            }
        }
        .contextMenu {
            Menu("手动设定分级…") {
                ForEach(ExposureLevel.allCases) { lv in
                    Button(lv.label) { svc.setLevel(pid, level: lv) }
                }
            }
            if let p = svc.photos[pid] {
                Text(String(format: "颜值 %.2f · 肤色 %.0f%% · 清晰度 %.2f",
                            p.scores.aesthetic, p.scores.skinRatio * 100, p.scores.sharpness))
            }
        }
    }
}
