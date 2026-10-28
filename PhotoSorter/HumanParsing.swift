import CoreML
import UIKit
import Accelerate

/// SegFormer-B2 人体解析（ATR 18 类，512 输入 → 128×128 logits）
///
/// 这是分类准确率的地基：有了像素级的「哪里是衣服、哪里是皮肤」，
/// 裸露度就不用靠肤色比例去猜，黑丝/开裆/无胸罩也能用几何证据判定，
/// 而不是让 CLIP 在 224×224 的整图里盲猜一个只占画面 2% 的细节。
///
/// 模型缺失时 available == false，调用方回退到 Vision 方案，不影响出包。
final class HumanParsing {

    static let shared = HumanParsing()

    static let inputSize = 512
    static let numClasses = 18
    static let outSize = 128

    /// ATR-18 类别编号（与 mattmdjaga/segformer_b2_clothes 输出一致）
    enum C: UInt8 {
        case background = 0
        case hat = 1
        case hair = 2
        case sunglasses = 3
        case upper = 4      // 上衣
        case skirt = 5
        case pants = 6
        case dress = 7
        case belt = 8
        case lshoe = 9
        case rshoe = 10
        case face = 11
        case lleg = 12      // 左腿（裸腿，穿丝袜时常被判 pants）
        case rleg = 13
        case larm = 14
        case rarm = 15
        case bag = 16
        case scarf = 17
    }

    /// 算作「穿着」的类别（判裸皮时要剔除）
    static let clothingSet: Set<UInt8> = [
        C.hat.rawValue, C.sunglasses.rawValue, C.upper.rawValue,
        C.skirt.rawValue, C.pants.rawValue, C.dress.rawValue, C.belt.rawValue,
        C.lshoe.rawValue, C.rshoe.rawValue, C.bag.rawValue, C.scarf.rawValue
    ]

    struct Result {
        /// 128×128 类别图（行优先）
        var clsMap: [UInt8]
        var personArea: Double      // 人物占整幅画面比例
        var exposure: Double        // 裸皮 / 人物面积
        var faceRatio: Double
        var legRatio: Double        // 裸腿 / 人物
        var armRatio: Double
        var upperRatio: Double      // 上衣+裙子 / 人物
        var pantsRatio: Double      // 裤子+半裙 / 人物
        var shoeRatio: Double
        /// 裸腿区域 HSV 明度均值（0~1）。黑丝会让这个值显著变暗
        var legBrightness: Double? = nil
        /// 腰线以下全部区域（裸腿 + 裤子 + 半裙）的明度均值。
        /// 丝袜常被解析器判成 pants，所以黑丝判定必须看这个而不是 legBrightness
        var lowerBrightness: Double? = nil
    }

    private var model: MLModel?
    private(set) var available = false
    private var didSetup = false

    private init() {}

    private func setup() {
        guard !didSetup else { return }
        didSetup = true
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let url = Bundle.main.url(forResource: "HumanParsing", withExtension: "mlmodelc")
                     ?? Bundle.main.url(forResource: "HumanParsing", withExtension: "mlmodel"),
              let m = try? MLModel(contentsOf: url, configuration: cfg) else { return }
        model = m
        available = true
    }

    /// 解析一张图。传入的 image 建议已缩到 1024 以内（内部再缩到 512）
    func parse(_ image: CGImage) -> Result? {
        setup()
        guard available, let model else { return nil }
        guard let buf = try? MLFeatureValue(cgImage: image,
                                            pixelsWide: Self.inputSize,
                                            pixelsHigh: Self.inputSize,
                                            pixelFormatType: kCVPixelFormatType_32ARGB,
                                            options: nil).imageBufferValue else { return nil }
        guard let prov = try? MLDictionaryFeatureProvider(
                dictionary: ["pixel_values": MLFeatureValue(pixelBuffer: buf)]),
              let out = try? model.prediction(from: prov) else { return nil }

        // 输出名在不同转换配置下可能是 logits / var_xxx，做一次兼容查找
        guard let arr = Self.pickArray(from: out) else { return nil }
        let n = Self.outSize
        guard arr.count >= Self.numClasses * n * n else { return nil }

        // 快路径：连续内存直接读，避免 29 万次 NSNumber 拆箱
        var logits: [Float]
        if let p = Self.contiguousPointer(arr, count: Self.numClasses * n * n) {
            logits = Array(UnsafeBufferPointer(start: p, count: Self.numClasses * n * n))
        } else {
            logits = (0..<(Self.numClasses * n * n)).map { arr[$0].floatValue }
        }

        var clsMap = [UInt8](repeating: 0, count: n * n)
        var person = 0
        var exposed = 0
        var counts = [Int](repeating: 0, count: Self.numClasses)

        for pixel in 0..<(n * n) {
            var best = 0
            var bestV = logits[pixel]
            for c in 1..<Self.numClasses {
                let v = logits[c * n * n + pixel]
                if v > bestV { bestV = v; best = c }
            }
            clsMap[pixel] = UInt8(best)
            counts[best] += 1
            if best != C.background.rawValue {
                person += 1
                let isCloth = Self.clothingSet.contains(UInt8(best))
                let isHair = best == C.hair.rawValue
                let isFace = best == C.face.rawValue
                if !isCloth && !isHair && !isFace { exposed += 1 }
            }
        }

        let personD = Double(max(person, 1))
        let totalD = Double(n * n)
        func ratio(_ ids: [Int]) -> Double {
            Double(ids.reduce(0) { $0 + counts[$1] }) / personD
        }

        var r = Result(clsMap: clsMap,
                       personArea: Double(person) / totalD,
                       exposure: Double(exposed) / personD,
                       faceRatio: ratio([Int(C.face.rawValue)]),
                       legRatio: ratio([Int(C.lleg.rawValue), Int(C.rleg.rawValue)]),
                       armRatio: ratio([Int(C.larm.rawValue), Int(C.rarm.rawValue)]),
                       upperRatio: ratio([Int(C.upper.rawValue), Int(C.dress.rawValue)]),
                       pantsRatio: ratio([Int(C.pants.rawValue), Int(C.skirt.rawValue)]),
                       shoeRatio: ratio([Int(C.lshoe.rawValue), Int(C.rshoe.rawValue)]))
        r.legBrightness = Self.regionBrightness(image, mask: clsMap,
                                               ids: [C.lleg.rawValue, C.rleg.rawValue])
        r.lowerBrightness = Self.regionBrightness(image, mask: clsMap,
                                                   ids: [C.lleg.rawValue, C.rleg.rawValue,
                                                         C.pants.rawValue, C.skirt.rawValue])
        return r
    }

    // MARK: - 辅助

    private static func pickArray(from out: MLFeatureProvider) -> MLMultiArray? {
        if let v = out.featureValue(for: "logits")?.multiArrayValue { return v }
        for name in out.featureNames {
            if let v = out.featureValue(for: name)?.multiArrayValue,
               v.count >= numClasses * outSize * outSize { return v }
        }
        return nil
    }

    /// 若 MLMultiArray 是 C 序连续内存，返回可直接遍历的指针
    private static func contiguousPointer(_ arr: MLMultiArray, count: Int) -> UnsafePointer<Float>? {
        guard arr.dataType == .float32 else { return nil }
        let shape = arr.shape.map { $0.intValue }
        guard !shape.isEmpty else { return nil }
        var expected = 1
        for d in shape { expected *= d }
        guard expected == count else { return nil }
        // 校验 strides 是否为行优先连续，不是就退回安全但慢的逐点读取
        var stride = 1
        var i = shape.count - 1
        while i >= 0 {
            if arr.strides[i].intValue != stride { return nil }
            stride *= shape[i]
            i -= 1
        }
        let raw = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        return UnsafePointer<Float>(raw)
    }

    /// 指定类别区域的 HSV 明度均值（0~1）
    private static func regionBrightness(_ image: CGImage, mask: [UInt8],
                                         ids: [UInt8]) -> Double? {
        let n = outSize
        var count = 0
        for v in mask where ids.contains(v) { count += 1 }
        guard count >= 500 else { return nil }

        // 把原图缩到 128×128 取 RGB，再逐点算 V = max(R,G,B)
        guard let small = resizeToRGB(image, width: n, height: n) else { return nil }
        var sum: Double = 0
        var used = 0
        for i in 0..<(n * n) where ids.contains(mask[i]) {
            let r = Double(small[i * 3]) / 255.0
            let g = Double(small[i * 3 + 1]) / 255.0
            let b = Double(small[i * 3 + 2]) / 255.0
            sum += max(r, g, b)
            used += 1
        }
        return used > 0 ? sum / Double(used) : nil
    }

    /// 缩放到指定尺寸并输出行优先 RGB 字节
    private static func resizeToRGB(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = bytes[i * 4]
            rgb[i * 3 + 1] = bytes[i * 4 + 1]
            rgb[i * 3 + 2] = bytes[i * 4 + 2]
        }
        return rgb
    }
}
