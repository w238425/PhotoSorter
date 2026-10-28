import SwiftUI
import Photos
import UIKit

/// 照片详情：加载原图（非缩略图），底部操作条支持复制/存储/分享/用其他 App 打开。
/// 点开不跳出 App —— iOS 没有跳转到「照片 App 里某一张」的公开接口。
struct PhotoDetailView: View {
    let ids: [String]
    let startID: String
    @EnvironmentObject var svc: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    @State private var image: UIImage?
    @State private var originalData: Data?
    @State private var uti: String?
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var toast = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 96)
            } else {
                ProgressView().tint(.white)
            }

            VStack(alignment: .leading) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    Spacer()
                    Text("\(index + 1) / \(ids.count)")
                        .font(.footnote).foregroundColor(.white.opacity(0.85))
                }
                .padding(.horizontal, 16)

                if let p = svc.photos[currentID] {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            tagPill(p.isPortrait ? "写真" : p.mainTag)
                            tagPill(p.part.rawValue)
                            tagPill("裸露 \(Int(p.exposure))")
                            if let sid = p.setID { tagPill("同套 \(sid)") }
                            if svc.overrides.tagOverride[currentID] != nil {
                                tagPill("已手动")
                            }
                            Spacer()
                            // 改分类：判错时手动纠正，同时训练对应类别的原型向量
                            Menu {
                                ForEach(ClothingLadder.orderedNames, id: \.self) { name in
                                    Button(name) { svc.setMainTag(name, for: currentID) }
                                }
                                if svc.overrides.tagOverride[currentID] != nil {
                                    Button("恢复自动判定") { svc.clearMainTagOverride(for: currentID) }
                                }
                            } label: {
                                Image(systemName: "tag")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(7)
                                    .background(Circle().fill(Color.white.opacity(0.18)))
                            }
                        }
                        Text(String(format: "质量 %.0f · 肤色 %.0f%% · 标签置信 %.0f%%",
                                    p.scores.aesthetic, p.scores.skinRatio * 100, p.tagConf * 100))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }

                Spacer()

                HStack(spacing: 0) {
                    action("square.and.arrow.up", "分享") { share() }
                    action("doc.on.doc", "复制") { copy() }
                    action("square.and.arrow.down", "存储") { save() }
                    action("star", "收藏") { favorite() }
                    action("eye.slash", "隐藏") { hide() }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 26)
                .background(
                    LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.6)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom))
            }

            if !toast.isEmpty {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.subheadline).foregroundColor(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .padding(.bottom, 130)
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 60).onEnded { v in
            if v.translation.width < -60 { next(1) }
            else if v.translation.width > 60 { next(-1) }
        })
        .onAppear {
            index = max(0, ids.firstIndex(of: startID) ?? 0)
            load()
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }

    private var currentID: String { ids.indices.contains(index) ? ids[index] : ids[0] }

    private func tagPill(_ t: String) -> some View {
        Text(t).font(.caption2)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.22)))
            .foregroundColor(.white)
    }

    private func action(_ icon: String, _ title: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 21))
                Text(title).font(.caption2)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
        }
    }

    private func next(_ d: Int) {
        let n = index + d
        guard n >= 0, n < ids.count else { return }
        index = n
        image = nil
        originalData = nil
        load()
    }

    // MARK: - 原图加载（拿原始文件字节，不是分析用的缩略图）

    private func load() {
        guard let asset = svc.assets[currentID] else { return }
        let opts = PHImageRequestOptions()
        opts.isNetworkAccessAllowed = true
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit, options: opts) { img, _ in
                self.image = img
            }
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: opts) { data, u, _, _ in
            self.originalData = data
            self.uti = u
        }
    }

    // MARK: - 操作

    private func share() {
        let items: [Any] = {
            if let d = originalData, let u = uti, let img = UIImage(data: d) { return [img, d as Any].compactMap { $0 } }
            if let d = originalData { return [d] }
            if let image { return [image] }
            return []
        }()
        guard !items.isEmpty else { flash("原图还在下载"); return }
        shareItems = items
        showShare = true
    }

    private func copy() {
        if let d = originalData, let u = uti {
            UIPasteboard.general.setData(d, forPasteboardType: u)
            flash("已复制原图（\(u)）")
        } else if let image {
            UIPasteboard.general.image = image
            flash("已复制图像")
        } else {
            flash("原图还在下载")
        }
    }

    private func save() {
        guard let image else { flash("原图还在下载"); return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        flash("已存储到「本地」")
    }

    private func favorite() {
        guard let asset = svc.assets[currentID] else { return }
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetChangeRequest(for: asset)
            req.isFavorite = !asset.isFavorite
        }) { ok, _ in
            DispatchQueue.main.async { flash(ok ? (asset.isFavorite ? "已取消收藏" : "已收藏") : "共享相册不支持修改") }
        }
    }

    private func hide() {
        svc.setHidden(currentID, true)
        flash("已在 App 内隐藏（照片仍在你相册里）")
    }

    private func flash(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { toast = "" }
    }
}
