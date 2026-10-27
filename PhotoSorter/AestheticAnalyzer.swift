import UIKit
import Vision
import Photos

/// 单张图像分析引擎：清晰度、曝光、肤色（RGB+HSV 双规则）、人脸、
/// 骨骼关键点部位判定、特征指纹（成组用）、重滤镜标记。
/// 全部本机计算，照片不离开手机。
final class AestheticAnalyzer {

    static let shared = AestheticAnalyzer()

    // MARK: - 图像获取

    /// 按 PHAsset 渲染指定最长边的图，用于分析
    func image(for asset: PHAsset, maxPixel: CGFloat, allowNetwork: Bool) -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowNetwork
        options.resizeMode = .fast
        options.isSynchronous = false

        let scale = maxPixel / max(CGFloat(max(asset.pixelWidth, asset.pixelHeight)), 1)
        let target = CGSize(width: CGFloat(asset.pixelWidth) * scale,
                            height: CGFloat(asset.pixelHeight) * scale)

        var result: CGImage?
        let semaphore = DispatchSemaphore(value: 0)
        PHImageManager.default().requestImage(
            for: asset, targetSize: target,
            contentMode: .aspectFit, options: options
        ) { img, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded { result = img?.cgImage; semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }

    // MARK: - 分析入口

    func analyze(_ img: CGImage) -> PhotoScores {
        var s = PhotoScores()
        s.sharpness = Self.sharpness(of: img)
        s.exposureScore = Self.exposureScore(of: img)
        s.skinRatio = Self.skinRatio(of: img)
        s.hasFilter = Self.isHeavyFilter(img)

        let faces = Self.detectFaces(img)
        s.faceCount = faces.count
        if let biggest = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            let imgArea = Double(img.width * img.height)
            if imgArea > 0 { s.faceAreaRatio = Double(biggest.width * biggest.height) / imgArea }
        }
        s.aesthetic = Self.aestheticScore(from: s)
        return s
    }

    // MARK: - 清晰度（Laplacian 方差）

    static func sharpness(of image: CGImage) -> Double {
        guard let gray = grayPixels(image, side: 128), gray.count > 4 else { return 0 }
        let side = 128
        var lapSum = 0.0, lapSqSum = 0.0, count = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let i = y * side + x
                let lap = Double(4 * Int(gray[i])
                                 - Int(gray[i - 1]) - Int(gray[i + 1])
                                 - Int(gray[i - side]) - Int(gray[i + side]))
                lapSum += lap; lapSqSum += lap * lap; count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = lapSum / count
        let variance = lapSqSum / count - mean * mean
        return min(variance / 500.0, 1.0)
    }

    // MARK: - 曝光（平均亮度越接近 0.5 越好）

    static func exposureScore(of image: CGImage) -> Double {
        guard let gray = grayPixels(image, side: 64), !gray.isEmpty else { return 0 }
        let mean = gray.reduce(0) { $0 + Double($1) } / Double(gray.count) / 255.0
        return max(0, 1.0 - abs(mean - 0.5) * 2.2)
    }

    // MARK: - 肤色占比（RGB 阈值 + HSV 色相区间，取并集，抗滤镜）

    static func skinRatio(of image: CGImage) -> Double {
        guard let pixels = rgbPixels(image, side: 64), !pixels.isEmpty else { return 0 }
        var skin = 0
        for (r, g, b) in pixels {
            if isSkinRGB(r, g, b) || isSkinHSV(r, g, b) { skin += 1 }
        }
        return Double(skin) / Double(pixels.count)
    }

    static func isSkinRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let ri = Int(r), gi = Int(g), bi = Int(b)
        let maxc = max(ri, gi, bi), minc = min(ri, gi, bi)
        return r > 95 && g > 40 && b > 20
            && (maxc - minc) > 15
            && abs(ri - gi) > 15
            && ri > gi && ri > bi
    }

    static func isSkinHSV(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxc = max(rf, gf, bf), minc = min(rf, gf, bf)
        let v = maxc
        let delta = maxc - minc
        guard delta > 0.1, v > 0.25, v < 0.98 else { return false }
        var h: Double = 0
        if maxc == rf { h = 60 * ((gf - bf) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxc == gf { h = 60 * ((bf - rf) / delta + 2) }
        else { h = 60 * ((rf - gf) / delta + 4) }
        if h < 0 { h += 360 }
        // 肤色色相集中区 0°~50°，饱和度不太高（排除纯色布料）
        let s = delta / maxc
        return (h >= 0 && h <= 50) && s > 0.15 && s < 0.68
    }

    // MARK: - 重滤镜标记（饱和度异常偏高 / 极端单色）

    static func isHeavyFilter(_ image: CGImage) -> Bool {
        guard let px = rgbPixels(image, side: 64), !px.isEmpty else { return false }
        var satSum = 0.0
        for (r, g, b) in px {
            let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
            let maxc = max(rf, gf, bf), minc = min(rf, gf, bf)
            satSum += maxc > 0 ? (maxc - minc) / maxc : 0
        }
        let meanSat = satSum / Double(px.count)
        return meanSat > 0.82 || meanSat < 0.02
    }

    // MARK: - 人脸检测

    static func detectFaces(_ image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision2
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.boundingBox }
    }

    // MARK: - 部位判定（骨骼关键点规则，见策划案）

    func detectBodyParts(_ image: CGImage) -> [BodyPart] {
        var parts: [BodyPart] = []

        // 人体关键点
        var joints: Set<VNHumanBodyPoseObservation.JointName> = []
        let bodyReq = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([bodyReq])
        if let obs = bodyReq.results?.first {
            let names: [VNHumanBodyPoseObservation.JointName] = [
                .nose, .neck, .leftShoulder, .rightShoulder,
                .leftElbow, .rightElbow, .leftWrist, .rightWrist,
                .leftHip, .rightHip, .leftKnee, .rightKnee,
                .leftAnkle, .rightAnkle
            ]
            for n in names {
                if let p = try? obs.recognizedPoint(n), p.confidence > 0.3 { joints.insert(n) }
            }
        }

        // 手部关键点
        var hasHand = false
        let handReq = VNDetectHumanHandPoseRequest()
        handReq.maximumHandCount = 2
        try? handler.perform([handReq])
        if let handObs = handReq.results, !handObs.isEmpty {
            for o in handObs {
                let count = (try? o.recognizedPoints(.all))?.values.filter { $0.confidence > 0.3 }.count ?? 0
                if count >= 3 { hasHand = true }
            }
        }

        let faces = Self.detectFaces(image)
        let faceArea: Double
        if let biggest = faces.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            faceArea = Double(biggest.width * biggest.height) / Double(image.width * image.height)
        } else { faceArea = 0 }
        let hasFace = !faces.isEmpty
        let faceBig = faceArea >= 0.25

        let hasShoulders = joints.contains(.leftShoulder) || joints.contains(.rightShoulder)
            || joints.contains(.leftElbow) || joints.contains(.rightElbow)
            || joints.contains(.leftWrist) || joints.contains(.rightWrist)
        let hasHips = joints.contains(.leftHip) || joints.contains(.rightHip)
            || joints.contains(.leftKnee) || joints.contains(.rightKnee)
        let hasAnkles = joints.contains(.leftAnkle) || joints.contains(.rightAnkle)

        if faceBig && !hasShoulders && !hasHips && !hasAnkles {
            parts.append(.face)
        }
        if hasHand && !hasFace {
            parts.append(.hand)
        }
        if hasFace && hasShoulders && !hasHips && !hasAnkles {
            parts.append(.upper)
        }
        if !hasFace && (hasHips || hasAnkles) && !hasShoulders {
            if hasHips { parts.append(.lower) }
            if hasAnkles && !hasHips { parts.append(.feet) }
        }
        if hasFace && hasAnkles {
            parts.append(.full)
        }
        if parts.isEmpty { parts.append(.undetermined) }
        return parts
    }

    // MARK: - 特征指纹（成组用）

    func featurePrint(_ image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            if let obs = request.results?.first as? VNFeaturePrintObservation {
                return try obs.data
            }
        } catch { }
        return nil
    }

    /// 指纹距离：0 完全相同，越小越相似（指纹以 Data 持久化，用时反序列化）
    static func distance(_ a: Data, _ b: Data) -> Float {
        guard let oa = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a)) as? VNFeaturePrintObservation,
              let ob = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b)) as? VNFeaturePrintObservation else { return .greatestFiniteMagnitude }
        var d: Float = 0
        do { try oa.computeDistance(&d, to: ob) } catch { return .greatestFiniteMagnitude }
        return d
    }

    // MARK: - 颜值综合分

    static func aestheticScore(from s: PhotoScores) -> Double {
        let sharp = s.sharpness
        let expo = s.exposureScore
        let faceSize = min(s.faceAreaRatio / 0.15, 1.0)
        let hasFace: Double = s.faceCount >= 1 ? 1.0 : 0.0
        return sharp * 0.35 + expo * 0.25 + faceSize * 0.25 + hasFace * 0.15
    }

    // MARK: - 像素工具（公开供视频抽帧复用）

    static func grayPixels(_ image: CGImage, side: Int) -> [UInt8]? {
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: buf, count: side * side))
    }

    static func rgbPixels(_ image: CGImage, side: Int) -> [(UInt8, UInt8, UInt8)]? {
        let bytesPerRow = side * 4
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        var out: [(UInt8, UInt8, UInt8)] = []
        out.reserveCapacity(side * side)
        for i in stride(from: 0, to: bytesPerRow * side, by: 4) {
            out.append((buf[i], buf[i + 1], buf[i + 2]))
        }
        return out
    }

    /// 两组灰度像素的平均绝对差（视频稳定度用）
    static func meanAbsDiff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in 0..<a.count { sum += Double(abs(Int(a[i]) - Int(b[i]))) }
        return sum / Double(a.count)
    }
}
