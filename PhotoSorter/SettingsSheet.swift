import SwiftUI

/// 设置页：全部阈值滑杆 + 重新分级 + 清除数据
struct SettingsSheet: View {
    @EnvironmentObject var svc: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var groupSensitivity = 1.0   // 0 严格 / 1 适中 / 2 宽松

    var body: some View {
        NavigationView {
            Form {
                Section("暴露分级阈值") {
                    ThresholdSliderRow(title: "T1 最低人脸占比", value: $svc.thresholds.minFaceArea, range: 0.02...0.30)
                    ThresholdSliderRow(title: "T1 最低清晰度", value: $svc.thresholds.minSharpness, range: 0.1...0.9)
                    ThresholdSliderRow(title: "T2 肤色下限", value: $svc.thresholds.t2SkinLow, range: 0.05...0.40)
                    ThresholdSliderRow(title: "T2 上限 / T3 下限（肤色）", value: $svc.thresholds.t2SkinHigh, range: 0.30...0.70)
                }

                Section("好看程度分界") {
                    ThresholdSliderRow(title: "「好看-高」分数线", value: $svc.thresholds.goodHigh, range: 0.5...0.95)
                    ThresholdSliderRow(title: "「好看-中」分数线", value: $svc.thresholds.goodMid, range: 0.2...0.7)
                }

                Section("成组灵敏度（同一套写真的合并松紧）") {
                    Picker("灵敏度", selection: $groupSensitivity) {
                        Text("严格（不易误合并）").tag(0.0)
                        Text("适中（推荐）").tag(1.0)
                        Text("宽松（更易合并）").tag(2.0)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Button("应用并重新分级（秒级，不重新读图）") {
                        applyGroupSensitivity()
                        svc.reclassify()
                        dismiss()
                    }
                    .disabled(svc.photos.isEmpty)
                } footer: {
                    Text("改成分级阈值后点这里立即生效；改了成组灵敏度则需要重新扫描才能重新成组。")
                }

                Section("数据") {
                    Button("清除全部分析数据（照片不受影响）", role: .destructive) {
                        svc.clearAllData()
                        dismiss()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                groupSensitivity = nearestSensitivity()
            }
        }
    }

    private func nearestSensitivity() -> Double {
        let t = svc.thresholds
        if abs(t.groupMedium - t.groupStrict) < 1.0 { return 0 }
        if abs(t.groupMedium - t.groupLoose) < 1.0 { return 2 }
        return 1
    }

    private func applyGroupSensitivity() {
        switch groupSensitivity {
        case 0: svc.thresholds.groupStrict = svc.thresholds.groupMedium - 2
        case 2: svc.thresholds.groupLoose = svc.thresholds.groupMedium + 3
        default: break
        }
    }
}
