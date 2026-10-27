import SwiftUI
import Photos
import UIKit

// MARK: - 共用网格

struct PhotoSheetItem: Identifiable { let id: String }

struct PhotoGrid: View {
    let ids: [String]
    @EnvironmentObject var svc: PhotoLibraryService
    var onTap: (String) -> Void = { _ in }

    private let cols = [GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)]

    var body: some View {
        LazyVGrid(columns: cols, spacing: 3) {
            ForEach(ids, id: \.self) { id in
                if let asset = svc.assets[id] {
                    Button { onTap(id) } label: {
                        ThumbView(asset: asset, side: 128)
                            .overlay(alignment: .topTrailing) {
                                if let p = svc.photos[id], p.isPortrait {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Circle().fill(Color.black.opacity(0.45)))
                                        .padding(3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 3)
    }
}

/// 组列表里的大卡片（相册形态）
struct GroupCard: View {
    let title: String
    let ids: [String]
    let subtitle: String
    @EnvironmentObject var svc: PhotoLibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                if let first = ids.first, let asset = svc.assets[first] {
                    ThumbView(asset: asset, side: 172, fillHeight: 118)
                } else {
                    Rectangle().fill(Color(white: 0.9)).frame(height: 118)
                }
                Text("\(ids.count)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(6)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

/// 点开某个组后的照片页（带部位 chips 子分组）
struct GroupDetail: View {
    let title: String
    let ids: [String]
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var partFilter: String? = nil
    @State private var detailItem: PhotoSheetItem? = nil

    private var parts: [(String, Int)] {
        var c: [String: Int] = [:]
        for id in ids { let p = svc.photos[id]?.part.rawValue ?? "未判定"; c[p, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private var shown: [String] {
        guard let f = partFilter else { return ids }
        return ids.filter { (svc.photos[$0]?.part.rawValue ?? "未判定") == f }
    }

    var body: some View {
        ScrollView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("全部", n: ids.count, on: partFilter == nil) { partFilter = nil }
                    ForEach(parts, id: \.0) { p, n in
                        chip(p, n: n, on: partFilter == p) { partFilter = p }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            PhotoGrid(ids: shown) { detailItem = PhotoSheetItem(id: $0) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $detailItem) { it in
            PhotoDetailView(ids: shown, startID: it.id)
        }
    }

    private func chip(_ t: String, n: Int, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 4) {
                Text(t)
                Text("\(n)").foregroundColor(on ? .white.opacity(0.8) : .secondary)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.blue : Color(.systemGray6)))
            .foregroundColor(on ? .white : .primary)
        }
    }
}

// MARK: - 写真页（第一层，锁定）

struct PortraitView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var picker = false

    private var groups: [(title: String, ids: [String])] { svc.portraitGroups() }

    var body: some View {
        NavigationView {
            ScrollView {
                if !svc.hasData {
                    emptyState
                } else if groups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.rectangle")
                            .font(.system(size: 40)).foregroundColor(.secondary)
                        Text("没有判定为写真的照片").foregroundColor(.secondary)
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(groups, id: \.title) { g in
                            NavigationLink {
                                GroupDetail(title: g.title, ids: g.ids)
                            } label: {
                                GroupCard(title: g.title, ids: g.ids,
                                          subtitle: g.title.hasPrefix("写真套图") ? "成套 · 封面最佳" : "不成套的散写真")
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8)
                }
            }
            .navigationTitle("写真")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { picker = true } label: { Image(systemName: "plus.rectangle.on.folder") }
                }
            }
            .sheet(isPresented: $picker) { AlbumPickerView() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44)).foregroundColor(.blue)
            Text("还没有分析任何照片").font(.headline)
            Text("选择本地图库或 iCloud 共享相册开始，可以一次只选一个相册，分批处理。")
                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("选择相册") { picker = true }.buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

// MARK: - 标签页（第二层，互斥）

struct TagsView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var picker = false

    private var groups: [(title: String, ids: [String])] { svc.tagGroups() }

    var body: some View {
        NavigationView {
            List {
                if groups.isEmpty {
                    Section { Text("暂无分组，先去「全部」页选择相册分析").foregroundColor(.secondary) }
                }
                ForEach(groups, id: \.title) { g in
                    NavigationLink {
                        GroupDetail(title: g.title, ids: g.ids)
                    } label: {
                        HStack(spacing: 12) {
                            if let first = g.ids.first, let a = svc.assets[first] {
                                ThumbView(asset: a, side: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title).font(.body)
                                Text("暴露阶梯第 \(ClothingLadder.index(g.title) + 1) 档")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(g.ids.count)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(Color(.systemGray6)))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { picker = true } label: { Image(systemName: "plus.rectangle.on.folder") }
                }
            }
            .sheet(isPresented: $picker) { AlbumPickerView() }
        }
    }
}

// MARK: - 部位页

struct PartsView: View {
    @EnvironmentObject var svc: PhotoLibraryService

    private var groups: [(title: String, ids: [String])] { svc.partGroups() }

    var body: some View {
        NavigationView {
            List {
                if groups.isEmpty {
                    Section { Text("暂无数据").foregroundColor(.secondary) }
                }
                ForEach(groups, id: \.title) { g in
                    NavigationLink {
                        GroupDetail(title: g.title, ids: g.ids)
                    } label: {
                        HStack(spacing: 12) {
                            if let first = g.ids.first, let a = svc.assets[first] {
                                ThumbView(asset: a, side: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.title)
                                Text("浏览入口 · 不参与序列排序")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(g.ids.count)").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("部位")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - 全部（跨相册混排）

struct AllPhotosView: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @State private var picker = false
    @State private var onlyDup = false
    @State private var detailItem: PhotoSheetItem? = nil
    @State private var dupGroups: [[String]] = []

    private var ids: [String] {
        let all = svc.photos.keys.filter { svc.assets[$0] != nil }
        if onlyDup {
            let flat = Set(dupGroups.flatMap { $0 })
            return all.filter { flat.contains($0) }
        }
        return all.sorted { (svc.photos[$0]?.scores.aesthetic ?? 0) > (svc.photos[$1]?.scores.aesthetic ?? 0) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("全部", on: !onlyDup) { onlyDup = false }
                        chip("重复 \(dupGroups.count)", on: onlyDup) {
                            dupGroups = svc.findDuplicateGroups()
                            onlyDup = true
                        }
                        chip("按相册分组", on: false) {}
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                ScrollView {
                    PhotoGrid(ids: ids) { detailItem = PhotoSheetItem(id: $0) }
                    Color.clear.frame(height: 20)
                }
            }
            .navigationTitle("全部")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { picker = true } label: { Image(systemName: "plus.rectangle.on.folder") }
                }
            }
            .sheet(isPresented: $picker) { AlbumPickerView() }
            .sheet(item: $detailItem) { it in
                PhotoDetailView(ids: ids, startID: it.id)
            }
            .onAppear { if dupGroups.isEmpty { dupGroups = svc.findDuplicateGroups() } }
        }
    }

    private func chip(_ t: String, on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(on ? Color.blue : Color(.systemGray6)))
                .foregroundColor(on ? .white : .primary)
        }
    }
}
