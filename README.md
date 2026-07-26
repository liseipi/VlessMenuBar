# VlessMenuBar — macOS 代理管理工具（主窗口版）

给 `vless-ws-client` 做的 macOS 图形界面：状态栏图标 + 一个带侧边栏导航的主窗口
（仪表板 / 代理配置 / 系统代理 / 本地代理 / 运行日志 / 偏好设置），内置了
`darwin-amd64` 和 `darwin-arm64` 两个版本的可执行文件，运行时自动挑选跟当前
Mac 匹配的那个。

> **重要提醒**：这份代码是在 Linux 沙盒环境里写的，**没有 macOS，没法在这
> 编译或运行验证**。Go 那部分我是真的编译测试过的，但这份
> Swift/AppKit/SwiftUI 代码没有。逻辑上是按官方 API 规范写的，vless 链接的
> 编解码逻辑额外用等价算法在 Python 里跑过完整往返测试，但整个 App 编译起来
> 你大概率还是会碰到一些问题，报错发我可以继续帮你调。

## 界面结构

```
┌─────────────┬──────────────────────────────────────┐
│ VlessProxy  │  代理已停止 / 运行中          [启停按钮] │
│ 已停止/运行中 │                                        │
├─────────────┤  ┌本地端口┐ ┌运行时长┐                    │
│ 仪表板       │  └────────┘ └────────┘                    │
│ 代理配置     │                                        │
│ 系统代理     │  当前节点                               │
│ 本地代理     │  配置名称 / 服务器 / UUID / 传输方式 ... │
│ 运行日志     │                                        │
│ 偏好设置     │  代理功能状态                           │
│             │  系统代理 / 局域网共享                   │
├─────────────┤                                        │
│ 监听端口     │                                        │
│ 127.0.0.1:.. │                                        │
└─────────────┴──────────────────────────────────────┘
```

点状态栏图标：左键开关主窗口，右键弹出"启停代理/打开主窗口/退出"快捷菜单。

## 功能对照

| 功能 | 实现方式 |
|---|---|
| 增加/编辑配置 | "代理配置"页面，支持保存多个节点 |
| SOCKS5+HTTP 共用端口 | 复用 Go 客户端本来就有的能力 |
| 局域网代理 | "本地代理"页面开关，全局设置，跟具体节点无关 |
| 一键系统代理 | "系统代理"页面，内部调用 `networksetup` |
| 导入/导出配置 | 合并进了"代理配置"页面：支持从文件导入、从 vless:// 链接导入；每个节点支持导出文件、复制链接、生成二维码 |
| 开机自启动 | "偏好设置"页面，macOS 13+ 用 `SMAppService`，macOS 12 用 LaunchAgent 兜底 |
| 菜单栏图标 | `NSStatusItem` + `.accessory` 激活策略，不占 Dock |

## 目录结构

```
VlessMenuBar/
├── Package.swift
├── Info.plist
├── build-app.sh
├── AppIcon.iconset/             # App 图标全部尺寸，build-app.sh 会转成 .icns
├── Sources/VlessMenuBar/
│   ├── main.swift
│   ├── AppDelegate.swift        # 状态栏图标 + 主窗口显示/隐藏 + 右键快捷菜单 + 主菜单
│   ├── AppStore.swift           # 全局状态：节点列表、运行状态、运行时长、日志
│   ├── Config.swift             # ProxyConfig / ProxyProfile / ProfileStore / LocalProxySettings
│   ├── ConfigFormFields.swift   # 可复用的节点表单字段
│   ├── CollapsibleSection.swift # 自制可折叠区域
│   ├── VlessLink.swift          # vless:// 链接编码/解码
│   ├── QRCodeGenerator.swift    # 用 CoreImage 生成二维码
│   ├── QRCodeSheet.swift        # 二维码展示弹窗
│   ├── ProxyProcess.swift       # 管理 vless-ws-client 子进程
│   ├── SystemProxyManager.swift
│   ├── LoginItemManager.swift
│   ├── MainContentView.swift    # 侧边栏 + 详情区整体布局
│   ├── DashboardView.swift      # 仪表板页面
│   ├── ProfilesView.swift       # 代理配置页面（节点列表 + 导入导出 + 链接/二维码）
│   ├── SystemProxyView.swift    # 系统代理页面
│   ├── LocalProxyView.swift     # 本地代理页面（全局本地 IP/端口 + 局域网共享）
│   ├── LogsView.swift           # 运行日志页面
│   ├── PreferencesView.swift    # 偏好设置页面
│   └── Resources/
│       ├── vless-ws-client-darwin-amd64
│       └── vless-ws-client-darwin-arm64
```

## 环境要求

- **运行**：macOS 12 (Monterey) 或更新即可；开机自启动在 macOS 13+ 用系统的
  `SMAppService`（跟"系统设置 -> 登录项"是同一套），macOS 12 用一个手写的
  LaunchAgent 兜底，效果类似但不会出现在系统那个登录项列表里。
- **编译**：Xcode 或 Xcode Command Line Tools：`xcode-select --install`

## 编译 & 打包

```bash
cd VlessMenuBar
./build-app.sh
```

编译完成后 App 在 `dist/VlessMenuBar.app`。第一次运行：

```bash
xattr -cr dist/VlessMenuBar.app
open dist/VlessMenuBar.app
```

快速调试（不打包成 .app，开机自启动功能不可用，其他都正常）：

```bash
swift run
```

## 使用流程

1. 打开 App，点"代理配置" -> "新增节点"，填服务器信息，保存
2. 回到"仪表板"，点右上角绿色播放按钮启动
3. 需要全局代理效果：去"系统代理"页面开关（会提示先启动代理）
4. 需要给局域网内其他设备用：去"本地代理"页面开局域网共享开关，会显示能用的局域网 IP
5. 需要开机自动跑起来：去"偏好设置"开"开机自启动"
6. 需要分享某个节点给别人：在"代理配置"列表里，点节点右边的复制图标/二维码
   图标，或者点顶部"导出"另存成文件

## vless:// 链接格式

```
vless://{uuid}@{host}:{port}?encryption=none&security=tls&type=ws&host={host头}&path={路径}&sni={sni}&token={token}#{节点名称}
```

`token` 是这个项目自己加的非标准参数（标准 VLESS 协议没有 token 概念），拿去
其他工具导入时会被忽略，不影响兼容性；反过来其他标准 VLESS 分享链接如果没有
`token` 参数，导入到这里也完全没问题（Token 字段就是空的）。

## 已知需要你在自己机器上核实/可能要改的地方

1. **内嵌二进制的定位方式**：`ProxyProcess.swift` 里优先从
   `Bundle.main.resourceURL`（即打包好的 `.app` 包里 `Contents/Resources/`
   目录）查找两个 `vless-ws-client` 二进制，找不到才退回 `Bundle.module`。
   `build-app.sh` 会把这两个文件直接拷贝到 `Contents/Resources/`，如果自己
   改过打包流程，注意保持这个位置一致。
2. **`Info.plist` 里的 bundle identifier** 是占位符 `com.example.vlessmenubar`，
   建议改成你自己的。
3. **`networksetup` 的网络服务名称**：中文系统下 Wi-Fi 服务名称显示是否跟
   代码假设的一致没有实测过，"设为系统代理"没反应的话，先手动跑一下
   `networksetup -listallnetworkservices` 看输出对不对。
4. **首次开机自启动可能需要手动批准**：系统设置里会要求确认一次，这是系统
   机制不是 bug。
5. **二维码渲染**：用的是系统自带 `CIQRCodeGenerator` 滤镜放大生成，具体显示
   效果我这边没法预览，如果显示有问题（太糊/太大/太小），`QRCodeGenerator.swift`
   里的 `scale` 参数可以调。

## 与 Go 客户端的关系

这个 App 本身不实现任何代理逻辑，是 `vless-ws-client-darwin-amd64` /
`vless-ws-client-darwin-arm64` 的图形界面壳：表单配置转成命令行参数，
`Process` 启动对应架构的二进制。以后 Go 客户端加新参数，对应到
`Config.swift` 的 `commandLineArguments()` 加一行、`ConfigFormFields.swift`
表单里加个输入框即可。
