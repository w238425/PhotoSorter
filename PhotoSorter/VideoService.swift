import AVFoundation
import Photos

/// 视频服务：元数据分类（零成本）+ 抽帧深度分析（按需触发）
final class VideoService {

    static let shared = VideoService()

    // MARK: - 元数据（瞬时完成）

    func metadata(for asset: PHAsset) -> VideoItem {
        let resources = PHAssetResource.assetResources(for: asset)
        var size: Int64 = 0
        for r in resources where r.type == .video || r.type == .fullSizeVideo {
            if let s = r.value(forKey: "fileSize") as? Int64 { size = s }
        }
        return VideoItem(
            id: asset.localIdentifier,
            duration: asset.duration,
            fileSize: size,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    // MARK: - 抽帧深度分析（裸露度取全部帧最高档 + 稳定度）

    /// 抽 frames 帧，回调 (最高肤色占比, 稳定度0~1)
    func deepAnalyze(asset: PHAsset, frames: Int = 12,
                     completion: @escaping (Double, Double) -> Void) {
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.version = .current
        opts.deliveryMode = .automatic

        PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
            guard let asset = avAsset else {
                DispatchQueue.main.async { completion(-1, -1) }
                return
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 256, height: 256)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            let duration = CMTimeGetSeconds(asset.duration)
            guard duration > 0 else {
                DispatchQueue.main.async { completion(-1, -1) }
                return
            }

            var skins: [Double] = []
            var grays: [[UInt8]] = []
            let lock = NSLock()

            for k in 0..<frames {
                let sec = duration * Double(k + 1) / Double(frames + 1)
                let time = NSValue(time: CMTime(seconds: sec, preferredTimescale: 600))
                gen.generateCGImagesAsynchronously(forTimes: [time]) { _, cgImage, _, _, _ in
                    if let cg = cgImage {
                        let skin = AestheticAnalyzer.skinRatio(of: cg)
                        let gray = AestheticAnalyzer.grayPixels(cg, side: 32) ?? []
                        lock.lock()
                        skins.append(skin)
                        grays.append(gray)
                        lock.unlock()
                    }
                }
            }

            // 等所有帧出来（generateCGImagesAsynchronously 是异步串行回调）
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(frames) * 0.5 + 2.0) {
                lock.lock()
                let skin = skins.max() ?? -1
                var diffs: [Double] = []
                for i in 1..<grays.count {
                    diffs.append(AestheticAnalyzer.meanAbsDiff(grays[i - 1], grays[i]))
                }
                lock.unlock()
                let stability = diffs.isEmpty ? 1.0
                    : max(0, 1.0 - (diffs.reduce(0, +) / Double(diffs.count)) / 60.0)
                DispatchQueue.main.async { completion(skin, stability) }
            }
        }
    }

    // MARK: - 视频好看分

    func aestheticScore(_ v: VideoItem) -> Double {
        var q: Double = 0
        switch v.qualityTier {
        case "4K": q = 1.0
        case "1080p": q = 0.8
        case "720p": q = 0.5
        default: q = 0.2
        }
        // 码率加成（>12Mbps 视为高码率）
        let bitrateBonus = min(v.bitrateMbps / 12.0, 1.0) * 0.2
        let stability = v.stability >= 0 ? v.stability : 0.8
        return min(q * 0.6 + bitrateBonus + stability * 0.2, 1.0)
    }

    // MARK: - 查重（时长+体积+首帧相似）

    func isLikelyDuplicate(_ a: VideoItem, _ b: VideoItem) -> Bool {
        abs(a.duration - b.duration) < 0.5 && a.fileSize == b.fileSize
    }
}
