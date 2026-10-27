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
    case feet = "脚部"
    case full = "全身"
    case undetermined = "未判定"

    var id: String { rawValue }
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

    enum CodingKeys: String, CodingKey {
        case id, scores, level, parts, setID, preciseDone
    }

    init(id: String, scores: PhotoScores, level: ExposureLevel, parts: [BodyPart], setID: Int? = nil, preciseDone: Bool = false) {
        self.id = id; self.scores = scores; self.level = level
        self.parts = parts; self.setID = setID; self.preciseDone = preciseDone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        scores = try c.decode(PhotoScores.self, forKey: .scores)
        level = try c.decode(ExposureLevel.self, forKey: .level)
        parts = try c.decode([BodyPart].self, forKey: .parts)
        setID = try c.decodeIfPresent(Int.self, forKey: .setID)
        preciseDone = try c.decodeIfPresent(Bool.self, forKey: .preciseDone) ?? false
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
