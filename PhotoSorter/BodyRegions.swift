import Vision
import UIKit
import CoreImage

/// 用 Apple 原生 Vision 做人体定位：姿态关节 + 人物分割掩码。
///
/// 存在的意义：CLIP 是 224×224 全局语义模型，黑丝、开裆、胸罩这类
/// 只占画面百分之几的细节，缩到 224 后就消失了。把关节拿出来裁成
/// 局部区域再单独编码，等于给 CLIP 装了一个放大镜。
///
/// 人物分割掩码则用来把肤色统计限定在人身上——否则米白墙、暖光、
/// 肉色衣服都会把裸露度顶上去，组内排序自然就乱了。
struct BodyRegions {
    /// 原图坐标系（左上原点，像素单位）
    var upper: CGRect? = nil    // 肩 → 髋
    var lower: CGRect? = nil    // 髋 → 踝
    var crotch: CGRect? = nil  // 髋部小框，专供开裆判定
    var legs: CGRect? = nil    // 膝 → 踝，收紧到双腿宽度，专给丝袜看

    var hasBody: Bool { upper != nil || lower != nil }
}

final class BodyRegionDetector {

    static let shared = BodyRegionDetector()

    struct Detection {
        var regions: BodyRegions?
        var personMask: CGImage?      // 单通道掩码，1=人
        /// 只在人物掩码内统计的肤色比例（0~1）。无人检测时回退整图
        var skinInPerson: Double?
        var personArea: Double
    }

    /// pose 关节置信度门槛，低于此值的关节不参与构图
    private let jointMinConfidence: Float = 0.25

    func detect(_ image: CGImage) -> Detection {
        let w = image.width
        let h = image.height
        var regions: BodyRegions?
        var personArea: Double = 0

        // 1. 人体姿态：拿肩/髋/膝/踝
        let poseReq = VNDetectHumanBodyPoseRequest()
        let segReq = VNGeneratePersonSegmentationRequest()
        segReq.qualityLevel = .accurate
        segReq.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([poseReq, segReq])
        } catch {
            // 姿态失败仍尝试分割
            _ = try? handler.perform([segReq])
        }

        if let obs = poseReq.results?.first {
            regions = Self.buildRegions(from: obs, width: w, height: h,
                                        minConf: jointMinConfidence)
        }

        // 2. 人物掩码
        var maskImage: CGImage?
        if let result = segReq.results?.first,
           let buf = result.pixelBuffer {
            maskImage = Self.cgImage(fromMask: buf)
            personArea = Self.maskCoverage(buf)
        }

        // 3. 掩码约束下的肤色比例
        var skin: Double?
        if let maskImage {
            skin = Self.skinRatio(in: image, mask: maskImage)
        }

        return Detection(regions: regions, personMask: maskImage,
                         skinInPerson: skin, personArea: personArea)
    }

    // MARK: - 关节 → 区域框

    private static func buildRegions(from obs: VNHumanBodyPoseObservation,
                                     width: Int, height: Int,
                                     minConf: Float) -> BodyRegions? {
        func pt(_ j: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            // 置信度过滤：Vision 会给不可见关节一个低分位置
            guard let p = try? obs.recognizedPoint(j), p.confidence >= minConf else { return nil }
            // Vision normalized 原点在左下，转成左上原点像素坐标
            return CGPoint(x: p.location.x * CGFloat(width),
                           y: (1 - p.location.y) * CGFloat(height))
        }

        let lSh = pt(.leftShoulder), rSh = pt(.rightShoulder)
        let lHip = pt(.leftHip), rHip = pt(.rightHip)
        let lKnee = pt(.leftKnee), rKnee = pt(.rightKnee)
        let lAnk = pt(.leftAnkle), rAnk = pt(.rightAnkle)
        let neck = pt(.neck)

        func mid(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
            switch (a, b) {
            case let (x?, y?): return CGPoint(x: (x.x + y.x) / 2, y: (x.y + y.y) / 2)
            case let (x?, nil): return x
            case let (nil, y?): return y
            case (nil, nil): return nil
            }
        }

        let shoulderY = mid(lSh, rSh)?.y
        let hip = mid(lHip, rHip)
        let ankle = mid(lAnk, rAnk)
        let knee = mid(lKnee, rKnee)

        var boxes = BodyRegions()

        // 上身：肩线到髋线，横向按肩宽外扩
        if let sy = shoulderY, let hip {
            let shW = max(abs((lSh?.x ?? hip.x) - (rSh?.x ?? hip.x)), CGFloat(width) * 0.12)
            let top = (neck?.y ?? sy) - shW * 0.35
            let bottom = hip.y
            if bottom > top {
                boxes.upper = clamp(CGRect(x: hip.x - shW * 0.95, y: top,
                                           width: shW * 1.9, height: bottom - top),
                                   width: width, height: height)
            }
        }

        // 下身：髋到踝，含全部腿部与鞋
        if let hip {
            let bottomY = ankle?.y ?? knee?.y ?? CGFloat(height)
            if bottomY > hip.y {
                let hipW = max(abs((lHip?.x ?? hip.x) - (rHip?.x ?? hip.x)), CGFloat(width) * 0.12)
                boxes.lower = clamp(CGRect(x: hip.x - hipW * 1.1, y: hip.y,
                                           width: hipW * 2.2, height: bottomY - hip.y),
                                    width: width, height: height)
            }
        }

        // 腿：膝到踝，收紧到双腿宽度，专给丝袜看
        if let knee, let ankle {
            let top = min(knee.y, ankle.y)
            let bottom = max(knee.y, ankle.y)
            let legW = max(abs((lKnee?.x ?? knee.x) - (rKnee?.x ?? knee.x)), CGFloat(width) * 0.10)
            let pad = legW * 0.6
            boxes.legs = clamp(CGRect(x: knee.x - legW / 2 - pad, y: top,
                                      width: legW + pad * 2, height: max(bottom - top, 8)),
                               width: width, height: height)
        }

        // 裆部：髋线附近的小方块，开裆判定专用
        if let hip {
            let s = CGFloat(min(width, height)) * 0.16
            boxes.crotch = clamp(CGRect(x: hip.x - s * 0.75, y: hip.y - s * 0.45,
                                        width: s * 1.5, height: s * 1.1),
                                 width: width, height: height)
        }

        return (boxes.upper != nil || boxes.lower != nil) ? boxes : nil
    }

    private static func clamp(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let x = max(0, min(r.minX, CGFloat(width) - 1))
        let y = max(0, min(r.minY, CGFloat(height) - 1))
        let w = max(8, min(r.width, CGFloat(width) - x))
        let h = max(8, min(r.height, CGFloat(height) - y))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - 掩码处理

    private static func cgImage(fromMask buf: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buf)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(ci, from: ci.extent)
    }

    /// 掩码覆盖率（人物占画面比例）
    private static func maskCoverage(_ buf: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return 0 }
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let step = max(1, w / 128)          // 采样，不必逐像素
        var hit = 0
        var total = 0
        for y in stride(from: 0, to: h, by: max(1, h / 128)) {
            let row = base.advanced(by: y * stride)
            for x in stride(from: 0, to: w, by: step) {
                total += 1
                if row.load(fromByteOffset: x, as: UInt8.self) > 128 { hit += 1 }
            }
        }
        return total > 0 ? Double(hit) / Double(total) : 0
    }

    /// 在人物掩码内统计肤色比例。
    /// 掩码把背景、家具、墙面全部排除，这是裸露度可信的前提。
    private static func skinRatio(in image: CGImage, mask: CGImage) -> Double? {
        let w = 160, h = 160
        var imgBytes = [UInt8](repeating: 0, count: w * h * 4)
        var mskBytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ci = CGContext(data: &imgBytes, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cm = CGContext(data: &mskBytes, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ci.interpolationQuality = .low
        cm.interpolationQuality = .low
        ci.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        cm.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hit = 0, total = 0
        for i in 0..<(w * h) {
            // 掩码是灰度图，画进 RGB 后取 R 通道即可
            guard mskBytes[i * 4] > 128 else { continue }
            total += 1
            let r = Double(imgBytes[i * 4]) / 255.0
            let g = Double(imgBytes[i * 4 + 1]) / 255.0
            let b = Double(imgBytes[i * 4 + 2]) / 255.0
            if isSkin(r: r, g: g, b: b) { hit += 1 }
        }
        // 人物太小说明分割不可靠，交回给调用方走别的路径
        guard total >= 200 else { return nil }
        return Double(hit) / Double(total)
    }

    /// YCrCb 经典肤色区间 + RGB 经验规则的折中：宁可漏，不可把米黄墙面算成皮肤
    private static func isSkin(r: Double, g: Double, b: Double) -> Bool {
        let mx = max(r, g, b), mn = min(r, g, b)
        let v = mx
        let s = mx > 0 ? (mx - mn) / mx : 0
        guard v >= 0.30, v <= 0.98, s >= 0.12, s <= 0.62 else { return false }
        // 肤色要求 R > G > B 且差距适中
        guard r > g, g > b else { return false }
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cr = (r - y) * 0.713 + 0.5
        let cb = (b - y) * 0.564 + 0.5
        return cr >= 0.52 && cr <= 0.63 && cb >= 0.36 && cb <= 0.49
    }
}
