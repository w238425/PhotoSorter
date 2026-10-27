# 写真分类助手 — 从源码到装上 iPhone 全流程教程

> 源码位置：`PhotoSorter/PhotoSorter/` 目录（12 个 Swift 文件，纯原生，无第三方依赖）

## 一、功能总览

| 页面 | 功能 |
|---|---|
| 扫描 | 授权 → 勾选相册（含 iCloud 共享相册）→ 粗筛分析 + 成组 + 分级 + 部位 |
| 套图 | 按套浏览（同一套写真永不拆散），长按照片移入其他套/移出/改分级 |
| 分类 | 按 分级 / 部位 / 好看 / 肤色 四维度浏览，长按显示分数与手动调整 |
| 视频 | 大小/画质/时长/码率排序；按需抽帧深度分析裸露度+稳定度 |
| 输出 | ① 按套/分级/好看/肤色生成引用相册 ② 重复照片检测+确认删除 ③ 半自动导出到共享相册（系统分享面板） |
| 设置 | 全部阈值滑杆、成组灵敏度三档、一键重新分级、清除数据 |

## 二、Xcode 建项目（Mac 上操作，约 3 分钟）

1. App Store 安装 **Xcode**（免费）
2. Xcode → File → New → Project → **iOS / App**，Product Name 填 `PhotoSorter`，Interface 选 **SwiftUI**，Language **Swift**，创建到任意目录
3. 删除项目里自带的 `ContentView.swift` 和 `<项目名>App.swift`
4. 把 `PhotoSorter/PhotoSorter/` 文件夹里的 **12 个 .swift 文件全部拖进** Xcode 左侧项目导航器（勾选 "Copy items if needed"，Target 勾选 PhotoSorter）
5. 添加权限描述（关键，不加会闪退）：
   - 左侧点蓝色项目图标 → TARGETS → PhotoSorter → **Info** 标签
   - 点任意一行 "+" 添加：

   | Key | Value |
   |---|---|
   | `NSPhotoLibraryUsageDescription` | `读取相册照片用于本机分类整理，照片不会上传` |
   | `NSPhotoLibraryAddUsageDescription` | `创建分类相册` |

6. General → Minimum Deployments 选 **iOS 16.0**（骨骼关键点检测需要）
7. ⌘R 模拟器先跑一遍确认能启动

## 三、装到你的 iPhone（自签名）

### 方式 A：免费 Apple ID（7 天有效，到期重签）

1. Xcode → Settings → Accounts → "+" 登录你的 Apple ID
2. 项目 → TARGETS → Signing & Capabilities：
   - Team 选你的 Personal Team
   - Bundle Identifier 改成唯一的，如 `com.你的名字.photosorter2026`
3. iPhone 用数据线连 Mac → Xcode 顶部设备选你的 iPhone
4. iPhone 上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书
5. ⌘R 安装运行

### 方式 B：付费开发者账号（$99/年）

Team 选正式账号，同上步骤，或 TestFlight 分发，签名一年有效。

## 四、使用建议

1. 首次扫描先用**少量相册**试水（勾一个几十张的共享相册），看看分级/成组准不准
2. 不准 → 设置页拖阈值滑杆 → "应用并重新分级"（秒级）
3. 成组太散 → 灵敏度调"宽松"后**重新扫描**；误合并 → 调"严格"
4. 确认没问题后再全量扫描（约 1000 张 3~5 分钟）
5. 长按照片可纠错：移套 / 移出 / 改分级，全部永久记住

## 五、已知边界（苹果 API 限制，非 bug）

- 共享相册**只读**：不能在原相册内排序/删除/写入，输出走"引用相册"或"半自动导出"
- 共享相册里的照片查重后**删不了**（只能删你本人图库里的）
- 深度精评（高清图）与"仅分析已缓存"模式的取舍见 App 内设置说明
- 识别不到关节/人脸的照片归入"未判定"，需人工长按归类

## 六、文件清单

```
PhotoSorter/
├── 策划案.md                ← 完整产品策划案（所有规则的依据）
└── PhotoSorter/
    ├── PhotoSorterApp.swift 入口
    ├── Models.swift         数据模型/阈值/手动调整
    ├── AestheticAnalyzer.swift 分析引擎（清晰度/曝光/肤色/人脸/部位/指纹）
    ├── PhotoLibraryService.swift 相册服务（扫描/成组/分级/缓存/建相册/查重）
    ├── VideoService.swift   视频元数据+抽帧分析
    ├── ContentView.swift    五页 Tab 框架
    ├── ScanView.swift       扫描页
    ├── SetsView.swift       套图页
    ├── ClassifyView.swift   分类页
    ├── VideoView.swift      视频页
    ├── ExportView.swift     输出页
    ├── SettingsSheet.swift  设置页
    └── Common.swift         缩略图/徽章/分享面板/滑杆组件
```
