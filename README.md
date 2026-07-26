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
| 开机自启动 | "偏好设置"页面，用 macOS 13+ 的 `SMAppService` |
| 菜单栏图标 | `NSStatusItem` + `.accessory` 激活策略 |

## 这一版的主要改动

1. **去掉了 Go 客户端的本地统计接口**：之前给仪表板显示活跃连接数/上传下载
   速度专门加过一个 `/stats` 接口，考虑到额外监听一个端口有跟其他服务冲突的
   风险，这次整个去掉了，`vless-ws-client` 恢复成只监听一个端口。仪表板现在
   显示的"运行时长"是纯本地计时（从点击启动的那一刻算起），不依赖任何网络
   请求。
2. **本地代理设置是全局的，不属于任何一个节点**：本地监听 IP/端口在独立的
   "本地代理"页面统一配置，所有节点共用同一份；节点编辑表单里不再有这些字段。
3. **导入配置合并进了"代理配置"页面**：去掉了单独的侧边栏入口。每个节点现在
   支持三种导出方式：导出成 JSON 文件、复制 `vless://` 分享链接、生成二维码
   （用系统自带的 CoreImage 生成，没有额外依赖）；导入支持选文件或者直接粘贴
   一个 `vless://` 链接。

## 目录结构

```
VlessMenuBar/
├── Package.swift
├── Info.plist
├── build-app.sh
├── AppIcon.iconset/             # App 图标全部尺寸，build-app.sh 会转成 .icns
├── Sources/VlessMenuBar/
│   ├── main.swift
│   ├── AppDelegate.swift       # 状态栏图标 + 主窗口显示/隐藏 + 右键快捷菜单
│   ├── AppStore.swift          # 全局状态：节点列表、运行状态、运行时长、日志
│   ├── Config.swift            # ProxyConfig / ProxyProfile / ProfileStore / LocalProxySettings
│   ├── ConfigFormFields.swift  # 可复用的节点表单字段
│   ├── CollapsibleSection.swift # 自制可折叠区域（替代 macOS 上有问题的 DisclosureGroup）
│   ├── VlessLink.swift         # vless:// 链接编码/解码
│   ├── QRCodeGenerator.swift   # 用 CoreImage 生成二维码
│   ├── QRCodeSheet.swift       # 二维码展示弹窗
│   ├── ProxyProcess.swift      # 管理 vless-ws-client 子进程
│   ├── SystemProxyManager.swift
│   ├── LoginItemManager.swift
│   ├── MainContentView.swift   # 侧边栏 + 详情区整体布局
│   ├── DashboardView.swift     # 仪表板页面
│   ├── ProfilesView.swift      # 代理配置页面（节点列表 + 导入导出 + 链接/二维码）
│   ├── SystemProxyView.swift   # 系统代理页面
│   ├── LocalProxyView.swift    # 本地代理页面（全局本地 IP/端口 + 局域网共享）
│   ├── LogsView.swift          # 运行日志页面
│   ├── PreferencesView.swift   # 偏好设置页面
│   └── Resources/
│       ├── vless-ws-client-darwin-amd64
│       └── vless-ws-client-darwin-arm64
```

## 环境要求

- **运行**：macOS 12 (Monterey) 或更新即可；开机自启动在 macOS 13+ 用系统的
  `SMAppService`（跟"系统设置 -> 登录项"是同一套），macOS 12 用一个手写的
  LaunchAgent 兜底，效果类似但不会出现在系统那个登录项列表里。
- **编译**：Xcode 或 Xcode Command Line Tools：`xcode-select --install`
  （用什么版本的 Xcode 编译跟运行时最低支持的系统版本是两回事，编译好的
  App 该支持到 macOS 12 还是支持到 macOS 12，不会因为你用的 Xcode 更新就变化）
- 新版本的 macOS（Sequoia 及以后）不用做任何额外适配，SwiftUI/AppKit 的
  API 是向后兼容设计的；用较新 Xcode 编译时可能会看到 `NavigationView`
  相关的"已弃用"编译警告，这是预期之内的——用它就是为了兼容 macOS 12，
  等以后不需要兼容这么老的系统了，可以换回 `NavigationSplitView`。

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

