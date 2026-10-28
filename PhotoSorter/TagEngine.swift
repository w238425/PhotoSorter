import CoreML
import UIKit

/// 精细标签引擎：内置 CLIP ViT-B/32（图像+文本双编码器，全离线）
/// - 默认标签表 Resources/labels_default.json（服装/丝袜/制服/场景/内容/暴露）
/// - 用户可在 App 内添加自定义标签（文本编码器在手机上现场算向量）
final class TagEngine {

    static let shared = TagEngine()

    struct LabelDef: Codable, Identifiable, Hashable {
        var cn: String
        var en: String
        var cat: String
        var expo: Int          // 0=无 1=暴露写真 2=高度暴露 3=非常暴露
        var id: String { cn }
    }

    private(set) var available = false
    private var didSetup = false
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var defaults: [LabelDef] = []
    private var custom: [LabelDef] = []
    private var embeddings: [String: [Float]] = [:]     // cn -> 归一化 512 维

    // MARK: - 持久化

    static var customURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("labels_custom.json")
    }
    static var embedURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("label_embeddings.json")
    }

    var allLabels: [LabelDef] { defaults + custom }

    static func loadCustom() -> [LabelDef] {
        guard let d = try? Data(contentsOf: customURL),
              let l = try? JSONDecoder().decode([LabelDef].self, from: d) else { return [] }
        return l
    }

    func addCustomTag(cn: String, en: String, cat: String = "自定义", expo: Int) {
        guard !cn.isEmpty, !allLabels.contains(where: { $0.cn == cn }) else { return }
        lazySetup()
        let def = LabelDef(cn: cn, en: en, cat: cat, expo: expo)
        if let e = embedText(en) {
            custom.append(def)
            embeddings[cn] = e
            persist()
        }
    }

    func removeCustomTag(cn: String) {
        custom.removeAll { $0.cn == cn }
        embeddings.removeValue(forKey: cn)
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(custom) { try? d.write(to: Self.customURL) }
        if let d = try? JSONEncoder().encode(embeddings) { try? d.write(to: Self.embedURL) }
    }

    // MARK: - 初始化（懒加载，首次调用在后台线程）

    private func lazySetup() {
        guard !didSetup else { return }
        didSetup = true

        guard let imgURL = Bundle.main.url(forResource: "CLIP_ImageEncoder", withExtension: "mlmodelc"),
              let txtURL = Bundle.main.url(forResource: "CLIP_TextEncoder", withExtension: "mlmodelc") else { return }
        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json", subdirectory: "Tokenizer"),
              let mergesURL = Bundle.main.url(forResource: "merges", withExtension: "txt", subdirectory: "Tokenizer"),
              let vd = try? Data(contentsOf: vocabURL),
              let md = try? Data(contentsOf: mergesURL),
              let tok = CLIPTokenizer(vocabData: vd, mergesData: md) else { return }

        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let im = try? MLModel(contentsOf: imgURL, configuration: cfg),
              let tm = try? MLModel(contentsOf: txtURL, configuration: cfg) else { return }
        imageModel = im
        textModel = tm
        tokenizer = tok

        // 默认标签表
        if let u = Bundle.main.url(forResource: "labels_default", withExtension: "json"),
           let d = try? Data(contentsOf: u),
           let defs = try? JSONDecoder().decode([LabelDef].self, from: d) {
            defaults = defs
        }
        custom = Self.loadCustom()

        // 向量缓存（首次启动计算一次，之后秒读）
        if let d = try? Data(contentsOf: Self.embedURL),
           let e = try? JSONDecoder().decode([String: [Float]].self, from: d) {
            embeddings = e
        }
        computeMissingEmbeddings()
        if let d = try? Data(contentsOf: Self.ladderURL),
           let e = try? JSONDecoder().decode([String: [Float]].self, from: d) {
            ladderEmbeddings = e
        }
        available = !defaults.isEmpty && embeddings.count >= defaults.count / 2
    }

    /// 标签 → 512 维文本向量（缺失的现算）
    private func computeMissingEmbeddings() {
        guard let textModel, let tokenizer else { return }
        var changed = false
        for def in allLabels where embeddings[def.cn] == nil {
            if let e = embedText(def.en) {
                embeddings[def.cn] = e
                changed = true
            }
        }
        if changed {
            if let d = try? JSONEncoder().encode(embeddings) { try? d.write(to: Self.embedURL) }
        }
    }

    private func embedText(_ text: String) -> [Float]? {
        guard let textModel, let tokenizer else { return nil }
        let ids = tokenizer.encode(text)
        guard let arr = try? MLMultiArray(shape: [1, 77], dataType: .int32) else { return nil }
        for (i, v) in ids.enumerated() { arr[i] = NSNumber(value: v) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: arr)]) else { return nil }
        guard let out = try? textModel.prediction(from: provider),
              let emb = out.featureValue(for: "var_1317")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: 512)
        for i in 0..<512 { v[i] = emb[i].floatValue }
        normalize(&v)
        return v
    }

    // MARK: - 图像打标

    /// 返回这张照片的标签（最多 4 个，自适应阈值）
    func classify(_ image: CGImage) -> [String] {
        lazySetup()
        guard available, let imageModel else { return [] }
        guard let buf = try? MLFeatureValue(cgImage: image, pixelsWide: 224, pixelsHigh: 224,
                                            pixelFormatType: kCVPixelFormatType_32ARGB,
                                            options: nil).imageBufferValue else { return [] }
        let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buf)])
        guard let prov = provider,
              let out = try? imageModel.prediction(from: prov),
              let emb = out.featureValue(for: "var_1240")?.multiArrayValue else { return [] }
        var v = [Float](repeating: 0, count: 512)
        for i in 0..<512 { v[i] = emb[i].floatValue }
        normalize(&v)

        var scored: [(cn: String, score: Float)] = []
        for def in allLabels {
            guard let e = embeddings[def.cn] else { continue }
            scored.append((def.cn, dot(v, e)))
        }
        scored.sort { $0.score > $1.score }
        guard let top = scored.first else { return [] }
        // 自适应阈值：贴近最高分的收进来，兼容模型预处理差异
        let cutoff = max(top.score - 0.08, 0.16)
        return scored.filter { $0.score >= cutoff }.prefix(4).map { $0.cn }
    }

    // MARK: - 第二层：服装主标签阶梯（暴露度升序 = 组间顺序）

    /// 每个主标签对应若干英文提示；打分取组内最大值（标准 CLIP zero-shot）
    static let ladderPrompts: [String: [String]] = [
        "长裤长裙": ["a woman wearing long trousers", "a woman in a long skirt",
                     "a woman in a jumpsuit", "a woman in jeans"],
        "短裙短裤": ["a woman in a short skirt", "a woman wearing shorts"],
        "制服":     ["a woman in a school uniform", "a woman in an office suit",
                     "a woman in a nurse outfit"],
        "Cosplay":  ["a woman in a cosplay costume", "a woman wearing an anime costume"],
        "胸罩内裤": ["a woman wearing a bra and panties", "a lingerie set"],
        "比基尼":   ["a woman wearing a bikini", "swimwear on a woman"],
        "无胸罩":   ["a woman with a bare chest", "a topless woman covering herself"],
        "黑丝":     ["a woman wearing black stockings", "black pantyhose on legs"],
        "浴室":     ["a woman in a bathroom with a towel", "a woman in the shower"],
        "开裆":     ["open crotch lingerie"],
        "全裸":     ["a completely nude woman"],
    ]
    /// 兜底：非人物内容
    static let otherPrompts: [String] = [
        "a landscape or scenery photo", "a photo of food",
        "a photo of a pet animal", "a screenshot of a phone interface",
        "a photo of a document or text",
    ]
    static let portraitPos: [String] = [
        "a glamour portrait photo of a woman",
        "a fashion photo of a woman posing",
        "a studio photo of a woman model",
    ]
    static let portraitNeg: [String] = [
        "a casual snapshot of a street", "a photo of an empty room",
    ]
    /// 非人物内容单独一组，写真判定要求它不能超过上限
    static let sceneryNeg: [String] = [
        "a landscape or scenery photo", "a photo of food",
        "a photo of a pet animal", "a screenshot of a phone interface",
        "a photo of a document or text", "a close up product photo of an object",
    ]

    /// 低于这个 softmax 置信度就归入「其他」，不硬塞进错组
    static let minConfidence: Double = 0.15

    // MARK: - 区域路由：哪个标签该看画面的哪一块
    //
    // 这是修「黑丝判不出、开裆判不出」的核心。CLIP 只有 224×224 的输入，
    // 一张全身照里腿占不到画面 15%，缩到 224 后丝袜的纹理彻底消失，
    // 于是「黑丝」和「裸腿/深色裤子」的向量几乎重合。把腿单独裁出来
    // 再编码，丝袜立刻变成画面主体，区分度才出得来。

    enum RegionKey: Hashable { case full, upper, lower, legs, crotch }

    /// 主标签 → 该看哪个区域
    static let mainTagRegion: [String: RegionKey] = [
        "长裤长裙": .lower,     // 裤型看下半身
        "短裙短裤": .lower,
        "制服":     .full,      // 制服是整体造型
        "Cosplay":  .full,
        "胸罩内裤": .upper,
        "比基尼":   .full,
        "无胸罩":   .upper,
        "黑丝":     .legs,      // 关键：只看腿
        "浴室":     .full,
        "开裆":     .crotch,    // 关键：只看裆部
        "全裸":     .full,
    ]

    /// 精细标签 → 该看哪个区域（未列出的走整图）
    static let fineTagRegion: [String: RegionKey] = [
        "黑丝": .legs, "白丝": .legs, "渔网袜": .legs, "大腿袜": .legs,
        "连裤袜": .legs, "露腿": .legs,
        "胸罩": .upper, "内裤": .lower, "内衣蕾丝": .upper, "裸肩": .upper,
        "开裆": .crotch, "比基尼": .full, "泳装": .full,
        "牛仔裤": .lower, "连衣裙": .lower, "高跟鞋": .lower,
    ]

    struct MainTagResult {
        var tag: String
        var conf: Double
        var probs: [String: Double]
        var portrait: Double
        /// 顺带返回的精细标签（复用同一次图像编码，避免每张图跑两次 CLIP）
        var tags: [String] = []
        /// 整图 512 维向量，供原型学习使用（不落盘）
        var fullVec: [Float]?
        /// 有人体解析时的裸皮比例，调用方据此算裸露度
        var skinReal: Double?
        /// 写真三条件（有人 / 写真分够高 / 非人像内容不占优）是否同时成立
        var portraitQualified: Bool = false
    }

    private var ladderEmbeddings: [String: [Float]] = [:]

    static var ladderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("labels_ladder.json")
    }

    private func ensureLadderEmbeddings() {
        var changed = false
        let all = Self.ladderPrompts.values.flatMap { $0 } + Self.otherPrompts +
                  Self.portraitPos + Self.portraitNeg + Self.sceneryNeg + [Self.anchorPrompt]
        for p in all where ladderEmbeddings[p] == nil {
            if let e = embedText(p) { ladderEmbeddings[p] = e; changed = true }
        }
        if changed, let d = try? JSONEncoder().encode(ladderEmbeddings) {
            try? d.write(to: Self.ladderURL)
        }
    }

    /// 区域校准锚点。不同裁剪区域的绝对 cosine 不在同一尺度上（腿部裁剪整体
    /// 分数偏高），直接跨区域比大小会误判。统一减去「普通照片」的分数后，
    /// 各区域都变成「相对该区域典型内容的增量」，才具备可比性。
    static let anchorPrompt = "a photo"

    // MARK: - 图像编码与裁剪

    private func encode(_ image: CGImage) -> [Float]? {
        guard let imageModel else { return nil }
        guard let buf = try? MLFeatureValue(cgImage: image, pixelsWide: 224, pixelsHigh: 224,
                                            pixelFormatType: kCVPixelFormatType_32ARGB,
                                            options: nil).imageBufferValue else { return nil }
        guard let prov = try? MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: buf)]),
              let out = try? imageModel.prediction(from: prov),
              let emb = out.featureValue(for: "var_1240")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: 512)
        for i in 0..<512 { v[i] = emb[i].floatValue }
        normalize(&v)
        return v
    }

    /// 对外暴露：取一张图的整图 CLIP 向量（原型纠错时用）
    func imageVector(_ image: CGImage) -> [Float]? {
        lazySetup()
        return encode(image)
    }

    private func crop(_ image: CGImage, _ rect: CGRect) -> CGImage? {
        // 太小的裁剪块放大后全是插值噪声，CLIP 反而更差
        let r = rect.standardized.integral
        guard r.width >= 48, r.height >= 48 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = r.intersection(bounds)
        guard clipped.width >= 48, clipped.height >= 48 else { return nil }
        return image.cropping(to: clipped)
    }

    private func addRegion(_ key: RegionKey, rect: CGRect?, image: CGImage,
                           into vecs: inout [RegionKey: [Float]], fallback: RegionKey?) {
        if let rect, let cg = crop(image, rect), let v = encode(cg) {
            vecs[key] = v
            return
        }
        if let f = fallback, let v = vecs[f] { vecs[key] = v }
    }

    private func bestScore(_ prompts: [String], in vec: [Float]) -> Double {
        var m = -1.0
        for p in prompts {
            guard let e = ladderEmbeddings[p] else { continue }
            let s = Double(dot(vec, e))
            if s > m { m = s }
        }
        return m
    }

    /// 图像 → 主标签（唯一归属）+ 置信度 + 各类概率 + 写真概率
    ///
    /// 三路证据融合：区域化 CLIP 语义 + 人体解析的像素证据 + 用户纠错原型
    func classifyMain(_ image: CGImage,
                      regions: BodyRegions?,
                      parse: HumanParsing.Result?,
                      personArea: Double,
                      skinInPerson: Double?) -> MainTagResult? {
        lazySetup()
        guard let imageModel else { return nil }
        ensureLadderEmbeddings()
        guard let vFull = encode(image) else { return nil }

        // 局部区域按需编码；没有检测到人时只跑整图，不浪费时间
        var vecs: [RegionKey: [Float]] = [.full: vFull]
        if let r = regions {
            addRegion(.lower, rect: r.lower, image: image, into: &vecs, fallback: nil)
            addRegion(.legs, rect: r.legs, image: image, into: &vecs, fallback: .lower)
            addRegion(.upper, rect: r.upper, image: image, into: &vecs, fallback: nil)
            addRegion(.crotch, rect: r.crotch, image: image, into: &vecs, fallback: nil)
        }
        let anchor = ladderEmbeddings[Self.anchorPrompt]

        var baselines: [RegionKey: Double] = [:]
        for (k, v) in vecs {
            baselines[k] = anchor.map { Double(dot(v, $0)) } ?? 0
        }
        func calibrated(_ prompts: [String], _ key: RegionKey) -> Double {
            let v = vecs[key] ?? vFull
            let base = baselines[key] ?? 0
            return (bestScore(prompts, in: v) - base) * 100.0
        }

        // logits 用标准 CLIP 尺度（cosine x 100），softmax 后才有可比性
        var logits: [String: Double] = [:]
        for (name, prompts) in Self.ladderPrompts {
            logits[name] = calibrated(prompts, Self.mainTagRegion[name] ?? .full)
        }
        logits["其他"] = calibrated(Self.otherPrompts, .full)

        logits = applyParsingEvidence(logits, parse: parse)
        applyPrototypes(&logits, vec: vFull)

        let names = Array(logits.keys)
        let raw = names.map { logits[$0] ?? 0 }
        let probsList = softmax(raw)
        var probs: [String: Double] = [:]
        for (i, n) in names.enumerated() { probs[n] = probsList[i] }

        var bestName = "其他", bestP = -1.0
        for (n, p) in probs where n != "其他" { if p > bestP { bestP = p; bestName = n } }
        let tag = bestP >= Self.minConfidence ? bestName : "其他"

        // 写真判定：沙盒验证过 personArea 门槛与 neg 上限，缺任一都会大量误判
        let pos = calibrated(Self.portraitPos, .full)
        let neg = calibrated(Self.portraitNeg, .full)
        let scenery = calibrated(Self.sceneryNeg, .full)
        let pProbs = softmax([pos, neg, scenery])
        let portraitScore = pProbs.first ?? 0
        let negScore = pProbs.dropFirst().reduce(0, +)
        let qualified = personArea > 0.02 && portraitScore > 0.30 && negScore < 0.45

        // 精细标签：丝袜类看腿、胸罩类看上身，各自用对应区域的向量
        var scored: [(String, Float)] = []
        for def in allLabels {
            guard let e = embeddings[def.cn] else { continue }
            let key = Self.fineTagRegion[def.cn] ?? .full
            let v = vecs[key] ?? vFull
            let base = baselines[key] ?? 0
            scored.append((def.cn, dot(v, e) - Float(base)))
        }
        scored.sort { $0.1 > $1.1 }
        var tags: [String] = []
        if let top = scored.first {
            let cutoff = max(top.1 - 0.08, 0.02)
            tags = scored.filter { $0.1 >= cutoff }.prefix(4).map { $0.0 }
        }

        return MainTagResult(tag: tag, conf: max(bestP, 0), probs: probs,
                             portrait: portraitScore, tags: tags,
                             fullVec: vFull, skinReal: skinInPerson,
                             portraitQualified: qualified)
    }

    // MARK: - 人体解析的像素证据（沙盒第 4 轮验证有效）

    /// 把「身上到底有没有布」这件事从 CLIP 手里夺回来。
    /// 这几条是硬几何约束，一旦成立 CLIP 说什么都不算。
    /// 用返回值而不是 inout：Swift 不允许嵌套函数捕获 inout 参数。
    private func applyParsingEvidence(_ logits: [String: Double],
                                      parse: HumanParsing.Result?) -> [String: Double] {
        guard let p = parse else { return logits }
        // 人物太小说明解析结果不可信，一条否决都不施加，交给 CLIP 自己判
        guard p.personArea >= 0.02 else { return logits }
        var out = logits
        func bump(_ k: String, _ d: Double) { out[k] = (out[k] ?? 0) + d }

        // 裸皮太少 → 不可能是全裸 / 无胸罩 / 开裆
        if p.exposure < 0.12 {
            bump("全裸", -6.0); bump("无胸罩", -6.0); bump("开裆", -6.0)
        }
        // 下半身整体很暗 → 丝袜（解析器常把丝袜判成 pants，所以看下半身不看裸腿）
        if let dl = p.lowerBrightness, dl < 0.30 {
            bump("黑丝", 2.5); bump("长裤长裙", -1.0)
        }
        // 裤子/半裙覆盖真实存在且整体不暴露 → 长裤长裙
        if p.pantsRatio > 0.15 && p.exposure < 0.25 {
            bump("长裤长裙", 1.5)
        }
        // 上半身有大片覆盖 → 不可能是无胸罩或全裸
        if p.upperRatio > 0.22 && p.exposure < 0.35 {
            bump("无胸罩", -4.0); bump("全裸", -4.0)
        }
        // 裸皮占人物面积大多数 → 强烈指向全裸
        if p.exposure > 0.55 {
            bump("全裸", 3.0); bump("无胸罩", 1.0)
        } else if p.exposure > 0.38 {
            bump("无胸罩", 2.0); bump("比基尼", 1.0)
        }
        // 开裆的几何特征：裆部裸露，但上下仍有衣物/腿部覆盖
        if p.exposure > 0.20 && p.exposure < 0.55 {
            if p.pantsRatio < 0.10 && p.legRatio > 0.12 { bump("开裆", 1.8) }
        }
        return out
    }

    // MARK: - 原型学习（用户纠错的闭环）

    /// 主标签 → 该类图像的平均向量。用户每纠正一张，对应原型就朝
    /// 真实样本挪一点，下次同类照片直接被原型拉过去。
    private var prototypes: [String: [Float]] = [:]

    static var protoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("prototypes.json")
    }

    static let prototypeWeight: Double = 60.0   // logit 空间的加成系数

    private func loadPrototypes() {
        guard let d = try? Data(contentsOf: Self.protoURL),
              let p = try? JSONDecoder().decode([String: [Float]].self, from: d) else { return }
        prototypes = p
    }

    private func applyPrototypes(_ logits: inout [String: Double], vec: [Float]) {
        guard !prototypes.isEmpty else { return }
        for (tag, proto) in prototypes {
            let sim = Double(dot(vec, proto))
            logits[tag] = (logits[tag] ?? 0) + sim * Self.prototypeWeight
        }
    }

    /// 用户把某张照片改判为 tag：用它的图像向量更新该类原型
    func updatePrototype(tag: String, vec: [Float]) {
        if prototypes.isEmpty { loadPrototypes() }
        var v = vec
        normalize(&v)
        if let old = prototypes[tag] {
            // 指数移动平均：纠正三五张后就能明显改变分类倾向
            var merged = [Float](repeating: 0, count: 512)
            let n = min(old.count, v.count)
            for i in 0..<n { merged[i] = 0.7 * old[i] + 0.3 * v[i] }
            normalize(&merged)
            prototypes[tag] = merged
        } else {
            prototypes[tag] = v
        }
        try? JSONEncoder().encode(prototypes).write(to: Self.protoURL)
    }

    func prototypeCount() -> Int { prototypes.isEmpty ? 0 : prototypes.count }

    /// 启动时调用一次
    func warmupPrototypes() { if prototypes.isEmpty { loadPrototypes() } }

    private func softmax(_ x: [Double]) -> [Double] {
        guard let m = x.max() else { return x }
        let e = x.map { exp($0 - m) }
        let s = e.reduce(0, +)
        return s > 0 ? e.map { $0 / s } : x
    }

    /// 标签对应的暴露等级加成（0~3）
    static func exposureBoost(_ tags: [String]) -> Int {
        guard !tags.isEmpty else { return 0 }
        var best = 0
        for def in shared.allLabels where tags.contains(def.cn) {
            best = max(best, def.expo)
        }
        return best
    }

    // MARK: - 工具

    private func normalize(_ v: inout [Float]) {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if n > 0 { for i in v.indices { v[i] /= n } }
    }
    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }
}
