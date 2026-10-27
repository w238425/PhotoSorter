import Photos

// MARK: - 暴露分级（严格量化，见策划案）

enum ExposureLevel: Int, CaseIterable, Codable, Identifiable {
    case normal = 0      // T0 普通照片
    case portrait = 1    // T1 写真
    case revealing = 2   // T2 暴露写真
    case explicit = 3    // T3 非常暴露写真

    var id: Int { rawValue }
    var label: String { ["普通", "写真", "暴露", "非常暴露"][rawValue] }
    var shortLabel: String { ["T0", "T1", "T2", "T3"][rawValue] }
    var color: String { ["gray", "blue", "orange", "red"][rawValue] }
}

// MARK: - 部位分类

enum BodyPart: String, CaseIterable, Codable, Identifiable {
    case face = "人脸"
    case hand = "手"
    case upper = "上半身"
    case lower = "下半身"
    case feet = "脚"
    case full = "全身"
    case undetermined = "未判定"

    var id: String { rawValue }

    /// 兼容旧缓存：上一版用过「脚部」，直接解码会整批失败
    init(from decoder: Decoder) throws {
        let v = try decoder.singleValueContainer().decode(String.self)
        if v == "脚部" { self = .feet } else { self = Self(rawValue: v) ?? .undetermined }
    }
    /// 组内二次切分的固定顺序（手和手、脚和脚相邻）
    var sortIndex: Int {
        switch self {
        case .full: return 0
        case .upper: return 1
        case .lower: return 2
        case .feet: return 3
        case .hand: return 4
        case .face: return 5
        case .undetermined: return 6
        }
    }
}

// MARK: - 服装主标签（第二层，唯一归属，按暴露度升序即组间顺序）

enum ClothingLadder: String, CaseIterable, Codable {
    case trousers  = "长裤长裙"
    case shorts    = "短裙短裤"
    case uniform   = "制服"
    case cosplay   = "Cosplay"
    case bra       = "胸罩内裤"
    case bikini    = "比基尼"
    case topless   = "无胸罩"
    case stockings = "黑丝"
    case bath      = "浴室"
    case crotchless = "开裆"
    case nude      = "全裸"
    case other     = "其他"

    static var orderedNames: [String] { allCases.map { $0.rawValue } }

    /// 每张照片只归一个主标签：越具体越优先（值越大越优先）
    static func priority(_ name: String) -> Int {
        switch name {
        case crotchless.rawValue: return 100
        case nude.rawValue: return 95
        case stockings.rawValue: return 90
        case bath.rawValue: return 85
        case topless.rawValue: return 80
        case bikini.rawValue: return 70
        case bra.rawValue: return 60
        case cosplay.rawValue: return 50
        case uniform.rawValue: return 40
        case shorts.rawValue: return 30
        case trousers.rawValue: return 20
        default: return 0
        }
    }

    /// 组间顺序：暴露阶梯升序（保守在前）
    static func index(_ name: String) -> Int {
        orderedNames.firstIndex(of: name) ?? (orderedNames.count - 1)
    }
}

// MARK: - 照片分析结果

struct PhotoScores: Codable {
    var sharpness: Double = 0        // 清晰度 0~1
    var exposureScore: Double = 0    // 曝光水平 0~1
    var skinRatio: Double = 0        // 肤色占比 0~1
    var faceCount: Int = 0
    var faceAreaRatio: Double = 0    // 最大人脸占画面比例
    var aesthetic: Double = 0        // 综合颜值分 0~1
    var hasFilter: Bool = false      // 重滤镜标记
}

struct AnalyzedPhoto: Identifiable, Codable {
    let id: String                   // PHAsset localIdentifier
    var scores: PhotoScores
    var level: ExposureLevel
    var parts: [BodyPart]
    var setID: Int?
    var preciseDone: Bool = false    // 是否已完成高清精评
    var tags: [String] = []          // CLIP 精细标签（胸罩/黑丝/cosplay…）
    /// 第二层唯一归属的服装主标签（可空 = 未定，归"其他"）
    var mainTag: String = ClothingLadder.other.rawValue
    /// 主标签 softmax 置信度 0~1
    var tagConf: Double = 0
    /// 0~100 裸露度（像素解析为主，CLIP 为修正）
    var exposure: Double = 0
    /// 是否写真（第一层锁定区块）
    var isPortrait: Bool = false

    var part: BodyPart { parts.first ?? .undetermined }

    enum CodingKeys: String, CodingKey {
        case id, scores, level, parts, setID, preciseDone, tags
        case mainTag, tagConf, exposure, isPortrait
    }

    init(id: String, scores: PhotoScores, level: ExposureLevel, parts: [BodyPart], setID: Int? = nil, preciseDone: Bool = false, tags: [String] = []) {
        self.id = id; self.scores = scores; self.level = level
        self.parts = parts; self.setID = setID; self.preciseDone = preciseDone
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        scores = try c.decode(PhotoScores.self, forKey: .scores)
        level = try c.decode(ExposureLevel.self, forKey: .level)
        parts = try c.decode([BodyPart].self, forKey: .parts)
        setID = try c.decodeIfPresent(Int.self, forKey: .setID)
        preciseDone = try c.decodeIfPresent(Bool.self, forKey: .preciseDone) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        mainTag = try c.decodeIfPresent(String.self, forKey: .mainTag) ?? ClothingLadder.other.rawValue
        tagConf = try c.decodeIfPresent(Double.self, forKey: .tagConf) ?? 0
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        isPortrait = try c.decodeIfPresent(Bool.self, forKey: .isPortrait) ?? false
    }
}

// MARK: - 套（成组的最小单位，永不拆散）

struct PhotoSet: Identifiable, Codable {
    let id: Int
    var name: String
    var photoIDs: [String]
    var coverID: String?
    var levelRaw: Int = 0            // 套内最高暴露档

    var level: ExposureLevel { ExposureLevel(rawValue: levelRaw) ?? .normal }
}

// MARK: - 视频条目

struct VideoItem: Identifiable, Codable {
    let id: String
    var duration: Double             // 秒
    var fileSize: Int64              // 字节
    var pixelWidth: Int
    var pixelHeight: Int
    var skinRatio: Double = -1       // -1 = 未深度分析
    var stability: Double = -1       // 0~1，越高越稳

    var bitrateMbps: Double {
        duration > 0 ? Double(fileSize) * 8 / duration / 1_000_000 : 0
    }
    var qualityTier: String {
        let h = max(pixelWidth, pixelHeight)
        if h >= 2160 { return "4K" }
        if h >= 1080 { return "1080p" }
        if h >= 720 { return "720p" }
        return "标清"
    }
    var sizeMB: String { String(format: "%.1f MB", Double(fileSize) / 1_048_576) }
    var durationText: String {
        let m = Int(duration) / 60, s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - 阈值（全部可在设置里调）

struct Thresholds: Codable {
    var minFaceArea: Double = 0.08   // T1 最低人脸占比
    var minSharpness: Double = 0.40  // T1 最低清晰度
    var t2SkinLow: Double = 0.20     // T2 肤色下限
    var t2SkinHigh: Double = 0.45    // T2 肤色上限 / T3 下限
    var goodHigh: Double = 0.70      // 好看-高
    var goodMid: Double = 0.45       // 好看-中
    var groupStrict: Double = 4.0    // 成组阈值：严格
    var groupMedium: Double = 6.0    // 适中
    var groupLoose: Double = 9.0     // 宽松
    var clusterLoose: Double = 12.0  // 散图风格堆阈值（比成组更宽松的轻聚类）

    static var saveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thresholds.json")
    }
    static func load() -> Thresholds {
        if let d = try? Data(contentsOf: saveURL), let t = try? JSONDecoder().decode(Thresholds.self, from: d) { return t }
        return Thresholds()
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.saveURL) }
}

// MARK: - 手动调整（永久记住，扫描不覆盖）

struct Overrides: Codable {
    var levelOverride: [String: Int] = [:]   // 照片ID -> 强制分级
    var setMove: [String: Int] = [:]         // 照片ID -> 强制移入的套ID
    var setRemove: [String: Bool] = [:]      // 照片ID -> 强制移出所属套
    var hidden: [String: Bool] = [:]         // 照片ID -> App 内隐藏（共享相册无法真删）

    static var saveURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("overrides.json")
    }
    static func load() -> Overrides {
        if let d = try? Data(contentsOf: saveURL), let o = try? JSONDecoder().decode(Overrides.self, from: d) { return o }
        return Overrides()
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.saveURL) }
}
