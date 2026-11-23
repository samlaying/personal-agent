# PersonalAgent

一个原生 macOS 个人 Agent 应用：菜单栏常驻、⌥Space 全局唤出、流式对话、工具调用（带人工审批）、SQLite 长期记忆。没有 Electron、没有 WebView、没有第三方依赖。

## 快速开始

```bash
# 编译 + 打包 .app（首次约 1 分钟）
scripts/build-app.sh
open .build/app/PersonalAgent.app
```

1. 菜单栏出现 ✨ 图标，点「设置…」
2. 填模型 API：Base URL（任何 OpenAI 兼容端点，如 `https://api.openai.com/v1`）、模型名、API Key（存 Keychain）
3. 可选：填 Tavily Key 启用联网搜索（basic 深度，1 credit/次）
4. 按 ⌥Space 唤出面板开始对话；Esc 隐藏

## 命令

```bash
scripts/test.sh      # 全部单元测试（无需完整 Xcode，CLT 即可）
scripts/build-app.sh # Release 打包
scripts/e2e.sh       # 冒烟：本地 mock 模型 + 启动/常驻/内存/落库
```

## 内置工具

| 工具 | 风险 | 审批 |
|---|---|---|
| `get_current_time` | 只读 | 自动执行 |
| `list_directory` / `read_file` | 只读 | 自动执行 |
| `search_history`（历史全文检索） | 只读 | 自动执行 |
| `web_search`（Tavily） | 只读 | 自动执行 |
| `write_file` / `remember` | 写入 | 每次询问（可「总是允许」） |
| `run_shell_command` | 高危 | 每次询问 |

审批原则：**模型只负责推理，是否允许执行由你决定**。拒绝后模型会收到拒绝说明并被明确禁止换个方式重试。

## 记忆

- `~/Library/Application Support/PersonalAgent/memory.sqlite` — 会话与消息，FTS5 全文检索（中文按字索引，搜「世界」能命中「你好世界」）
- 同目录 `USER.md` / `MEMORY.md` — 每次对话注入系统提示词；前者写你的偏好，后者是 Agent 通过 `remember` 写的笔记，随时可手改

## 架构

```
Sources/
  PACore/                    # 纯逻辑库，无 UI 依赖，可复用
    OpenAICompatibleClient   # 流式 chat completions（SSE 逐字节解析）
    StreamAggregator/Decoder # 增量合并：文本、reasoning、分片 tool_call 参数
    AgentRunner              # Agent 循环：流式→工具→回填→循环，审批门控
    Tool                     # AgentTool 协议 + 风险分级（readOnly/write/dangerous）
    MemoryStore              # actor 化 SQLite（WAL、FTS5、事务）
    CJKText                  # 中文分词索引适配
    KeychainStore            # 密钥存登录钥匙串
  PAMock/                    # 本地 OpenAI 兼容模拟服务（纯 socket，测试/联调用）
  PAApp/                     # SwiftUI 应用
    MenuBarExtra + NSPanel   # 菜单栏常驻 + ⌥Space 浮动面板
    ChatStore                # 会话状态机、事件消费、持久化
    AppSettings/AgentDirectory
```

关键设计：

- **AgentRunner 无状态**，每次 run 独立；`history`/`input`/`profile` 全部入参。这是多 Agent 的扩展点。
- **协议宽容解析**：content 支持字符串/分段数组、arguments 支持字符串/对象、reasoning 支持 `reasoning_content`/`reasoning` 双字段。
- **上下文预算**：transcript 超长时从最新往前保留，并修复被截断的 tool 请求/结果对（成对保留或成对丢弃），不会发出孤儿 tool 消息。

## 多 Agent 团队（下一步）

基础已预留：

- `ChatMessage.author` 带 `agent:<id>`，`ChatSession.mode` 已有 `.team` 分支，表结构不用改
- `AgentProfile` 独立持久化（名称/指令/模型），UI 已能管理多个
- 计划中的实现路径：加一个 `delegate(agent:instructions:task:)` 内置工具（`dangerous` 级），由 AgentRunner 嵌套调用自身——runner 是无状态 struct，天然支持嵌套；子 Agent 的事件折叠进父会话的 transcript。再加一个「团队编排者」profile，负责拆分任务、分派成员、汇总结果。

## 平台与体积

- macOS 14+，Apple Silicon；本机（M5 MacBook Air / 16GB / macOS 26.7.1）实测
- .app 约 2MB；空闲内存约 82MB，6 线程，无渲染进程
- 只依赖系统框架（SwiftUI/AppKit/Foundation/SQLite3/Carbon/Security），SwiftPM 零第三方包

## 已知限制

- reasoning 展示但不持久化（重开会话后不可见）
- 面板固定浮在最前（未做「仅当前空间」选项）
- 分发需自行 Developer ID 签名 + 公证（当前脚本为 ad-hoc 签名，仅本机可用）
