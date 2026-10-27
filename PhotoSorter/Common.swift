import SwiftUI
import Photos
import UIKit

// MARK: - 缩略图

struct ThumbView: View {
    let asset: PHAsset
    var side: CGFloat = 110
    /// 给定时横向撑满、高度固定（相册卡片用）
    var fillHeight: CGFloat? = nil

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.92))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: fillHeight == nil ? side : nil, height: fillHeight ?? side)
        .frame(maxWidth: fillHeight == nil ? nil : .infinity)
        .clipped()
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .fast
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side * UIScreen.main.scale, height: side * UIScreen.main.scale),
            contentMode: .aspectFill, options: opts
        ) { img, _ in
            if let img { self.image = img }
        }
    }
}

// MARK: - 分级徽章

struct LevelBadge: View {
    let level: ExposureLevel
    var body: some View {
        Text(level.shortLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.85))
            .foregroundColor(.white)
            .clipShape(Capsule())
    }
    private var badgeColor: Color {
        switch level {
        case .normal: return .gray
        case .portrait: return .blue
        case .revealing: return .orange
        case .explicit: return .red
        }
    }
}

// MARK: - 系统分享面板（半自动导出共享相册）

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 数值滑杆行（设置页复用）

struct ThresholdSliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
