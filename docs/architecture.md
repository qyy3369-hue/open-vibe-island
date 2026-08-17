# Architecture

## System Shape

The project is a single Swift package with four targets:

| Target | Role |
|---|---|
| **OpenIslandApp** | SwiftUI + AppKit shell — menu bar extra, overlay panel (notch/top-bar), settings. Entry point: `OpenIslandApp.swift` with `AppModel` as the central `@Observable` state owner. |
| **OpenIslandCore** | Shared library — models (`AgentSession`, `AgentEvent`, `SessionState`), bridge transport (Unix socket IPC with JSON line protocol), hook models/installers, transcript discovery, session persistence/registry. |
| **OpenIslandHooks** | Lightweight CLI executable invoked by agent hooks. Reads hook payload from stdin, forwards to app bridge via Unix socket, writes blocking JSON to stdout only when island denies a `PreToolUse`. |
| **OpenIslandSetup** | Installer CLI for managing `~/.codex/config.toml` and `hooks.json`. |

## Data Flow

### Hook-based agents (Codex, Claude Code and forks, Gemini CLI, Antigravity)

```
Agent
  │  stdin: JSON payload
  ▼
OpenIslandHooks CLI  (--source codex | --source claude | ...)
  │  Unix socket
  ▼
BridgeServer → AppModel → UI
  │  BridgeResponse
  ▼
OpenIslandHooks CLI
  │  stdout: JSON directive (only when a response is needed)
  ▼
Agent
```

### Plugin-based agents (OpenCode)

```
OpenCode → JS plugin (~/.config/opencode/plugins/) → Unix socket → BridgeServer → AppModel → UI
```

### Storage-observed agents (DeepSeek Harness)

```
DeepSeek Harness Desktop / dsh CLI
  │  writes workspace.json + session_projcache.json
  ▼
DeepSeekSessionDiscovery
  │  startup snapshot + 2-second polling
  ▼
DeepSeekStorageWatcher → AgentEvent → AppModel → SessionState → UI
```

This path is intentionally read-only. It does not install a DeepSeek hook or modify `cordis.patch.yml`. `ActiveAgentProcessDiscovery` separately detects `dsh` and supported Node/package-runner forms so the monitoring coordinator can reconcile storage records with live processes.

### Session discovery (on launch)

1. Restore cached Codex, Claude, OpenCode, and Cursor sessions from their registries
2. Discover Codex rollout JSONL, Claude transcript JSONL, and DeepSeek native storage records
3. Merge records by source-stable session identifiers
4. Prime the DeepSeek watcher without replaying completion notifications for sessions that were already complete before launch
5. Reconcile with active terminal/agent processes and start the live bridge

**Fail-open principle**: if the bridge is unavailable, the hook process exits silently without writing to stdout, so the agent continues running unaffected.

## Event Model

The shared `AgentEvent` enum drives all state transitions:

- Session started / updated / completed
- Permission requested
- Question asked
- Tool use (pre/post)
- Subagent lifecycle
- Jump target updated

Each event carries a stable session identifier, agent type, timestamps, and enough metadata to route approvals or focus changes.

Source identity is preserved across adapters. Antigravity uses `conversationId`; DeepSeek Harness uses its persisted session UUID. A shared working directory alone is never sufficient to merge two independent sessions.

## Completion Semantics

- **Antigravity**: `PreInvocation` is running. `Stop` is completed only when `fullyIdle == true`; otherwise it remains running because background work may still exist.
- **DeepSeek Harness**: a non-null `openStep`, non-empty `pendingCalls`, or a submitted first prompt with no completed turn is running. A task is completed after active work clears and `turns > 0`.
- **DeepSeek filtering**: records marked `sessionListMetadata.blank == true`, or records with no prompt, turn, or active work evidence, are not surfaced.
- **Fast DeepSeek tasks**: a newly discovered completed task is emitted as a running bootstrap followed by completion so notification deduplication does not suppress the completion card.

## State Management

- `SessionState.apply(_:)` is the single source of truth for session mutations (pure reducer)
- `AppModel` owns all live state and bridge lifecycle
- All models are `Sendable` and `Codable`

## Transport

- Unix domain sockets for app ↔ hook communication
- Newline-delimited JSON envelopes (`BridgeCodec`)
- Bridge server lives inside the app process

## Terminal Jump-Back

Terminal focus restoration is implemented per-terminal:

| Terminal | Strategy |
|---|---|
| Terminal.app | TTY targeting via AppleScript |
| Ghostty | Window ID matching |
| cmux | Unix socket API |
| Kaku | CLI pane targeting |
| WezTerm | CLI pane targeting |
| iTerm2 | AppleScript session/TTY probe |
| tmux (multiplexer) | switch-client → select-window → select-pane |

The hook helper enriches payloads with terminal-local hints (terminal app, TTY, session ID, window title) from environment inspection at hook invocation time.

## Technologies

- SwiftUI for most UI composition
- AppKit for panel behavior, status item control, and activation policy edge cases
- Unix domain sockets for IPC
- JSON event envelopes for debugging and adapter simplicity
- Sparkle for auto-updates

## Engineering Rules

- Preserve clean separation between UI state and transport concerns
- Version the event schema so adapters can evolve safely
- Keep setup reversible when editing third-party tool config files
- Keep the runtime surface bound to real agent state rather than shipping UI-level demo toggles
