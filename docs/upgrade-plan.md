# 现代化改造方案（0.0.x → 主流形态）

> 流程：调研开源方案 → 评估匹配度 → 输出适配方案 → 落地。
> 调研方式：Tavily 检索 + 读源码/文档，2026-11-23。

## 一、调研：同类项目的标准答案是什么

| 关注点 | 主流做法（开源方案） | 关键事实 |
|---|---|---|
| 状态管理 | SwiftUI `@Observable` 宏（macOS 14+）替代 `ObservableObject` + `@Published` | Apple 官方迁移指南；Antoine van der Lee 实测重绘次数明显下降；Jesse Squires 提醒：它不是 drop-in，`@Bindable` / `Environment` 用法要一起改 |
| 菜单栏 | `NSStatusItem`（或 SwiftUI `MenuBarExtra`） | 与我们的实现一致 |
| 全局热键 | `sindresorhus/KeyboardShortcuts` | 支持沙盒与 App Store，自带「录制快捷键」UI 和用户自定义，内部仍用 Carbon/事件源，不需要辅助功能权限 |
| 自动更新 | `Sparkle 2` | 支持 SPM；ed25519 签名 + `appcast.xml`；**前提是 Developer ID 签名并公证**，ad-hoc 更新会被 Gatekeeper 拦 |
| 本地库 | `GRDB.swift` / `SQLiteData`（以及 SwiftData） | GRDB 对 FTS5、加密、SwiftUI 集成是一等公民；SwiftData 的全文检索能力弱，社区普遍不建议用于搜索重的场景 |
| 工程与构建 | Xcode 工程（或 Swift Bundler 这类 SwiftPM 打包器） | SwiftPM 能做 GUI app，但签名/归档/公证/资源处理仍以 Xcode 工程最顺 |
| 签名与分发 | Developer ID + `notarytool` + `stapler` | 命令行可全自动，可放进 CI |
| 长列表 | `LazyVStack` + 分页 | 实测：`VStack` 一次创建 1000 个视图会卡死并留下内存尖峰；`LazyVStack` 内存平稳 |

## 二、匹配度评估

| 组件 | 现状 | 结论 | 理由 / 代价 |
|---|---|---|---|
| `@Observable` | 3 个类、16 个 `@Published` | **采用** | 零依赖、纯 Swift；流式 token 更新时只重绘用到的地方，直接改善长对话卡顿 |
| `LazyVStack` + 分页 | `ScrollView + VStack + ForEach(全部消息)`，打开会话一次性 `SELECT *` | **采用（P0）** | 这是唯一会让"用户进来页面卡死"的地方；5000 条消息必然复现 |
| Xcode 工程 | 纯 SwiftPM + 手写 Info.plist + ad-hoc | **采用（P2）** | 签名/公证/资源/归档都要它；保留 `Package.swift` 继续跑 `scripts/test.sh` 与 CI |
| Developer ID + 公证 | 无 | **采用（P2，需你的账号）** | 不公证的分发包每次都要用户右键打开 |
| Sparkle 2 | 无 | **采用（P3，依赖 P2）** | 没有 Developer ID 就更新不了；先有公证再上自动更新 |
| `KeyboardShortcuts` | 自写 Carbon 全局热键（≈60 行） | **可选（P3）** | 收益是用户可自定义 + 录制 UI；代价是引入第一个第三方包（约 +300KB）。核心库仍保持零依赖 |
| `GRDB` / SwiftData | 手写 SQLite + FTS5 + 中文分词补丁 | **不采用** | 现有实现已覆盖需求（FTS5、事务、迁移、actor 串行化）；换 GRDB 只是为了少写代码，反而要重做中文分词；SwiftData 的全文检索能力不足以支撑 `search_history` |
| Electron / Tauri | — | **不采用** | 与 2MB / 80MB 的硬指标冲突 |

## 三、性能设计（先想清楚数据量级，再写代码）

| 场景 | 量级假设 | 设计 |
|---|---|---|
| 打开一个会话 | 单会话 ≤ 5000 条消息 | 只查最近 200 条（`ORDER BY seq DESC LIMIT`，再反转）；顶部「加载更早」每次再取 200 |
| 长列表渲染 | 可见 ≤ 30 条 | `LazyVStack`；工具卡片默认折叠；reasoning 默认折叠 |
| 流式输出 | 每轮 1 个气泡在变 | 只改最后一个 item 的 `content`，不重建数组；`@Observable` 让重绘停在用到它的行 |
| 全文检索 | 10 万条消息 | FTS5 + bm25 排序已够；`snippet()` 只回片段，不回全文 |
| 内存 | 空闲 < 120MB | 不缓存历史 `[ChatMessage]`，切会话重查；摘要只留最新一份 |

验收线：5000 条消息的会话，滚动 60fps、打开 < 300ms、切换会话 RSS 增幅 < 50MB。

## 四、落地顺序

> 2026-11-26 更新：项目定位改为**本机自用、不分发**。P2/P3 里的签名、公证、Sparkle 全部降级为「可选」，保留脚手架（`project.yml` + `release.sh`）但不再推进；日常入口是 `scripts/run.sh`。

**P0 性能（本次）**
1. `ChatView`：`VStack` → `LazyVStack`，reasoning/工具默认折叠
2. `MemoryStore.messages(in:limit:beforeSeq:)`：倒序取 N 条再反转
3. `ChatStore`：`open()` 只加载最近 200 条；`hasEarlierMessages` + `loadEarlier()`
4. `ChatView` 顶部「加载更早」

**P1 状态管理（本次）**
5. `ChatStore` / `AppSettings` / `AgentDirectory` 改 `@Observable`
6. 视图改用 `@Environment(Type.self)` + `@Bindable`
7. 去掉 `ObservableObject` / `@Published` / `@EnvironmentObject`

**P2 工程化（脚手架已完成，待环境）**
8. ✅ `project.yml`（XcodeGen 描述）—— `xcodegen generate` 生成工程，`.xcodeproj` 不入库
9. ✅ `scripts/release.sh`：`xcodebuild archive` → 导出 → 签名 → 公证 → `stapler` → 打 zip → 可选 `gh release`；缺 Xcode/证书时自动退回 ad-hoc
10. ✅ 版本号单一来源：`project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
11. ⏳ 待办（需要环境）：装 Xcode、`brew install xcodegen`、Developer ID 证书、`notarytool store-credentials pa-notary`

**P3 分发与体验**
12. Sparkle 2：`appcast.xml` 放 GitHub Releases，菜单栏加「检查更新」
13. （可选）`KeyboardShortcuts` 换掉自写热键，设置页支持自定义组合键

P0/P1 不改公开行为、不引入依赖，测试可覆盖；P2 之后需要开发者证书。
