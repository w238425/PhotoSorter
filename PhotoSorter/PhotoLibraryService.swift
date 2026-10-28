import Photos
import UIKit

struct AlbumInfo: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let isShared: Bool
    let isUserAlbum: Bool     // 用户自建相册（默认隐藏，避免混入醒图/微信/美颜相机等）
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
    /// 重新绑定结果提示（退出 iCloud 重登后 ID 变化用）
    @Published var rebindInfo: String? = nil
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

    /// 默认只显示「本地」与 iCloud 共享相册；第三方 App 建的相册混在用户自建相册里，
    /// 无公开 API 可区分，因此默认隐藏，需要时再打开开关。
    @Published var showUserAlbums = false

    func loadAlbums() {
        var list: [AlbumInfo] = []
        func add(_ fetch: PHFetchResult<PHAssetCollection>, shared: Bool, user: Bool) {
            fetch.enumerateObjects { col, _, _ in
                let count = PHAsset.fetchAssets(in: col, options: nil).count
                if count > 0 {
                    list.append(AlbumInfo(id: col.localIdentifier,
                                          title: col.localizedTitle ?? "未命名",
                                          count: count, isShared: shared,
                                          isUserAlbum: user))
                }
            }
        }
        // 本机图库（改名「本地」）
        add(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil), shared: false, user: false)
        // 用户自建 / 第三方相册
        add(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil), shared: false, user: true)
        // iCloud 共享相册
        add(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil), shared: true, user: false)

        albums = list
        if selectedAlbumIDs.isEmpty {
            selectedAlbumIDs = Set(list.filter { $0.isShared }.prefix(1).map { $0.id })
        }
    }

    var visibleAlbums: [AlbumInfo] {
        albums.filter { showUserAlbums || !$0.isUserAlbum }
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
            self?.runScan(collections: cols, net: net)
        }
    }

    /// 扫描主体：单独拆成方法，避免大闭包触发 Swift 类型检查超时
    private func runScan(collections cols: [PHAssetCollection], net: Bool) {

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

                    // 人体定位：关节切出上身/下身/腿/裆部，供 CLIP 分区域编码
                    let det = BodyRegionDetector.shared.detect(img)
                    // 像素级人体解析：把「穿没穿衣服」变成可测量的事实。
                    // 只有画面里确实有人才值得跑——风景/食物/截图直接跳过，
                    // 解析模型是单张耗时的大头，这样能省下大部分时间。
                    let parse = det.personArea >= 0.05 ? HumanParsing.shared.parse(img) : nil
                    let personArea = parse?.personArea ?? det.personArea

                    // 一次图像编码同时拿到主标签、写真概率和精细标签
                    let main = TagEngine.shared.classifyMain(img, regions: det.regions,
                                                             parse: parse,
                                                             personArea: personArea,
                                                             skinInPerson: det.skinInPerson)
                    let tags = main?.tags ?? []
                    var level = self.classifyLevel(scores, tags: tags)
                    if let lv = self.overrides.levelOverride[id] {
                        level = ExposureLevel(rawValue: lv) ?? level
                    }
                    let parts = self.resolveParts(analyzer: analyzer, img: img, parse: parse)
                    var photo = AnalyzedPhoto(id: id, scores: scores, level: level,
                                              parts: parts, tags: tags)
                    self.applyMainTag(main, to: &photo, scores: scores, level: level,
                                      parse: parse, skinInPerson: det.skinInPerson)
                    // 手工指定永远压过自动判定
                    if let forced = self.overrides.tagOverride[id] {
                        photo.mainTag = forced
                        photo.tagConf = 1.0
                    }
                    analyzed[id] = photo
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

    /// 部位判定：有人体解析时按像素比例裁决，否则回退到启发式
    private func resolveParts(analyzer: AestheticAnalyzer, img: CGImage,
                              parse: HumanParsing.Result?) -> [BodyPart] {
        guard let p = parse, p.personArea >= 0.005 else {
            return analyzer.detectBodyParts(img)
        }
        let lower = p.pantsRatio + p.shoeRatio
        if p.faceRatio > 0.30 { return [.face] }
        if p.legRatio > 0.40 && p.upperRatio < 0.10 { return [.lower] }
        if p.shoeRatio > 0.30 && p.legRatio < 0.20 && p.upperRatio < 0.15 { return [.feet] }
        if lower > 0.38 && p.upperRatio < 0.12 { return [.lower] }
        if p.faceRatio > 0.015 && p.upperRatio > 0.08 && (lower > 0.10 || p.legRatio > 0.10) {
            return [.full]
        }
        if lower < 0.05 && p.legRatio < 0.12 && p.faceRatio < 0.30 { return [.upper] }
        return [.full]
    }

    /// 把区间 [low, high] 线性映射到 0~1
    private func mapExposure(_ v: Double, low: Double, high: Double) -> Double {
        let x = (v - low) / max(high - low, 0.001)
        return max(0.0, min(1.0, x))
    }

    /// 把 CLIP 主标签结论写进记录。单独成方法：大函数里的复合表达式会拖垮 Swift 类型检查。
    private func applyMainTag(_ main: TagEngine.MainTagResult?,
                              to photo: inout AnalyzedPhoto,
                              scores: PhotoScores,
                              level: ExposureLevel,
                              parse: HumanParsing.Result?,
                              skinInPerson: Double?) {
        // 裸露度的证据优先级：解析的裸皮像素 > 人物掩码内的肤色 > 整图肤色启发式
        var base: Double
        var reliable: Bool
        if let p = parse {
            base = mapExposure(p.exposure, low: 0.12, high: 0.75)
            reliable = true
        } else if let s = skinInPerson {
            base = mapExposure(s, low: 0.20, high: 0.70)
            reliable = true
        } else {
            base = min(1.0, scores.skinRatio / 0.55)
            reliable = false
        }

        guard let main = main else {
            photo.mainTag = ClothingLadder.other.rawValue
            photo.isPortrait = level.rawValue >= ExposureLevel.portrait.rawValue
            photo.exposure = min(100.0, 100.0 * base)
            return
        }
        photo.mainTag = main.tag
        photo.tagConf = main.conf
        // 第一层：写真判定——CLIP 写真分 + 有人 + 非人像内容不占优
        photo.isPortrait = main.portraitQualified && level.rawValue >= ExposureLevel.portrait.rawValue
        // 第三层用的裸露度：像素证据为主，CLIP 裸露概率只做小幅修正
        // 用小函数取值：避免 4 段「字典下标 + ??」连写拖垮类型检查
        func prob(_ k: String) -> Double { main.probs[k] ?? 0 }
        let nudity: Double = prob("无胸罩") + prob("开裆") + prob("全裸") + 0.5 * prob("比基尼")
        let w = reliable ? 0.18 : 0.32
        let clipPart: Double = w * min(1.0, nudity * 2.0)
        photo.exposure = min(100.0, 100.0 * (base * (1 - w) + clipPart))
    }

    // MARK: - 手动纠错（顺带训练原型）

    /// 用户把某张照片改判为另一个服装主标签：立即生效，并让该类原型向它靠拢
    func setMainTag(_ tag: String, for id: String) {
        var o = overrides
        o.tagOverride[id] = tag
        o.save()
        DispatchQueue.main.async {
            self.overrides = o
            if var p = self.photos[id] {
                p.mainTag = tag
                p.tagConf = 1.0
                self.photos[id] = p
            }
            self.saveCache()
            // 原型学习：重新取图编码一次，让后续同类照片自动跟着改
            let asset = self.assets[id]
            DispatchQueue.global(qos: .utility).async {
                guard let asset,
                      let img = AestheticAnalyzer.shared.image(for: asset, maxPixel: 512,
                                                               allowNetwork: false),
                      let v = TagEngine.shared.imageVector(img) else { return }
                TagEngine.shared.updatePrototype(tag: tag, vec: v)
            }
        }
    }

    func clearMainTagOverride(for id: String) {
        var o = overrides
        o.tagOverride.removeValue(forKey: id)
        o.save()
        DispatchQueue.main.async { self.overrides = o; self.saveCache() }
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
        let all = photos.keys.filter { assets[$0] != nil }

        func avgExposure(_ ids: [String]) -> Double {
            guard !ids.isEmpty else { return 0 }
            return ids.reduce(0.0) { $0 + (photos[$1]?.exposure ?? 0) } / Double(ids.count)
        }

        if mode == .aesthetic {
            for pid in all.sorted(by: { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }) {
                result.append(("按颜值", pid)); used.insert(pid)
            }
            return result
        }

        if mode == .similar {
            for (ci, c) in styleClusters(all).enumerated() {
                for pid in c.sorted(by: { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) })
                where !used.contains(pid) {
                    result.append(("堆\(ci + 1)", pid)); used.insert(pid)
                }
            }
            for pid in all where !used.contains(pid) { result.append(("未归类", pid)); used.insert(pid) }
            return result
        }

        // ===== 三层排序 =====
        // 第一层：写真区块（排完即锁定，后面两层不碰）
        let portraits = all.filter { photos[$0]?.isPortrait == true }
        var setBuckets: [Int: [String]] = [:]
        var portraitSingles: [String] = []
        for pid in portraits {
            if let sid = photos[pid]?.setID,
               (sets.first(where: { $0.id == sid })?.photoIDs.count ?? 0) >= 2 {
                setBuckets[sid, default: []].append(pid)
            } else {
                portraitSingles.append(pid)
            }
        }
        // 套间按套平均裸露度升序（保守在前）；套内封面=质量最高，其余按质量降序
        for sid in setBuckets.keys.sorted(by: { avgExposure(setBuckets[$0] ?? []) < avgExposure(setBuckets[$1] ?? []) }) {
            guard let members = setBuckets[sid] else { continue }
            var ordered = members.sorted { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }
            if let cover = sets.first(where: { $0.id == sid })?.coverID,
               let ci = ordered.firstIndex(of: cover) {
                ordered.remove(at: ci)
                ordered.insert(cover, at: 0)
            }
            for pid in ordered where !used.contains(pid) {
                result.append(("写真·套\(sid)", pid)); used.insert(pid)
            }
        }
        // 不成套的散写真 → 写真页里的「其他」组
        for pid in portraitSingles.sorted(by: { (photos[$0]?.exposure ?? 0) < (photos[$1]?.exposure ?? 0) })
        where !used.contains(pid) {
            result.append(("写真·其他", pid)); used.insert(pid)
        }

        // 第二层：服装主标签，组间按暴露阶梯升序；第三层：组内 部位聚堆 → 相似聚簇 → 裸露度升序
        var buckets: [String: [String]] = [:]
        for pid in all where photos[pid]?.isPortrait != true {
            let tag = photos[pid]?.mainTag ?? ClothingLadder.other.rawValue
            buckets[tag, default: []].append(pid)
        }
        for name in ClothingLadder.orderedNames {
            guard let ids = buckets[name], !ids.isEmpty else { continue }
            let byPart = Dictionary(grouping: ids) { photos[$0]?.part.sortIndex ?? 6 }
            for key in byPart.keys.sorted() {
                guard let sub = byPart[key] else { continue }
                let clusters = styleClusters(sub).sorted { avgExposure($0) < avgExposure($1) }
                for c in clusters {
                    for pid in c.sorted(by: { (photos[$0]?.exposure ?? 0) < (photos[$1]?.exposure ?? 0) })
                    where !used.contains(pid) {
                        result.append((name, pid)); used.insert(pid)
                    }
                }
            }
        }

        // 兜底：保证张数守恒
        for pid in all where !used.contains(pid) {
            result.append(("未归类", pid)); used.insert(pid)
        }
        return result
    }

    // MARK: - 浏览用的分组视图（写真套图 / 服装标签 / 部位）

    // MARK: - 隐藏（共享相册只读，删不掉，只能在 App 内隐藏）

    func setHidden(_ id: String, _ on: Bool) {
        overrides.hidden[id] = on
        overrides.save()
        objectWillChange.send()
    }

    func isHidden(_ id: String) -> Bool { overrides.hidden[id] == true }

    private func visible() -> [String] {
        photos.keys.filter { assets[$0] != nil && overrides.hidden[$0] != true }
    }

    /// 写真页：成套写真 + 散写真（其他）
    func portraitGroups() -> [(title: String, ids: [String])] {
        let all = visible().filter { photos[$0]?.isPortrait == true }
        var groups: [(String, [String])] = []
        var inSet = Set<String>()
        for s in sets where s.photoIDs.count >= 2 {
            let members = s.photoIDs.filter { all.contains($0) }
            guard !members.isEmpty else { continue }
            var ordered = members.sorted { (photos[$0]?.scores.aesthetic ?? 0) > (photos[$1]?.scores.aesthetic ?? 0) }
            if let cover = s.coverID, let ci = ordered.firstIndex(of: cover) {
                ordered.remove(at: ci); ordered.insert(cover, at: 0)
            }
            groups.append(("写真套图 \(s.id)", ordered))
            inSet.formUnion(members)
        }
        let singles = all.filter { !inSet.contains($0) }
            .sorted { (photos[$0]?.exposure ?? 0) < (photos[$1]?.exposure ?? 0) }
        if !singles.isEmpty { groups.append(("其他（散写真）", singles)) }
        return groups
    }

    /// 标签页：互斥主标签 + 张数，类别之间零重叠
    func tagGroups() -> [(title: String, ids: [String])] {
        let all = visible().filter { photos[$0]?.isPortrait != true }
        var buckets: [String: [String]] = [:]
        for pid in all { buckets[photos[pid]?.mainTag ?? ClothingLadder.other.rawValue, default: []].append(pid) }
        var out: [(String, [String])] = []
        for name in ClothingLadder.orderedNames {
            guard let ids = buckets[name], !ids.isEmpty else { continue }
            let byPart = Dictionary(grouping: ids) { photos[$0]?.part.sortIndex ?? 6 }
            var flat: [String] = []
            for key in byPart.keys.sorted() { flat.append(contentsOf: byPart[key] ?? []) }
            out.append((name, flat))
        }
        return out
    }

    /// 部位页：浏览入口，不参与序列排序
    func partGroups() -> [(title: String, ids: [String])] {
        let all = visible()
        var buckets: [String: [String]] = [:]
        for pid in all { buckets[photos[pid]?.part.rawValue ?? "未判定", default: []].append(pid) }
        return BodyPart.allCases
            .filter { !(buckets[$0.rawValue] ?? []).isEmpty }
            .map { ($0.rawValue, buckets[$0.rawValue]!) }
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

    // MARK: - 重新绑定（退出 iCloud 再登录后照片 ID 可能变化）

    /// 纯元数据签名：拍摄时间(秒) + 像素尺寸。不加载图像、不触发下载。
    private func sigKey(w: Int, h: Int, d: Date?) -> String {
        let t = d.map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(t)_\(w)x\(h)"
    }

    /// 把「找不到资产」的旧记录用元数据签名重新绑到现有照片上。
    /// 只在签名唯一命中时才绑定，多个候选不猜（避免绑错）。
    private func rebindOrphans(metas: [String: AssetMeta]) {
        let orphans = photos.keys.filter { assets[$0] == nil }
        guard !orphans.isEmpty else { return }

        // 全库影像资产索引：只读元数据，不下载、不占缓存
        var index: [String: PHAsset] = [:]
        var sigMap: [String: [String]] = [:]
        func collect(_ fetch: PHFetchResult<PHAsset>) {
            fetch.enumerateObjects { a, _, _ in
                guard a.mediaType == .image else { return }
                index[a.localIdentifier] = a
                let k = self.sigKey(w: a.pixelWidth, h: a.pixelHeight, d: a.creationDate)
                sigMap[k, default: []].append(a.localIdentifier)
            }
        }
        collect(PHAsset.fetchAssets(with: .image, options: nil))
        // iCloud 共享相册的资产不一定进全局 fetch，单独再扫一遍
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            .enumerateObjects { col, _, _ in
                collect(PHAsset.fetchAssets(in: col, options: nil))
            }

        var remap: [String: String] = [:]
        for old in orphans {
            guard let meta = metas[old] else { continue }
            let k = sigKey(w: meta.w, h: meta.h, d: meta.creation)
            guard let cands = sigMap[k], cands.count == 1 else { continue }
            let new = cands[0]
            if photos[new] == nil { remap[old] = new }   // 新 ID 已被占用则不覆盖
        }
        guard !remap.isEmpty else {
            rebindInfo = "有 \(orphans.count) 张照片找不到对应（可能是真删除了）"
            return
        }

        for (old, new) in remap {
            if var rec = photos.removeValue(forKey: old) {
                rec.id = new
                photos[new] = rec
            }
            if let fp = fingerprints.removeValue(forKey: old) { fingerprints[new] = fp }
            if let a = index[new] { assets[new] = a }
            for i in sets.indices {
                sets[i].photoIDs = sets[i].photoIDs.map { $0 == old ? new : $0 }
                if sets[i].coverID == old { sets[i].coverID = new }
            }
            overrides.remapID(from: old, to: new)
        }
        overrides.save()
        saveCache()

        let left = orphans.count - remap.count
        rebindInfo = left > 0
            ? "已自动重新绑定 \(remap.count) 张照片，另有 \(left) 张未匹配（建议重新分析）"
            : "已自动重新绑定 \(remap.count) 张照片（iCloud ID 已变化）"
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
        rebindOrphans(metas: file.assetsMeta)
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
