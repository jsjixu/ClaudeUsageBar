# Claude Usage Bar

<p align="center">
  <img src="screenshots/icon.png" width="128" alt="Claude Usage Bar Icon">
</p>

<p align="center">
  <strong>原生 macOS 菜单栏应用，实时显示 Claude 的 Session 和 Weekly 用量。</strong>
</p>

<p align="center">
  <img src="screenshots/menubar.png" alt="菜单栏" height="32">
</p>

<p align="center">
  <img src="screenshots/popover.png" alt="详情面板" width="400">
</p>

## 功能

- **状态栏实时显示** — 常驻菜单栏：`⚡0% 📅24%`，一眼看到 Session（5h）和 Weekly（7d）用量
- **重置倒计时** — 每个窗口还有多久回血，一目了然
- **模型独立追踪** — Sonnet、Opus 周用量单独显示
- **颜色分级** — 绿色（<50%）→ 橙色（50-80%）→ 红色（>80%）
- **自动刷新** — 正常 5 分钟，异常时 30 秒快速恢复
- **开机自启** — 弹窗内一键开关
- **零依赖** — 纯 Swift + SwiftUI + AppKit，无第三方库
- **隐私优先** — 读取本地 OAuth 凭证，直接调 Anthropic API，不经过任何第三方
- **静默运行** — 仅菜单栏图标，不在 Dock 显示

## 工作原理

读取 Claude Code CLI 的 OAuth 凭证（macOS 钥匙串），调用 Anthropic 官方用量 API。

```
Claude Code OAuth token (钥匙串) → api.anthropic.com/api/oauth/usage → 菜单栏
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

## 状态说明

| 菜单栏显示 | 含义 |
|-----------|------|
| `⚡12% 📅24%` | 正常运行 |
| `⏳ ...` | 加载中 |
| `🔒 Auth` | Token 过期 — 跑一下 `claude` 刷新 |
| `🔑 No Key` | 无凭证 — 安装 Claude Code CLI 并登录 |
| `⚠️ Error` | API 错误（限速、网络等） |

## 项目结构

```
Sources/
├── main.swift           # 应用入口
├── AppDelegate.swift    # 状态栏 + 弹窗 + 自适应刷新
├── OAuthManager.swift   # 钥匙串 + 文件凭证读取
├── UsageAPI.swift       # Anthropic OAuth 用量 API 客户端
├── UsageModel.swift     # Codable 数据模型
├── PopoverView.swift    # SwiftUI 弹窗（进度条）
└── LaunchAtLogin.swift  # 基于 LaunchAgent 的开机自启开关
```

## 配置

应用自动读取 Claude Code 凭证，无需任何配置。

## 许可证

MIT

## 致谢

由 🦞 [OpenClaw](https://github.com/openclaw/openclaw) 驱动构建。
