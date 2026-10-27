import Photos
import UIKit

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let isShared: Bool
}

/// 照片库总服务：授权、相册选择、扫描分析、成组、分级、缓存、建相册、查重删除
final class PhotoLibraryService: ObservableObject {

    // MARK: - 状态

    @Published var authorized = false
    @Published var albums: [AlbumInfo] = []
    @Published var selectedAlbumIDs: Set<String> = []
    @Published var allowNetwork = true
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var statusText = ""
    @Published var photos: [String: AnalyzedPhoto] = [:]
    @Published var assets: [String: PHAsset] = [:]
    @Published var sets: [PhotoSet] = []
    @Published var hasData = false
    @Published var videoItems: [String: VideoItem] = [:]
    @Published var videoAssets: [String: PHAsset] = [:]
    @Published var thresholds: Thresholds = Thresholds.load() {
        didSet { thresholds.save() }
    }

    var overrides = Overrides.load()
    private var fingerprints: [String: Data] = [:]

    // MARK: - 授权与相册列表

    func requestAuth() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorized = (status == .authorized || status == .limited)
                if self.authorized {
                    self.loadAlbums()
                    self.loadCache()
                }
            }
        }
    }

    func loadAlbums() {
        var list: [AlbumInfo] = []
        func add(_ fetch: PHFetchResult<PHAssetCollection>, shared: Bool) {
            fetch.enumerateObjects { col, _, _ in
                let count = PHAsset.fetchAssets(in: col, options: nil).count
                if count > 0 {
                    list.append(AlbumInfo(id: col.localIdentifier,
                                          title: col.localizedTitle ?? "未命名",
                                          count: count, isShared: shared))
                }
            }
        }
        // 相机胶卷
        add(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil), shared: false)
        // 用户自建相册
        add(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil), shared: false)
        // iCloud 共享相册
        add(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil), shared: true)

        albums = list
        if selectedAlbumIDs.isEmpty {
            selectedAlbumIDs = Set(list.filter { !$0.isShared }.prefix(1).map { $0.id })
        }
    }

    private func collectionsForSelected() -> [PHAssetCollection] {
        albums
            .filter { selectedAlbumIDs.contains($0.id) }
            .compactMap { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0.id], options: nil).firstObject }
    }

    // MARK: - 扫描（粗筛 256px → 分级 → 成组）

    func startScan() {
        guard !scanning, !selectedAlbumIDs.isEmpty else { return }
        scanning = true
        progress = 0
        statusText = "正在获取照片列表…"
        let cols = collectionsForSelected()
        let net = allowNetwork

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 1. 拉取资产
            var assets: [PHAsset] = []
            for col in cols {
                let opts = PHFetchOptions()
                opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                PHAsset.fetchAssets(in: col, options: opts).enumerateObjects { a, _, _ in assets.append(a) }
            }
            self.ui { self.statusText = "共 \(assets.count) 张照片，开始粗筛分析…" }

            let analyzer = AestheticAnalyzer.shared
            var assetMap: [String: PHAsset] = [:]
            var analyzed: [String: AnalyzedPhoto] = [:]
            var fps: [String: Data] = [:]

            for (i, asset) in assets.enumerated() {
                let id = asset.localIdentifier
                if let img = analyzer.image(for: asset, maxPixel: 512, allowNetwork: net) {
                    let scores = analyzer.analyze(img)
                    let tags = TagEngine.shared.classify(img)
                    var level = self.classifyLevel(scores, tags: tags)
                    if let lv = self.overrides.levelOverride[id] {
                        level = ExposureLevel(rawValue: lv) ?? level
                    }
                    let parts = analyzer.detectBodyParts(img)
                    analyzed[id] = AnalyzedPhoto(id: id, scores: scores, level: level, parts: parts, tags: tags)
                    assetMap[id] = asset
                    if let fp = analyzer.featurePrint(img) { fps[id] = fp }
                }
                self.ui {
                    self.progress = Double(i + 1) / Double(max(assets.count, 1)) * 0.85
                    if (i + 1) % 20 == 0 { self.statusText = "已分析 \(i + 1)/\(assets.count)" }
                }
            }

            // 1.5 视频元数据（零成本，顺带收集）
            var vAssets: [String: PHAsset] = [:]
            var vItems: [String: VideoItem] = [:]
            for col in cols {
                let vOpts = PHFetchOptions()
                vOpts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
                PHAsset.fetchAssets(in: col, options: vOpts).enumerateObjects { a, _, _ in
                    vAssets[a.localIdentifier] = a
                    vItems[a.localIdentifier] = VideoService.shared.metadata(for: a)
                }
            }

            // 2. 成组
            self.ui { self.statusText = "正在识别套图（合并被打散的写真）…" }
            var sets = self.groupPhotos(assets: assetMap, fps: fps)
            for s in sets {
                for pid in s.photoIDs { analyzed[pid]?.setID = s.id }
            }
            // 套的等级 = 套内最高档
            for i in sets.indices {
                let maxLv = sets[i].photoIDs.compactMap { analyzed[$0]?.level.rawValue }.max() ?? 0
                sets[i].levelRaw = maxLv
            }

            // 3. 落盘与回主线程
            self.ui {
                self.assets = assetMap
                self.photos = analyzed
                self.sets = sets
                self.fingerprints = fps
                self.videoAssets = vAssets
                self.videoItems = vItems
                self.scanning = false
                self.hasData = true
                self.statusText = "完成：\(analyzed.count) 张照片，\(sets.count) 套"
                self.saveCache()
            }
        }
    }

    private func ui(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

    // MARK: - 分级规则（严格量化）

    func classifyLevel(_ s: PhotoScores, tags: [String] = []) -> ExposureLevel {
        let t = thresholds
        let boost = TagEngine.exposureBoost(tags)
        // 负标签否决：CLIP 认出风景/食物/宠物/截图等非人物内容 → 直接非写真。
        // 否决压过人脸误检（动物毛色会触发肤色规则、DNN/Vision 偶发动物误脸），
        // 但暴露类标签（boost>0）可推翻否决（如"海滩+比基尼"人像）。
        // 代价：人+宠物合影会被归入非写真，可长按手动纠错。
        let negativeTags = ["风景", "食物", "宠物", "屏幕截图"]
        let negative = tags.contains(where: { negativeTags.contains($0) })
        if negative && boost == 0 { return .normal }
        guard s.faceCount >= 1 || s.skinRatio >= t.t2SkinLow else { return .normal }
        if s.skinRatio > t.t2SkinHigh || boost >= 3 { return .explicit }
        if s.skinRatio >= t.t2SkinLow || boost >= 1 { return .revealing }
        return .portrait
    }

    /// 好看程度三档
    func goodTier(_ s: PhotoScores) -> String {
        if s.aesthetic >= thresholds.goodHigh { return "高" }
        if s.aesthetic >= thresholds.goodMid { return "中" }
        return "低"
    }

    /// 肤色四档
    func skinTier(_ r: Double) -> String {
        if r < 0.10 { return "极低" }
        if r < 0.25 { return "低" }
        if r < 0.50 { return "中" }
        return "高"
    }

    // MARK: - 成组（时间窗内相似度 + 封面合并散图，并查集）

    private func groupPhotos(assets: [String: PHAsset], fps: [String: Data]) -> [PhotoSet] {
        let t = thresholds
        let ids = assets.keys.sorted {
            (assets[$0]?.creationDate ?? .distantPast) < (assets[$1]?.creationDate ?? .distantPast)
        }
        var parent: [String: String] = [:]
        for id in ids { parent[id] = id }

        func find(_ x0: String) -> String {
            var x = x0
            while let p = parent[x], p != x {
                let gp = parent[p] ?? p   // 路径压缩
                parent[x] = gp
                x = gp
            }
            return x
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        // 信号1：时间窗（30 分钟）内相邻比较，适中阈值
        for (i, id) in ids.enumerated() {
            guard let fp1 = fps[id], let a1 = assets[id] else { continue }
            var j = i + 1
            while j < ids.count {
                let id2 = ids[j]
                guard let a2 = assets[id2] else { j += 1; continue }
                let gap = (a2.creationDate ?? .distantPast).timeIntervalSince(a1.creationDate ?? .distantPast)
                if gap > 1800 { break }
                if let fp2 = fps[id2], AestheticAnalyzer.distance(fp1, fp2) < Float(t.groupMedium) {
                    union(id, id2)
                }
                j += 1
            }
        }

        // 信号2：每张散图与所有已成套的封面比对（宽松阈值）→ 合并被用户打乱的同套照片
        var rootCover: [String: String] = [:]
        for id in ids {
            let r = find(id)
            if rootCover[r] == nil { rootCover[r] = id }
        }
        for id in ids {
            guard let fp1 = fps[id] else { continue }
            for (root, cover) in rootCover {
                if find(id) == root || find(cover) == find(id) { continue }
                if let fp2 = fps[cover], AestheticAnalyzer.distance(fp1, fp2) < Float(t.groupLoose) {
                    union(cover, id)
                }
            }
        }

        // 汇总成套
        var buckets: [String: [String]] = [:]
        for id in ids { buckets[find(id), default: []].append(id) }
        let members = buckets.values.sorted { $0.count > $1.count }
        var sets: [PhotoSet] = []
        for (idx, m) in members.enumerated() {
            sets.append(PhotoSet(id: idx + 1,
                                 name: "套#\(String(format: "%03d", idx + 1))",
                                 photoIDs: m,
                                 coverID: m.first))
        }
        return sets
    }

    // MARK: - 手动调整（永久记忆）

    func movePhoto(_ photoID: String, toSet setID: Int) {
        overrides.setMove[photoID] = setID
        overrides.setRemove[photoID] = false
        applyOverrides()
        overrides.save()
    }

    func removePhotoFromSet(_ photoID: String) {
        overrides.setRemove[photoID] = true
        overrides.setMove[photoID] = nil
        applyOverrides()
        overrides.save()
    }

    func setLevel(_ photoID: String, level: ExposureLevel) {
        overrides.levelOverride[photoID] = level.rawValue
        photos[photoID]?.level = level
        refreshSetLevels()
        overrides.save()
    }

    /// 把手动调整应用到当前成组结果
    func applyOverrides() {
        var sets = self.sets
        // 先按 override 重建成员关系
        for i in sets.indices { sets[i].photoIDs.removeAll { overrides.setRemove[$0] == true } }
        for (pid, target) in overrides.setMove {
            for i in sets.indices where sets[i].id != target {
                sets[i].photoIDs.removeAll { $0 == pid }
            }
            if let ti = sets.firstIndex(where: { $0.id == target }) {
                if !sets[ti].photoIDs.contains(pid) { sets[ti].photoIDs.append(pid) }
                photos[pid]?.setID = target
            }
        }
        // 清掉空套
        sets.removeAll { $0.photoIDs.isEmpty && overrides.setMove.values.firstIndex(of: $0.id) == nil }
        var renumber: [PhotoSet] = []
        for (i, s) in sets.enumerated() {
            var ns = s
            if s.photoIDs.isEmpty { continue }
            renumber.append(ns)
        }
        // 重算等级
        for i in renumber.indices {
            let maxLv = renumber[i].photoIDs.compactMap { photos[$0]?.level.rawValue }.max() ?? 0
            renumber[i].levelRaw = maxLv
        }
        sets = renumber
        self.sets = sets
        saveCache()
    }

    private func refreshSetLevels() {
        for i in sets.indices {
            let maxLv = sets[i].photoIDs.compactMap { photos[$0]?.level.rawValue }.max() ?? 0
            sets[i].levelRaw = maxLv
        }
    }

    /// 阈值调整后重新分级（不重新读图，秒级）
    func reclassify() {
        for (id, photo) in photos {
            var level = classifyLevel(photo.scores, tags: photo.tags)
            if let lv = overrides.levelOverride[id] {
                level = ExposureLevel(rawValue: lv) ?? level
            }
            photos[id]?.level = level
        }
        refreshSetLevels()
        objectWillChange.send()
        saveCache()
    }

    // MARK: - 最终排序序列（单一归属，无重复；策划案第七节）

    enum SequenceMode: String, CaseIterable {
        case standard = "三层排序（默认）"
        case aesthetic = "纯颜值"
        case similar = "纯相似聚堆"
    }

    func buildFinalSequence(mode: SequenceMode) -> [(tag: String, id: String)] {
        var result: [(String, String)] = []
        var used = Set<String>()

        // 套图区块：套间按套最高分级降序 → 套均颜值降序；套内封面第一 → 颜值降序
        let activeSets = sets.filter { $0.photoIDs.count >= 2 }.sorted { a, b in
            if a.levelRaw != b.levelRaw { return a.levelRaw > b.levelRaw }
            let avgA = a.photoIDs.compactMap { photos[$0]?.scores.aesthetic }.reduce(0, +) / Double(max(a.photoIDs.count, 1))
            let avgB = b.photoIDs.compactMap { photos[$0]?.scores.aesthetic }.reduce(0, +) / Double(max(b.photoIDs.count, 1))
            return avgA > avgB
        }
        for s in activeSets {
            var ordered = s.photoIDs.sorted { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }
            if let cover = s.coverID, let ci = ordered.firstIndex(of: cover) {
                ordered.remove(at: ci)
                ordered.insert(cover, at: 0)
            }
            for pid in ordered where !used.contains(pid) {
                result.append(("\(s.name)·\(s.level.shortLabel)", pid))
                used.insert(pid)
            }
        }

        // 散图区块：不在任何套里的照片
        let setMembers = Set(sets.flatMap { $0.photoIDs })
        var scatter = photos.keys.filter { !setMembers.contains($0) && assets[$0] != nil }

        switch mode {
        case .aesthetic:
            scatter.sort { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }
            for pid in scatter where !used.contains(pid) {
                result.append(("散图·\(photos[pid]?.level.shortLabel ?? "")", pid))
                used.insert(pid)
            }

        case .standard:
            // 第一层：裸露分级定段落（T3→T2→T1→T0）
            for lv in stride(from: 3, through: 0, by: -1) {
                let inPara = scatter.filter { photos[$0]?.level.rawValue == lv }
                guard !inPara.isEmpty else { continue }
                // 第二层：风格聚堆（宽松指纹阈值 + 并查集）
                let clusters = styleClusters(inPara)
                // 堆间：按堆均颜值降序
                let orderedClusters = clusters.sorted { ca, cb in
                    let avgA = ca.reduce(0.0) { $0 + (photos[$1]?.scores.aesthetic ?? 0) } / Double(ca.count)
                    let avgB = cb.reduce(0.0) { $0 + (photos[$1]?.scores.aesthetic ?? 0) } / Double(cb.count)
                    return avgA > avgB
                }
                for (ci, cluster) in orderedClusters.enumerated() {
                    // 第三层：堆内颜值降序
                    let sorted = cluster.sorted { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }
                    let tag = clusters.count > 1 ? "T\(lv)·堆\(ci + 1)" : "T\(lv)"
                    for pid in sorted where !used.contains(pid) {
                        result.append(("散图·\(tag)", pid))
                        used.insert(pid)
                    }
                }
            }

        case .similar:
            // 纯相似：不分段落，全部散图聚堆；堆间按最高分级 → 堆均颜值
            let clusters = styleClusters(scatter)
            let orderedClusters = clusters.sorted { ca, cb in
                let lvA = ca.compactMap { photos[$0]?.level.rawValue }.max() ?? 0
                let lvB = cb.compactMap { photos[$0]?.level.rawValue }.max() ?? 0
                if lvA != lvB { return lvA > lvB }
                let avgA = ca.reduce(0.0) { $0 + (photos[$1]?.scores.aesthetic ?? 0) } / Double(ca.count)
                let avgB = cb.reduce(0.0) { $0 + (photos[$1]?.scores.aesthetic ?? 0) } / Double(cb.count)
                return avgA > avgB
            }
            for (ci, cluster) in orderedClusters.enumerated() {
                let sorted = cluster.sorted { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }
                for pid in sorted where !used.contains(pid) {
                    result.append(("堆\(ci + 1)", pid))
                    used.insert(pid)
                }
            }
        }

        // 兜底：任何漏网照片追加在尾部（保证张数守恒）
        for pid in photos.keys where !used.contains(pid) && assets[pid] != nil {
            result.append(("未归类", pid))
            used.insert(pid)
        }
        return result
    }

    /// 风格堆：比成组更宽松的指纹聚类（软分组，只影响排序，不产生归属）
    private func styleClusters(_ ids: [String]) -> [[String]] {
        let t = Float(thresholds.clusterLoose)
        var parent: [String: String] = [:]
        for id in ids { parent[id] = id }
        func find(_ x0: String) -> String {
            var x = x0
            while let p = parent[x], p != x {
                let gp = parent[p] ?? p
                parent[x] = gp
                x = gp
            }
            return x
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        let arr = ids.sorted()
        for i in 0..<arr.count {
            guard let f1 = fingerprints[arr[i]] else { continue }
            for j in (i + 1)..<arr.count {
                guard let f2 = fingerprints[arr[j]] else { continue }
                if AestheticAnalyzer.distance(f1, f2) < t { union(arr[i], arr[j]) }
            }
        }
        var buckets: [String: [String]] = [:]
        for id in arr { buckets[find(id), default: []].append(id) }
        return buckets.values.sorted { $0.count > $1.count }
    }

    // MARK: - 建相册（引用，不移动照片）

    private func findAlbum(named name: String) -> PHAssetCollection? {
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var found: PHAssetCollection?
        fetch.enumerateObjects { col, _, _ in
            if col.localizedTitle == name { found = col }
        }
        return found
    }

    func createAlbum(named name: String, photoIDs: [String], completion: @escaping (String?) -> Void) {
        let list = photoIDs.compactMap { assets[$0] } as NSArray
        guard list.count > 0 else { completion("没有可归档的照片"); return }
        PHPhotoLibrary.shared().performChanges {
            if let existing = self.findAlbum(named: name) {
                PHAssetCollectionChangeRequest(for: existing)?.addAssets(list)
            } else {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                req.addAssets(list)
            }
        } completionHandler: { ok, err in
            self.ui { completion(ok ? nil : (err?.localizedDescription ?? "创建失败")) }
        }
    }

    // MARK: - 查重（指纹 < 1.5 且尺寸一致）

    func findDuplicateGroups() -> [[String]] {
        var groups: [[String]] = []
        var claimed = Set<String>()
        let ids = photos.keys.sorted()
        for id in ids {
            guard !claimed.contains(id), let fp = fingerprints[id] else { continue }
            var group = [id]
            for id2 in ids where id2 != id {
                guard !claimed.contains(id2), let fp2 = fingerprints[id2] else { continue }
                guard let a = assets[id], let b = assets[id2], a.pixelWidth == b.pixelWidth else { continue }
                if AestheticAnalyzer.distance(fp, fp2) < 1.5 {
                    group.append(id2)
                    claimed.insert(id2)
                }
            }
            if group.count > 1 {
                groups.append(group)
                claimed.insert(id)
            }
        }
        return groups
    }

    func delete(ids: [String], completion: @escaping (String?) -> Void) {
        let list: [PHAsset] = ids.compactMap { assets[$0] }
        guard !list.isEmpty else { completion("无照片"); return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(list as NSArray)
        }, completionHandler: { (ok: Bool, err: Error?) in
            self.ui {
                if ok {
                    for id in ids {
                        self.photos.removeValue(forKey: id)
                        self.assets.removeValue(forKey: id)
                    }
                }
                completion(ok ? nil : (err?.localizedDescription ?? "删除失败"))
            }
        })
    }

    // MARK: - 缓存

    private struct CacheFile: Codable {
        var photos: [String: AnalyzedPhoto]
        var sets: [PhotoSet]
        var fingerprints: [String: Data]
        var assetsMeta: [String: AssetMeta]
        var videoItems: [String: VideoItem]?
    }

    struct AssetMeta: Codable {
        var w: Int, h: Int
        var creation: Date?
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("analysis_cache.json")
    }

    func saveCache() {
        var metas: [String: AssetMeta] = [:]
        for (id, a) in assets {
            metas[id] = AssetMeta(w: a.pixelWidth, h: a.pixelHeight, creation: a.creationDate)
        }
        let file = CacheFile(photos: photos, sets: sets, fingerprints: fingerprints, assetsMeta: metas, videoItems: videoItems)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(file) {
                try? data.write(to: self.cacheURL)
            }
        }
    }

    func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              !file.photos.isEmpty else { return }
        photos = file.photos
        sets = file.sets
        fingerprints = file.fingerprints
        for (id, meta) in file.assetsMeta {
            if let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                assets[id] = a
            } else {
                _ = meta // 资产已删除的照片自然消失
            }
        }
        photos = photos.filter { assets[$0.key] != nil }
        if let v = file.videoItems { videoItems = v }
        for id in videoItems.keys {
            videoAssets[id] = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        }
        videoItems = videoItems.filter { videoAssets[$0.key] != nil }
        hasData = true
    }

    func clearAllData() {
        photos = [:]; assets = [:]; sets = []; fingerprints = [:]
        videoItems = [:]; videoAssets = [:]
        overrides = Overrides(); overrides.save()
        hasData = false
        try? FileManager.default.removeItem(at: cacheURL)
    }
}
