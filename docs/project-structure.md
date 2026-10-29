# 项目目录与文件规范

本规范描述当前原生工程的文件归属和维护方式。新增、移动或清理文件前，先确认文件用途、引用和工作区中的现有修改。

## 文件放在哪里

| 路径 | 职责 |
| --- | --- |
| `README.md` | 项目介绍、快速开始和文档入口。 |
| `docs/USAGE.md` | 日常使用、数据口径、存储和故障恢复。 |
| `PRODUCT.md`、`DESIGN.md` | 分别维护产品范围和界面规范。 |
| `GLOSSARY.md` | 维护领域术语。 |
| `docs/VALIDATION.md` | 维护带验证范围的结果。 |
| `docs/release.md`、`docs/releases/`、`.github/workflows/`、`tools/release/` | 分别维护发布规范、各版本面向用户的说明、GitHub Actions 流程及发布工具。 |
| `AGENTS.md`、`docs/agents/` | 协作入口及按需读取的任务规则。 |
| `AirportMonitor.xcodeproj/`、`Package.swift`、`AirportMonitor.entitlements` | 原生应用、Swift Package 与权限配置。 |
| `Sources/Core/` | 订阅读取、采样、统计、预测和提醒规则等核心逻辑；不依赖原生界面。 |
| `Sources/App/` | 原生界面、应用状态、本地存储、钥匙串和通知交付。 |
| `Sources/App/Application/`、`Workspace/`、`Settings/` | 分别负责应用启动与单实例、主窗口与机场编辑、设置页面。 |
| `Sources/App/MenuBar/`、`Presentation/` | 分别负责菜单栏面板与图标、共享展示和界面控件。 |
| `Sources/App/Monitoring/`、`Storage/` | 分别负责监测与提醒交付、本地存储及钥匙串。 |
| `Sources/App/Review/` | 应用内的隔离预览、验证数据和导航基准工具。 |
| `Sources/App/Assets.xcassets/` | 应用构建使用的图标与其他资源。 |
| `Tests/CoreTests/`、`Tests/NativeModelTests/` | 分别验证核心逻辑和原生模型；共享测试辅助代码位于 `Tests/NativeModelTests/Support/`，数据样本位于 `Tests/NativeModelTests/Fixtures/`。 |
| `Design/Branding/` | 品牌原稿和资源导出工具；界面规则以 `DESIGN.md` 为准。 |
| `docs/adr/`、`docs/images/` | 分别保存重要决策和文档使用的图片。 |
| `tools/` | 独立的开发和验证工具，按用途分目录。 |
| `.scratch/<feature>/` | 进行中的本地任务记录，按[任务记录规则](agents/issue-tracker.md)使用。 |

用户的订阅、历史和运行时偏好保存在应用的数据位置，详见[使用说明](USAGE.md#隐私存储与故障恢复)。测试样本和文档截图使用合成或脱敏数据。

## 命名与新增

- 延续现有目录大小写：`Sources/`、`Tests/`、`Design/` 使用大写开头，`docs/` 和 `tools/` 使用小写。
- `Sources/` 下的 Swift 文件按主要类型或职责使用 `UpperCamelCase.swift`；测试文件使用 `<Subject>Tests.swift`。相关小类型可放在同一文件，不为单个声明强制拆文件。
- 新增普通文档和脚本优先使用小写连字符命名；已有文档的名称和路径保持稳定。ADR 使用 `NNNN-kebab-case.md`。
- 新增文档先选择已有职责归属，避免为同一事实维护多份副本。产品介绍放 `README.md`，详细口径放 `docs/USAGE.md`，设计规则放 `DESIGN.md`，验证结果放 `docs/VALIDATION.md`。
- Xcode 的 `Sources/` 是同步分组；新增、移动或删除源码时，检查应用构建及 `Package.swift` 中 `NativeModels` 的 `sources`／`exclude` 是否仍准确。新测试样本放在对应测试目标的 `Fixtures/`，并按需在 `Package.swift` 声明资源。
- 图标的不同尺寸与倍率按 `Contents.json` 分别保留，即使文件内容相同；替换品牌原稿时按 `Design/Branding/README.md` 同步生成资源。

## 临时文件与清理

- `.scratch/` 按需创建，默认不纳入 Git；任务记录的保留与清理见[任务记录规则](agents/issue-tracker.md)。
- 构建产物、测试输出、应用副本和日志优先放在项目外的临时目录。正式文档、测试样本和构建所需资源保留在项目内。
- `.build/`、`.serena/`、`.codegraph/` 等可能包含正在使用的构建或搜索索引；清理前确认用途，遵守用户的保留要求，不隐式删除或重建。
- 清理前同时检查已跟踪、未跟踪和被忽略的文件及引用；未跟踪并不代表无用。可恢复地移除已确认无用的内容，清理后检查相关链接和资源。
