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
- **自动刷新** — 正常 5 分钟，异常时 30 秒快速恢复
- **远程访问** — 通过 HTTPS Bridge 从任何 Mac 远程查看（Surge Ponte / Tailscale / 局域网）
- **Session 保活** — 常驻后台标签页自动刷新 Session，防止锁屏后过期
- **自动重试** — Auth 失败时自动清缓存、重建标签页、重试
- **可配置 CDP** — 设置面板自定义 Chrome CDP 地址和端口
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
    <key>KeepAlive</key>
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
cp -r "Claude Usage Bar.app" /Applications/
open "/Applications/Claude Usage Bar.app"
```

### 3. 配置 Organization ID

应用默认使用作者的 Organization ID。使用你自己的：

1. 在 Chrome 中打开 `https://claude.ai/settings/usage`，按 F12 打开开发者工具 → Network 面板
2. 找到对 `/api/organizations/{org-id}/usage` 的请求
3. 复制你的 `org-id`，更新 `Sources/UsageAPI.swift` 中的值

## 远程访问（多 Mac 方案）

想在 MacBook 上查看 Mac Mini 的 Claude 用量？应用支持通过 HTTPS Bridge 远程连接 CDP。

### 架构

```
MacBook                          Mac Mini
┌─────────────┐    HTTPS/WSS    ┌──────────────┐    HTTP/WS    ┌─────────────┐
│ Usage Bar   │ ──────────────→ │ CDP Bridge   │ ────────────→ │ Chrome CDP  │
│ (端口 9223) │  Ponte/局域网   │ (端口 9223)  │   localhost   │ (端口 9222) │
└─────────────┘                 └──────────────┘               └─────────────┘
```

### 为什么需要 Bridge？

Chrome CDP 强制绑定 `127.0.0.1`，不接受非 localhost 的 Host header。Bridge 做两件事：
1. **HTTPS 加密** — 绕过 macOS ATS 对 HTTP 明文的限制
2. **Host 重写** — 把远程请求的 Host 改写为 `127.0.0.1`，Chrome 才接受

### 1. 生成自签证书（在运行 Chrome 的 Mac 上）

```bash
mkdir -p ~/.openclaw/certs
openssl req -x509 -newkey rsa:2048 \
  -keyout ~/.openclaw/certs/cdp-bridge-key.pem \
  -out ~/.openclaw/certs/cdp-bridge-cert.pem \
  -days 3650 -nodes \
  -subj "/CN=cdp-bridge" \
  -addext "subjectAltName=DNS:你的主机名,DNS:localhost,IP:127.0.0.1"
```

### 2. 部署 HTTPS Bridge

保存为 `~/.openclaw/scripts/cdp-bridge.js`：

```javascript
const https = require('https');
const http = require('http');
const fs = require('fs');
const net = require('net');
const path = require('path');

const LISTEN_PORT = 9223;
const CDP_HOST = '127.0.0.1';
const CDP_PORT = 9222;

const CERT_DIR = path.join(process.env.HOME, '.openclaw', 'certs');
const tlsOptions = {
  key: fs.readFileSync(path.join(CERT_DIR, 'cdp-bridge-key.pem')),
  cert: fs.readFileSync(path.join(CERT_DIR, 'cdp-bridge-cert.pem')),
};

const server = https.createServer(tlsOptions, (req, res) => {
  const options = {
    hostname: CDP_HOST, port: CDP_PORT,
    path: req.url, method: req.method,
    headers: { ...req.headers, host: `${CDP_HOST}:${CDP_PORT}` }
  };
  const proxy = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });
  proxy.on('error', (e) => { res.writeHead(502); res.end(e.message); });
  req.pipe(proxy);
});

server.on('upgrade', (req, socket, head) => {
  const target = net.connect(CDP_PORT, CDP_HOST, () => {
    const headers = { ...req.headers, host: `${CDP_HOST}:${CDP_PORT}` };
    let rawReq = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [key, value] of Object.entries(headers))
      rawReq += `${key}: ${value}\r\n`;
    rawReq += '\r\n';
    target.write(rawReq);
    if (head.length) target.write(head);
    target.pipe(socket);
    socket.pipe(target);
  });
  target.on('error', () => socket.destroy());
  socket.on('error', () => target.destroy());
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`CDP bridge (HTTPS) on 0.0.0.0:${LISTEN_PORT} → ${CDP_HOST}:${CDP_PORT}`);
});
```

### 3. 创建 LaunchAgent

```bash
cat > ~/Library/LaunchAgents/com.openclaw.cdp-bridge.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.cdp-bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/node</string>
        <string>/Users/你的用户名/.openclaw/scripts/cdp-bridge.js</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.openclaw.cdp-bridge.plist
```

### 4. 配置远端 Mac 上的 App

1. 在远端 Mac 上编译安装
2. 点击菜单栏图标 → **Settings**
3. **Host** 填服务器主机名（如 `my-mac-mini.ponte` 或局域网 IP）
4. **Port** 填 `9223`
5. 点 **Save & Reconnect**

应用会自动对远程主机使用 HTTPS/WSS 并接受自签证书。

### 网络方案对比

| 方案 | 优点 | 缺点 |
|------|------|------|
| **Surge Ponte** | 任何网络都能用 | 需要 Surge 许可 |
| **Tailscale** | 免费，任何网络 | 需要安装配置 |
| **局域网 IP** | 最简单，无需额外配置 | 只能在同一网络 |

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
├── AppDelegate.swift       # NSStatusItem + NSPopover + 自适应刷新
├── UsageAPI.swift          # API 客户端（Auth 失败自动重试）
├── CDPCookieManager.swift  # CDP Cookie 提取 + 常驻标签页保活
├── UsageModel.swift        # Codable 数据模型
├── PopoverView.swift       # SwiftUI 弹窗视图（进度条）
└── SettingsView.swift      # CDP 地址/端口配置面板
```

### Cookie 提取流程

1. 通过 WebSocket 连接 Chrome CDP 浏览器端点（WS 或 WSS）
2. 复用常驻 `claude.ai` 后台标签页（不存在则创建）
3. 通过 `Network.getCookies` 提取 Cookie
4. 从标签页分离但保持活跃（前端 JS 自动刷新 Session）
5. Cookie 缓存 4 分钟，减少 CDP 调用
6. Auth 失败时：清缓存 → 清理旧标签页 → 重建 → 重试

### Session 保活机制

应用在 Chrome CDP 中维护一个常驻的 `claude.ai` 标签页。Claude 前端 JavaScript 会自动刷新 Session Token，防止空闲或锁屏期间 Session 过期。旧标签页会自动清理，防止堆积。

### 自适应刷新频率

| 状态 | 刷新间隔 |
|------|---------|
| 正常（`⚡%`）| 每 5 分钟 |
| 异常 / Auth / CDP | 每 30 秒 |

异常时快速轮询，正常后自动降频，兼顾恢复速度和资源消耗。

## 状态说明

| 菜单栏显示 | 含义 |
|-----------|------|
| `⚡30% 📅19%` | 正常运行 |
| `⏳ ...` | 加载中 / 首次获取 |
| `⛔ CDP` | Chrome CDP 不可用 |
| `🔒 Auth` | Session 过期 — 需重新登录 claude.ai |
| `⚠️ Error` | 网络或 API 错误 |

## 安全说明

- **Chrome CDP（端口 9222）** 仅监听 `127.0.0.1` — 外部无法访问
- **CDP Bridge（端口 9223）** 监听 `0.0.0.0` — 仅在需要远程访问时启用
- Bridge 使用 HTTPS 自签证书 — 流量加密传输
- 不向任何第三方服务器发送数据 — 所有通信仅在你的设备之间
- 如果网络环境不可信，建议为 Bridge 添加认证

## 许可证

MIT

## 致谢

由 🦞 [OpenClaw](https://github.com/openclaw/openclaw) 驱动构建。
