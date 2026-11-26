# AGENTS.md

给在本仓库里工作的编码 Agent（Claude Code / Codex / ZCode 等）的说明。人也可以读。

## 这是什么

原生 macOS 个人助理 Agent：菜单栏常驻 + ⌥Space 浮动面板 + 流式对话 + 工具调用（带人工审批）+ SQLite 长期记忆。

- 包名 `PersonalAgent`，GitHub `samlaying/personal-agent`，应用显示名「个人助理」，bundle id `com.sam.personal-agent`
- **定位：本机自用，不分发**。不做签名/公证/自动更新那条线，`scripts/run.sh` 一条命令启动
- 只依赖系统框架（SwiftUI / AppKit / Foundation / SQLite3 / Carbon / Security）。**不要引入第三方 Swift 包**——体积和启动时间是硬指标
- 硬指标：`.app` ≈ 2MB，空闲 RSS ≈ 80MB。任何改动都不能明显抬高这两项（禁止 WebView、禁止额外常驻进程）

## 构建与验证

```bash
swift build                 # 快速类型检查
scripts/test.sh             # 全部单元测试（swift-testing；本机只有 Command Line Tools，脚本里已带 -F 和 rpath）
scripts/build-app.sh        # Release 打包到 .build/app/PersonalAgent.app
scripts/e2e.sh              # 冒烟：本地 mock 模型 + 启动/常驻/内存/落库检查
scripts/run.sh              # 编译 + 启动（--clean 强制重编）
scripts/release.sh          # 可选：签名/公证/发布流水线（不分发时用不到）
```

版本号只有一个来源：`project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，`build-app.sh` 与 `release.sh` 都从那里读。
Xcode 工程由 `xcodegen generate` 从 `project.yml` 生成，**不提交 `.xcodeproj`**（避免 pbxproj 冲突）；CI 仍然只用 SwiftPM。

改完必须跑 `scripts/test.sh`，全绿才算完。CI（`.github/workflows/test.yml`）在 macOS runner 上跑同样两步。

想手工试：`swift run mock-llm --port 18731`，把设置里的 Base URL 指到 `http://127.0.0.1:18731/v1`，API Key 随便填。

## 目录

```
Sources/PACore/     纯逻辑，无 UI 依赖，可单测（改逻辑基本都在这里）
Sources/PAApp/      SwiftUI + AppKit 外壳（NSStatusItem、NSPanel、ChatStore、设置）
Sources/PAMock/     本地 OpenAI 兼容 mock 服务（BSD socket，无依赖）
Sources/mock-llm/   mock 服务的 CLI 入口
Tests/PACoreTests/  swift-testing（@Test / #expect）
```

关键文件：

| 文件 | 职责 |
|---|---|
| `PACore/AgentRunner.swift` | Agent 循环、system prompt 拼装、审批门控、summary 事件 |
| `PACore/ModelClient.swift` | 请求/事件类型、`TranscriptBuilder`（预算裁剪 + 头部修复） |
| `PACore/ContextSummarizer.swift` | 超预算时的摘要压缩 |
| `PACore/MemoryStore.swift` | actor 化 SQLite：sessions / messages / agents / FTS5 |
| `PACore/BuiltinTools.swift`、`KnowledgeTools.swift` | 内置工具实现 |
| `PACore/TextTokenizer.swift` | 中文 FTS 分词补丁（`CJKText`） |
| `PAApp/ChatStore.swift` | 会话状态机、事件消费、落库 |
| `PAApp/ChatView.swift`、`SessionSidebar.swift` | 对话 UI、左侧会话列表 |

## 代码约定

- **Swift 6 严格并发**。UI 一律 `@MainActor`；`MemoryStore` 是 actor；跨边界类型要 `Sendable`。确实要持有可变状态时用 `@unchecked Sendable` 包裹并加锁（见 `LockedValue`、`DBHandle`、`ApprovalTicket`），不要用 `nonisolated(unsafe)` 糊过去
- actor 的 `init` 里不能调自己的隔离方法——`MemoryStore` 的做法是静态 `setUp(handle)`，在 handle 装进 `DBHandle` 之前执行
- 数据库 schema 变更必须**幂等且向后兼容**：`CREATE TABLE IF NOT EXISTS` + `PRAGMA table_info` 检查后 `ALTER TABLE`（参考 `addSummaryColumnsIfNeeded`），老库要能直接用
- 解析模型返回不要用 `Codable` 硬解：用 `JSONSerialization` 宽容解析（见 `JSONValue.parse`、`StreamDecoder`），因为不同 provider 的字段形态不一致
- 用户可见文案用中文，注释用中文；命名用英文
- 错误的 `LocalizedError` 要能直接展示给用户

## 加一个工具

1. 在 `PACore` 里新建 `struct XxxTool: AgentTool`，实现 `name` / `summary` / `risk` / `parameters`（用 `JSONSchema.object` + `JSONProperty` DSL），`run(arguments:context:)`
2. 风险分级要诚实：只读 → `.readOnly`；写文件/改状态 → `.write`；执行命令/不可逆 → `.dangerous`。写了类工具应实现 `approvalSummary(for:)` 让人看懂要发生什么
3. 在 `PAApp/ChatStore.swift` 的 `makeRunner` 里注册进 `ToolRegistry`
4. 在 `Tests/PACoreTests/` 补测试，并更新 README 的工具表

工具返回的是**数据不是指令**，长输出要有上限（参考 `OutputCollector` 的 32KB 截断）。

## 上下文与记忆（改动前先读）

- 每轮请求 = `SystemPrompt.make(...)` + `TranscriptBuilder.trim(history)` + 本轮输入
- 预算单位是**字符**不是 token（`transcriptBudgetChars`，默认 60k），刻意不引分词器
- 超预算：`split` 报告被丢弃的消息 → `ContextSummarizer` 压成 ≤800 字摘要 → 写进 `sessions.summary` / `summary_through_seq` 并在下轮复用；失败则退回直接截断
- 裁剪后必须修头部：不能以孤儿 `tool` 消息或结果不全的 `assistant.tool_calls` 开头，否则 provider 会 400
- `AgentRunner` **无状态**（每次 run 独立），这是多 Agent 嵌套调用的前提，不要往里塞实例状态

## 多 Agent（预留，未实现）

已铺好的路：`ChatMessage.author` = `agent:<id>`、`ChatSession.mode` 有 `.team`、`AgentProfile` 独立持久化、runner 可嵌套。计划是加 `delegate` 工具让父 Agent 调起子 Agent，再用一个编排者 profile 汇总。**不要绕过这条路径重造一套 executor。**

## 不要做的事

- 不引第三方依赖、不加 WebView、不加常驻后台进程
- 不在 `PACore` 里 `import SwiftUI` / `AppKit`（要保持可单测、可复用）
- 不把密钥写进 UserDefaults 或文件——走 `KeychainStore`
- 不静默吞掉 provider 错误；要在 UI 上给出可读原因
- 不提交 `docs/screenshot.png` 之外的大二进制；不把真实 API Key 提交进仓库
- 演示/截图需要造数据时，**先备份用户的真实数据库**（`~/Library/Application Support/PersonalAgent/memory.sqlite`），结束后恢复并核对条数

## 平台坑（踩过的）

- **刘海屏上新建的菜单栏图标会落在刘海下面**：`NSStatusItem` 报 `isVisible = true`，但 WindowServer 里根本没有这个窗口，用户看不到也点不到。解法是先写一条 `NSStatusItem Preferred Position <autosaveName>` 到 app 自己的 UserDefaults（也就是用户 ⌘ 拖动图标时系统写的那条），把图标推到刘海右侧；见 `AppDelegate.makeStatusItem`。SwiftUI 的 `MenuBarExtra` 在同一台机器上同样画不出来，所以菜单栏项是用 AppKit 手搓的
- **accessory 应用没有 Dock 图标，窗口最小化后会流落到 Dock 角落**：面板的黄色按钮用 `FloatingPanel.miniaturize` 改成直接 `orderOut`，`show()` 里再 `deminiaturize` 兜底
## Git

- 默认在 `main` 上工作；较大改动先开分支（如 `feat/xxx`），测试绿了再合
- 提交信息用中文短句描述做了什么
- 只有用户明确要求时才 push 或发 Release
