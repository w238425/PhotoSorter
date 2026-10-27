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
    ] + otherPrompts

    /// 低于这个 softmax 置信度就归入「其他」，不硬塞进错组
    static let minConfidence: Double = 0.15

    struct MainTagResult {
        var tag: String
        var conf: Double
        var probs: [String: Double]
        var portrait: Double
    }

    private var ladderEmbeddings: [String: [Float]] = [:]

    static var ladderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("labels_ladder.json")
    }

    private func ensureLadderEmbeddings() {
        var changed = false
        let all = Self.ladderPrompts.values.flatMap { $0 } + Self.otherPrompts +
                  Self.portraitPos + Self.portraitNeg
        for p in all where ladderEmbeddings[p] == nil {
            if let e = embedText(p) { ladderEmbeddings[p] = e; changed = true }
        }
        if changed, let d = try? JSONEncoder().encode(ladderEmbeddings) {
            try? d.write(to: Self.ladderURL)
        }
    }

    /// 图像 → 主标签（唯一归属）+ 置信度 + 各类概率 + 写真概率
    func classifyMain(_ image: CGImage) -> MainTagResult? {
        lazySetup()
        guard let imageModel else { return nil }
        ensureLadderEmbeddings()
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

        func best(_ prompts: [String]) -> Double {
            prompts.compactMap { ladderEmbeddings[$0].map { dot(v, $0) } }.max() ?? -1
        }
        // logits 用标准 CLIP 尺度（cosine x 100），softmax 后才有可比性
        var logits: [String: Double] = [:]
        for (name, prompts) in Self.ladderPrompts { logits[name] = best(prompts) * 100.0 }
        logits["其他"] = best(Self.otherPrompts) * 100.0

        let names = Array(logits.keys)
        let raw = names.map { logits[$0]! }
        let probsList = softmax(raw)
        var probs: [String: Double] = [:]
        for (i, n) in names.enumerated() { probs[n] = probsList[i] }

        var bestName = "其他", bestP = -1.0
        for (n, p) in probs where n != "其他" { if p > bestP { bestP = p; bestName = n } }

        let pos = Self.portraitPos.compactMap { ladderEmbeddings[$0].map { dot(v, $0) } }.max() ?? 0
        let neg = Self.portraitNeg.compactMap { ladderEmbeddings[$0].map { dot(v, $0) } }.max() ?? 0
        let pProbs = softmax([pos * 100.0, neg * 100.0])

        let tag = bestP >= Self.minConfidence ? bestName : "其他"
        return MainTagResult(tag: tag, conf: max(bestP, 0), probs: probs,
                             portrait: pProbs.first ?? 0)
    }

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
