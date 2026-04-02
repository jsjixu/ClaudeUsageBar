# Claude Usage Bar

<p align="center">
  <img src="screenshots/icon.png" width="128" alt="Claude Usage Bar Icon">
</p>

<p align="center">
  <strong>原生 macOS 菜单栏应用，实时显示 Claude 的 Session 和 Weekly 用量。</strong>
</p>

<p align="center">
  <img src="screenshots/menubar.png" alt="菜单栏" height="40">
</p>

<p align="center">
  <img src="screenshots/popover.png" alt="用量面板" width="320">
  <img src="screenshots/stats.png" alt="统计概览" width="320">
</p>

<p align="center">
  <img src="screenshots/stats-chart.png" alt="活动图表" width="320">
</p>

## 功能

- **状态栏实时显示** — 常驻菜单栏：`⚡35% 📅4%`，一眼看到 Session（5h）和 Weekly（7d）用量
- **一键登录** — 点击登录按钮直接执行 `claude auth login` 弹浏览器登录，无需手动开终端
- **登录后自动刷新** — 后台每 2 秒轮询检测新凭证，登录成功自动加载用量，无需手动刷新
- **Delegated CLI Refresh** — Token 过期时，自动通过 `claude -p ping` 触发 CLI 刷新，避免 OAuth rate limit
- **智能 Token 读取** — 多源凭证优先级：CLI Proxy API → 内存缓存 → Keychain → credentials.json → Delegated CLI → OAuth refresh
- **FailureGate 双层防护** — terminal block（invalid_grant 彻底停止重试）+ transient backoff（429/网络错误指数退避），Keychain+File 双源 fingerprint 自动解锁
- **重置倒计时** — 每个窗口还有多久回血，一目了然
- **模型独立追踪** — Sonnet、Opus 周用量单独显示
- **颜色分级** — 绿色（<50%）→ 橙色（50–80%）→ 红色（>80%）
- **Stats 面板** — 历史用量统计（Usage tab + Stats tab）
- **多机共享** — 多台 Mac 共享用量数据，不触发 429 限速（见 [远程模式](#远程模式)）
- **开机自启** — 弹窗内一键开关
- **零依赖** — 纯 Swift + SwiftUI + AppKit，无第三方库
- **隐私优先** — 读取本地 OAuth 凭证，直接调 Anthropic API，不经过任何第三方
- **静默运行** — 仅菜单栏图标，不在 Dock 显示

## 工作原理

读取 Claude Code CLI 的 OAuth 凭证（macOS 钥匙串或 `~/.claude/.credentials.json`），调用 Anthropic 官方用量 API。

```
Claude Code CLI credentials (Keychain / ~/.claude/.credentials.json)
  → OAuthManager（多源凭证读取 + 自动刷新）
  → api.anthropic.com/api/oauth/usage
  → 菜单栏 + 弹窗
```

不需要浏览器，不需要 Cookie，不需要 Chrome DevTools Protocol。

## 系统要求

- **macOS 15.0+**（Apple Silicon）
- **Claude Code CLI** 已安装并登录
- **Claude Max** 订阅（Pro/Team 应该也能用）

## 安装

### 1. 安装 Claude Code CLI（如果还没装）

```bash
npm install -g @anthropic-ai/claude-code
claude  # 浏览器登录后 Ctrl+C 退出
```

### 2. 编译安装

```bash
git clone https://github.com/jsjixu/ClaudeUsageBar.git
cd ClaudeUsageBar
./build.sh
cp -r "Claude Usage Bar.app" /Applications/
open "/Applications/Claude Usage Bar.app"
```

只需要 Xcode Command Line Tools（不需要完整 Xcode）：

```bash
xcode-select --install  # 如果尚未安装
```

### 3. 开启开机自启

点击菜单栏图标 → 打开 **Launch at Login** 开关。

## 认证与 Token 管理

ClaudeUsageBar 采用多源凭证解析链，自动维持 session 有效，无需手动干预。

### 凭证优先级

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | **CLI Proxy API** | 最快 — 直接从 Claude CLI 守护进程读取 token |
| 2 | **内存缓存** | 进程内缓存上次成功读取的 token |
| 3 | **Keychain** | macOS 钥匙串（由 Claude Code CLI 存入） |
| 4 | **credentials.json** | `~/.claude/.credentials.json` 文件兜底 |
| 5 | **Delegated CLI Refresh** | 执行 `claude -p ping` 触发 CLI 刷新 token |
| 6 | **OAuth refresh** | 最后兜底：直接走 OAuth refresh 流程 |

### Delegated CLI Refresh（委托 CLI 刷新）

当 token 过期且直接 OAuth refresh 会触发 rate limit 时，ClaudeUsageBar 自动在后台执行 `claude -p ping`。这将 token 刷新委托给 Claude CLI 进程，由 CLI 自己处理 OAuth 流程和限速逻辑。刷新完成后，应用从 Keychain 或 credentials.json 自动取到新 token。

### FailureGate 双层防护

| 层级 | 触发条件 | 行为 |
|------|---------|------|
| **Terminal block** | `invalid_grant` 错误 | 彻底停止重试；等待 Keychain 或文件 fingerprint 变化（即重新登录）后自动解锁 |
| **Transient backoff** | 429 / 网络错误 | 指数退避；错误消除后自动恢复 |

FailureGate 同时监听 Keychain 和 `~/.claude/.credentials.json` 的 fingerprint。一旦你重新登录（通过一键登录或 `claude auth login`），新凭证的 fingerprint 变化会自动解锁 gate，恢复数据拉取。

### 一键登录流程

1. 点击弹窗中的 **Login** 按钮 → 浏览器自动打开 `claude auth login`
2. 应用每 2 秒检测一次新凭证
3. 检测到登录成功后，用量数据自动加载 — 无需手动刷新

## 远程模式

**问题：** 多台 Mac 同时跑 ClaudeUsageBar 会触发 429 限速 — Anthropic 的用量 API 限频很严。

**方案：** 一台 Mac 查 API（服务端），其他 Mac 读缓存数据（客户端）。客户端 API 调用次数为零。

```
┌─────────────────────┐         ┌─────────────────────┐
│   Mac A（服务端）     │         │   Mac B（客户端）     │
│                     │         │                      │
│  OAuth → Anthropic  │  HTTP   │  Remote → Mac A      │
│  每 5 分钟查一次     │◄───────►│  读取缓存 JSON       │
│  + 开放 :9876 端口   │         │  0 次 API 调用       │
│  标签: [LOCAL]      │         │  标签: [REMOTE]      │
└─────────────────────┘         └──────────────────────┘
```

### 配置

#### 服务端（查 Anthropic API 的那台 Mac）

不需要任何配置 — 内嵌 HTTP 服务器在本地模式下自动启动，监听端口 **9876**。

验证是否在运行：
```bash
curl http://127.0.0.1:9876/usage
```

#### 客户端（其他 Mac）

**方式 A：先配置再启动**（推荐 — 避免任何 API 调用）

```bash
defaults write ClaudeUsageBar remote_usage_url "http://<服务端地址>:9876"
open "/Applications/Claude Usage Bar.app"
```

**方式 B：在应用内配置**

点击菜单栏图标 → 展开 **Remote Mode** → 输入服务端 URL → **Save & Restart**。

### 网络方案

客户端只需要能 HTTP 访问服务端的 9876 端口即可：

| 方式 | URL 示例 | 说明 |
|------|----------|------|
| 局域网 | `http://192.168.1.100:9876` | 最简单 — 两台 Mac 在同一 Wi-Fi/网络 |
| [Surge Ponte](https://manual.nssurge.com/others/ponte.html) | `http://mymac.sgponte:9876` | 随时随地访问家里的 Mac，无需端口转发 |
| Tailscale | `http://my-mac-mini.tail12345.ts.net:9876` | 类似 Ponte 但跨平台 |
| SSH 隧道 | `http://127.0.0.1:9876`（先 `ssh -L 9876:127.0.0.1:9876 user@server`） | 有 SSH 就能用 |

### Surge Ponte 详细配置

[Surge Ponte](https://manual.nssurge.com/others/ponte.html) 通过 Surge 的代理网格访问家庭网络中的设备 — 不需要公网 IP、不需要端口映射、不需要 VPN。

**前置条件：**
- 两台 Mac 都安装了 [Surge for Mac](https://nssurge.com)
- 服务端 Mac（LOCAL 模式）开启了 Ponte
- 两台 Mac 用同一个 Surge 账号 / iCloud 团队

**步骤：**

1. **服务端 Mac：** 在 Surge → Dashboard → Ponte 中启用。记下主机名（如 `my-mac-mini.sgponte`）。

2. **客户端 Mac：** 确保 Surge 正在运行（增强模式或系统代理）。验证连通性：
   ```bash
   curl http://my-mac-mini.sgponte:9876/usage
   ```

3. **配置客户端 ClaudeUsageBar：**
   ```bash
   defaults write ClaudeUsageBar remote_usage_url "http://my-mac-mini.sgponte:9876"
   ```

**常见问题：**

| 症状 | 原因 | 解决 |
|------|------|------|
| Connection refused | 服务端 ClaudeUsageBar 未运行 | 确认服务端在跑且 9876 端口在监听（`lsof -i :9876`） |
| 无法解析 .sgponte | 客户端 Surge 未启用增强模式 | 开启 Surge Enhanced Mode |
| ATS 拦截 HTTP | macOS App Transport Security | 本应用使用 raw TCP socket 绕过 ATS，确保安装最新版本 |
| 数据显示 "Remote: error" | 网络不通或 URL 错误 | 先用 `curl` 验证 URL 可达 |

### 内部实现

- **本地模式（服务端）：** 应用启动时通过 `Network.framework` 的 `NWListener` 在 9876 端口开启轻量 TCP 服务器。每次从 Anthropic 拿到新数据，就缓存 JSON。任何 `GET /usage` 请求都返回缓存的 JSON，附带 `X-Cached-Age` 头表示数据年龄（秒）。

- **远程模式（客户端）：** 不调 Anthropic API，而是通过 raw TCP socket（完全绕过 ATS）连接服务端，发送最简 HTTP/1.1 GET 请求，解码相同的 `UsageResponse` JSON。UI 完全一致 — 唯一区别是蓝色的 `REMOTE` 标签。

**为什么用 raw TCP socket？**

macOS 上，即使在 Info.plist 中设置了 `NSAllowsArbitraryLoads`，`URLSession` 仍然可能拦截对非标准域名的 HTTP 明文请求。raw TCP socket（`InputStream`/`OutputStream`）工作在更底层，不受 ATS 约束。

## 状态说明

| 菜单栏显示 | 含义 |
|-----------|------|
| `⚡35% 📅4%` | 正常运行 |
| `⏳ ...` | 加载中 |
| `🔑 Login` | 未登录 — 点击弹窗中的 Login 按钮 |
| `🔒 Auth` | Token 过期 — 应用将自动尝试 Delegated CLI Refresh |
| `⚠️ Error` | API 错误（限速、网络等）— 指数退避中 |
| `[REMOTE]` 标签 | 客户端模式，从远程服务器读取数据 |
| `[LOCAL]` 标签 | 服务端模式，向其他 Mac 提供数据 |

## 项目结构

```
Sources/
├── main.swift             # 应用入口
├── AppDelegate.swift      # 状态栏 + 弹窗 + 自适应刷新 + 凭证监听 + 登录轮询
├── OAuthManager.swift     # 多源凭证读取 + DelegatedCLIRefresh
├── OAuthFailureGate.swift # 双层 FailureGate（Keychain+File fingerprint 自动解锁）
├── UsageAPI.swift         # Anthropic OAuth 用量 API + raw TCP 远程拉取
├── UsageServer.swift      # 内嵌 HTTP 服务器，支持多机共享
├── UsageModel.swift       # Codable 数据模型
├── UsageStore.swift       # 历史用量持久化
├── PopoverView.swift      # SwiftUI 弹窗（进度条 + 登录流程 + 远程模式配置）
├── StatsView.swift        # 用量统计与热力图
└── LaunchAtLogin.swift    # 基于 LaunchAgent 的开机自启开关
```

## 配置

单机使用无需任何配置，应用自动读取 Claude Code 凭证。

多机使用见 [远程模式](#远程模式)。

## 许可证

MIT

## 致谢

由 🦞 [OpenClaw](https://github.com/openclaw/openclaw) 驱动构建。
