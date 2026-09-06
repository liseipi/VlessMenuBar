# VlessMenuBar — macOS 代理管理工具（主窗口版）

给 `vless-ws-client` 做的 macOS 图形界面：状态栏图标 + 一个带侧边栏导航的主窗口
（仪表板 / 代理配置 / 系统代理 / 本地代理 / 运行日志 / 偏好设置），内置了
`darwin-amd64` 和 `darwin-arm64` 两个版本的可执行文件，运行时自动挑选跟当前
Mac 匹配的那个。

> **重要提醒**：这份代码是在 Linux 沙盒环境里写的，**没有 macOS，没法在这
> 编译或运行验证**。我做了这几件事把风险降到最低：
> 1. Go 那部分（内置的 `vless-ws-client-darwin-*` 可执行文件）是真的交叉编译
>    测试过的，包括新加的 **tun 模式**（见下面"系统代理"一节）。
> 2. vless 链接的编解码逻辑额外用等价算法在 Python 里跑过完整往返测试。
> 3. `TunRunner.swift`（新加的、用来做提权启动 + 路由接管的核心逻辑）里用到
>    的 API（`getaddrinfo`/`getnameinfo`、`Process`/`Pipe`、`FileHandle`）
>    都是直接复用/照抄这份代码里其他地方（`LocalProxyView.swift`、
>    `ProxyProcess.swift`）已经在用的同类写法，不是凭空猜的。
> 4. 但整个 App 编译起来、以及 **`TunRunner.swift` 里生成的那段 shell 脚本
>    本身，都没有在真实 macOS 上跑过**，这是这次改动里最不确定的部分。建议
>    编译出来后先自己测一遍"开启系统代理"，如果不对劲，把
>    `~/Library/Application Support/VlessMenuBar/tun/` 目录下的
>    `tun-stdout.log` / `tun-stderr.log` 发给我，我可以照着报错继续改。

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
| 一键系统代理 | 两种方式都保留，`SystemProxyView` 里切换：**`SystemProxyManager.swift`**（传统模式，调用 `networksetup`）+ **`TunRunner.swift`**（tun 模式，创建 utun 虚拟网卡接管默认路由） |
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
│   ├── Config.swift             # ProxyConfig / ProxyProfile / ProfileStore / LocalProxySettings / TunSettings
│   ├── ConfigFormFields.swift   # 可复用的节点表单字段
│   ├── CollapsibleSection.swift # 自制可折叠区域
│   ├── VlessLink.swift          # vless:// 链接编码/解码
│   ├── QRCodeGenerator.swift    # 用 CoreImage 生成二维码
│   ├── QRCodeSheet.swift        # 二维码展示弹窗
│   ├── ProxyProcess.swift       # 管理 vless-ws-client 子进程（本地 SOCKS5/HTTP 模式）
│   ├── TunRunner.swift          # 系统代理·tun 模式：提权启动 + 路由接管/撤销
│   ├── SystemProxyManager.swift # 系统代理·传统模式：调用 networksetup（保留，两种模式都在）
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
3. 需要全局代理效果：去"系统代理"页面开关（会弹一次管理员密码确认框，用来创建虚拟网卡）
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
3. **系统代理"传统模式"和"TUN 模式"两种方式都保留**，在「系统代理」页面上方
   一个 radio 切换，开着的时候不能切（要先关再切）。传统模式沿用旧版调用
   `networksetup` 的实现，仍然依赖「仪表板」的本地代理已经在跑；tun 模式是
   独立的第二条连接，不依赖仪表板本地代理。
4. **tun 模式每次开关都会弹一次管理员密码确认框**：开启时提权启动子进程 +
   配置网卡 + 接管路由是一次；关闭时结束子进程 + 撤销路由是另一次。这是
   macOS 权限模型决定的——非 root 的 GUI 进程本身没有权限直接操作一个 root
   权限的子进程，也无法回收它改过的路由表，只能每次都单独提权处理。
5. **异常退出场景**：如果 tun 模式开着的时候 App 被强制退出（而不是正常走
   "退出"菜单/关闭系统代理开关），路由表和虚拟网卡可能会残留，需要手动执行
   `sudo route delete -net 0.0.0.0 -netmask 128.0.0.0 <网卡地址>`（以及
   `128.0.0.0` 那条）清理，或者重启一次电脑。
6. **首次开机自启动可能需要手动批准**：系统设置里会要求确认一次，这是系统
   机制不是 bug。
7. **二维码渲染**：用的是系统自带 `CIQRCodeGenerator` 滤镜放大生成，具体显示
   效果我这边没法预览，如果显示有问题（太糊/太大/太小），`QRCodeGenerator.swift`
   里的 `scale` 参数可以调。

## 与 Go 客户端的关系

这个 App 本身不实现任何代理逻辑，是 `vless-ws-client-darwin-amd64` /
`vless-ws-client-darwin-arm64` 的图形界面壳：表单配置转成命令行参数，
`Process` 启动对应架构的二进制。以后 Go 客户端加新参数，对应到
`Config.swift` 的 `commandLineArguments()` 加一行、`ConfigFormFields.swift`
表单里加个输入框即可。
