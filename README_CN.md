# Claude Usage Bar

<p align="center">
  <img src="screenshots/icon.png" width="128" alt="Claude Usage Bar Icon">
</p>

<p align="center">
  <strong>原生 macOS 菜单栏应用，实时监控 Claude Max 订阅用量。</strong>
</p>

<p align="center">
  <img src="screenshots/menubar.png" alt="菜单栏" height="32">
</p>

<p align="center">
  <img src="screenshots/popover.png" alt="详情面板" width="400">
</p>

## 功能

- **菜单栏显示** — 一眼看到 Session（5h）和 Weekly（7d）用量：`⚡47% 📅20%`
- **详情弹窗** — 点击展开进度条、百分比、重置倒计时
- **颜色分级** — 绿色（<50%）→ 橙色（50-80%）→ 红色（>80%）
- **Sonnet 独立追踪** — 单独显示 Sonnet 模型用量
- **自动刷新** — 每 5 分钟更新一次
- **优雅降级** — Chrome CDP 不可用或认证过期时显示清晰状态
- **零依赖** — 纯 Swift + SwiftUI + AppKit，无第三方库
- **静默运行** — 仅菜单栏图标，不在 Dock 显示

## 工作原理

Claude Max 订阅有用量限制，但没有公开 API 可查。本应用通过 [Chrome DevTools Protocol (CDP)](https://chromedevtools.github.io/devtools-protocol/) 从 Chrome 提取 Session Cookie，调用 `claude.ai/settings/usage` 使用的内部 API。

```
Chrome CDP (端口 9222) → 提取 Cookie → claude.ai/api/organizations/{id}/usage → 菜单栏
```

## 系统要求

- **macOS 15.0+**（Apple Silicon）
- **Google Chrome** 以 `--remote-debugging-port=9222` 模式运行
- 在 CDP Chrome 实例中**已登录** [claude.ai](https://claude.ai)
- **Claude Max** 订阅（Pro/Team 应该也能用）

## 安装

### 1. 启动 Chrome CDP

创建 LaunchAgent 让 Chrome 以远程调试模式运行：

```bash
cat > ~/Library/LaunchAgents/com.claude-usage.chrome-cdp.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-usage.chrome-cdp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Google Chrome.app/Contents/MacOS/Google Chrome</string>
        <string>--remote-debugging-port=9222</string>
        <string>--user-data-dir=${HOME}/.chrome-cdp-data</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.claude-usage.chrome-cdp.plist
```

然后在打开的 Chrome 窗口中登录 [claude.ai](https://claude.ai)。

### 2. 编译安装

```bash
git clone https://github.com/jsjixu/ClaudeUsageBar.git
cd ClaudeUsageBar
./build.sh
./install.sh
```

或手动安装：

```bash
./build.sh
cp -r "Claude Usage Bar.app" /Applications/
open "/Applications/Claude Usage Bar.app"
```

### 3. 配置 Organization ID

应用默认使用作者的 Organization ID。使用你自己的：

1. 在 Chrome 中打开 `https://claude.ai/settings/usage`，按 F12 打开开发者工具 → Network 面板
2. 找到对 `/api/organizations/{org-id}/usage` 的请求
3. 复制你的 `org-id`，更新 `Sources/UsageAPI.swift` 中的值

## 从源码构建

只需要 Xcode Command Line Tools（不需要完整 Xcode）：

```bash
xcode-select --install  # 如果尚未安装
./build.sh
```

构建脚本使用 `swiftc` 编译并生成签名的 `.app` Bundle。

## 项目结构

```
Sources/
├── main.swift              # 应用入口
├── AppDelegate.swift       # NSStatusItem + NSPopover 管理
├── UsageAPI.swift          # API 客户端（模拟浏览器请求头）
├── CDPCookieManager.swift  # Chrome DevTools Protocol Cookie 提取
├── UsageModel.swift        # Codable 数据模型
└── PopoverView.swift       # SwiftUI 弹窗视图（进度条）
```

### Cookie 提取流程

1. 通过 WebSocket 连接 Chrome CDP 浏览器端点
2. 创建隐藏 Target（`about:blank`）
3. 导航至 `claude.ai` 激活 Cookie
4. 通过 `Network.getCookies` 提取 Cookie
5. 关闭隐藏 Target（不会打开可见标签页）
6. Cookie 缓存 4 分钟，减少 CDP 调用

## 状态说明

| 菜单栏显示 | 含义 |
|-----------|------|
| `⚡30% 📅19%` | 正常运行 |
| `⏳ ...` | 加载中 / 首次获取 |
| `⛔ CDP` | Chrome CDP 不可用（端口 9222） |
| `🔒 Auth` | Session 过期 — 需重新登录 claude.ai |
| `⚠️ Error` | 网络或 API 错误 |

## 许可证

MIT

## 致谢

由 🦞 [OpenClaw](https://github.com/openclaw/openclaw) 驱动构建。
