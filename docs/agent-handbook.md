# Open Island 开发者与 Coding Agent 指南 (Agent Handbook)

本文档专为后续接手的 **AI Coding Agent** 以及开发者编写，旨在系统性阐述 **Open Island** 的设计定位、核心架构、各类 Agent 的监视机制、开发工作流与关键避坑指南。

---

## 1. 项目定位与设计原则

Open Island（灵动岛）是一个针对 macOS 开发者的原生任务监视与交互控制台，主要用于在刘海区域（或屏幕顶部悬浮栏）实时呈现终端与桌面 AI Coding Agent 的执行状态、交互提问与完成提醒。

- **Native macOS**: 基于 Swift 6、SwiftUI 与 AppKit 构建，轻量高效，低资源占用。
- **Local First & Privacy**: 纯本地运行，不依赖远程服务器或账号系统，不采集遥测数据。
- **Fail Open**: 如果 Open Island 崩溃或 Socket 通信中断，Agent 在终端中依然能正常无感运行，绝对不可阻塞用户终端工作流。
- **Seamless Terminal Jump**: 点击通知或会话卡片，可通过 AppleScript、Ghostty IPC、cmux Socket、tmux 等机制一键聚焦并跳转回对应的终端窗口/标签页/工作区。

---

## 2. 代码仓库与模块架构

项目采用 Swift Package Manager (SPM) 进行多 Target 管理：

```
OpenIsland (Root)
├── Package.swift
├── Sources
│   ├── OpenIslandCore       # 核心业务领域层：会话模型、状态机、Socket 桥接服务、存储/文件解析器、Hook 安装器
│   ├── OpenIslandHooks      # 轻量 CLI 可执行文件，作为 Agent Hook 的入口（转发事件至 BridgeServer）
│   ├── OpenIslandSetup      # CLI 工具，支持终端中检测与一键配置 Hook
│   └── OpenIslandApp        # macOS 主应用程序：SwiftUI 界面、刘海窗口渲染、设置面板、进程探活、跳转逻辑
├── Tests
│   ├── OpenIslandCoreTests  # Core 模块单元测试（Hook 解析、状态机、Socket 通信、存储发现）
│   └── OpenIslandAppTests   # App 模块测试（会话列表聚合、偏好隔离、UI 状态迁移）
└── docs                     # 设计方案、规范文档、技术调研
```

### 核心数据流

```
[Agent 运行时]
  │
  ├─ (方式 A: Hook CLI) ──> OpenIslandHooks (CLI) ──[Unix Socket]──┐
  │                                                                 ▼
  ├─ (方式 B: 本地持久化) ──> Storage Watcher (JSON / JSONL) ────> BridgeServer / Coordinator ──> SessionState ──> SwiftUI UI (Notch / Panel)
  │                                                                 ▲
  └─ (方式 C: 进程探活) ──> ActiveAgentProcessDiscovery (ps/lsof) ─┘
```

---

## 3. 各 Agent 监控机制与接入分类

Open Island 针对不同 Agent 的开放能力，采用了三种互补的接入机制：

### 3.1. Hook 接入方式 (CLI -> Unix Socket -> BridgeServer)

Agent 在执行特定生命周期节点时调用 `OpenIslandHooks --source <name> --event <event>`，Hook CLI 读取 stdin 中的 JSON payload 并通过本地 Socket 转发给 `BridgeServer`。

- **Codex (`--source codex`)**:
  - 配置文件：`~/.codex/config.toml`
  - 关键事件：`SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Stop`
  - 特性：支持双向响应，可拦截 Tool 调用由用户在灵动岛内点击“Allow / Deny”。
- **Claude Code 及衍生分支 (`--source claude / qoder / qwen / factory / codebuddy / kimi`)**:
  - 配置文件：`~/.claude/settings.json`, `~/.kimi/config.toml` 等
  - 关键事件：`PreToolUse`, `PostToolUse`, `Stop`
- **Antigravity (`--source antigravity`)**:
  - 配置文件：`~/.gemini/config/hooks.json`
  - 关键事件：`PreInvocation`, `Stop`
  - **关键状态规则**：
    - `PreInvocation` -> 转换为 `.running`。
    - `Stop` 时**必须严格检查 `fullyIdle` 字段**：
      - `fullyIdle == true`：任务完全结束，派发 `.sessionCompleted`。
      - `fullyIdle != true`（或 `false`）：Agent 本轮推理虽结束，但后台仍有活跃命令/子任务在运行，必须维持在 `.running` 状态并提示后台任务中。
    - 唯一标识：严格使用 payload 的 `conversationID`，严禁仅按工作目录强行合并独立会话。
- **Gemini CLI (`--source gemini`)**:
  - 配置文件：`~/.gemini/config.json`
  - 关键事件：`SessionStart`, `BeforeAgent`, `AfterAgent`, `SessionEnd`, `Notification`。

---

### 3.2. 原生存储监听方式 (Native Storage Watcher)

某些桌面版或不支持通用外部 Hook 的 Agent，通过后台定时轮询/文件监视其真实存储目录。

- **DeepSeek Harness (`DeepSeekSessionDiscovery` & `DeepSeekStorageWatcher`)**:
  - **存储路径**：
    - 桌面端：`~/Library/Application Support/io.github.hairyf.deepseek-harness-desktop/data/dsh/storages/`
    - CLI 端：`~/.dsh/storages/`
  - **文件格式**：
    - `workspace.json`：包含工作区 ID、标题与关联的 `sessionIds`。
    - `session_projcache.json`：包含会话详情，`tables.sessions.<sessionID>` 下有 `identity.cwd`, `rows.title.val`, `rows.sessionStats.val`。
  - **状态判断逻辑**：
    - 当 `openStep != nil` 或 `pendingCalls` 非空时，判定为正在执行步骤（`.running`）。
    - 当 `openStep == nil` 且 `turns > 0` 时，判定为执行完毕（`.completed`）。
  - **重要注意事项**：
    - **切勿**向 `~/.dsh/profiles/web/cordis.patch.yml` 添加不存在的 `hooks:` 键（该文件顶层为 YAML 数组，追加对象会导致 DeepSeek 启动失败）。
    - 每个 DeepSeek 会话保持独立的 `session-<uuid>`，互不干扰。

---

### 3.3. 进程探活与清理机制 (Process Discovery)

- **`ActiveAgentProcessDiscovery`**:
  - 通过 `ps` 与 `lsof` 定期扫描系统中正在运行的 `codex`, `claude`, `dsh`, `node`, `kimi` 等进程。
- **`ProcessMonitoringCoordinator`**:
  - 结合实时 Socket 事件与探活结果，自动关联终端 TTY / CWD，并在进程退出或超时后将 Stale 会话归档至 Idle 列表中。

---

## 4. 开发与工作流规范 (Mandatory Agent Rules)

接手本项目的 Agent 必须严格遵守以下工作流（定义于 `AGENTS.md`）：

1. **分支与 Worktree 隔离**：
   - 严禁在 `main` 分支直接编辑或提交代码。
   - 所有开发必须在独立的 feature worktree 中进行（例如 `/Users/yuanmuyou/Documents/island-feat-<name>` 分支 `feat/<name>`）。
2. **构建与测试工具链**：
   - 必须使用 Swift 6 工具链编译和测试：
     ```bash
     ~/Library/Developer/Toolchains/swift-6.2.4-RELEASE.xctoolchain/usr/bin/swift test
     ```
3. **验证原则**：
   - 每次代码修改完成后，必须先执行针对性测试或全量测试（当前基准 340+ 测试均需保持 Passing）。
4. **Git Commit 规范**：
   - 每次完成一个独立功能的修改并验证通过后，必须立即使用 Conventional Commits 规范（如 `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`）提交，不可遗留未暂存修改。
5. **本地开发 App 刷新**：
   - 若要启动并验证 `Open Island Dev.app`，运行 `zsh scripts/launch-dev-app.sh` 进行打包刷新，不可仅运行 `open -na`（可能会启动旧二进制缓存）。

---

## 5. 核心避坑指南 (Gotchas & Antipatterns)

1. **Antigravity 后台任务误报完成问题**：
   - 永远不要将 `Stop` 直接等同于完成，必须验证 `payload.fullyIdle == true`。
2. **工作目录跨会话误合并问题**：
   - 开发者可能在同一目录开启多个独立会话（例如主 Agent、子 Agent 或双任务），绝不能仅根据 `workingDirectory` 相同就把它们强行揉成一个会话。各工具均有其全局唯一 ID。
3. **DeepSeek 配置兼容性**：
   - DeepSeek Harness 的 `cordis.patch.yml` 是补丁数组配置，不要尝试通过改写此文件注入 Shell Hook，使用文件存储监听（`DeepSeekSessionDiscovery`）是唯一稳健的方案。
4. **Swift Testing 偏好隔离**：
   - 在涉及 `AppModel`、`SessionState`、显示设置的测试中，需注意清理或隔离 `UserDefaults`，防止跨测试用例污染。
