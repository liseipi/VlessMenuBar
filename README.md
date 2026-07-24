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

## 这次修的两个 bug

1. **点击"停止"后提示"启动失败，退出码 15"**：`stop()` 发送终止信号后，
   子进程的 `terminationHandler` 回调还是会异步触发一次，这时候看到的退出码
   是 15（SIGTERM，就是我们自己发的终止信号），但代码逻辑简单地把"退出码不是
   0"都当成异常退出处理，等于自己终止自己却被判定成失败，把刚设好的"已停止"
   状态覆盖掉了。修法是用"进程身份对比"代替简单的退出码判断：`stop()` 里先
   把 `self.process` 设成 `nil` 再发终止信号，等终止回调真正触发时检查
   "这次通知对应的进程是不是我们当前还在追踪的那一个"，如果不是（因为已经
   被主动停止，或者又重新启动了新的），就直接忽略这次通知，不会再覆盖状态。
2. **点击启动后侧边栏短暂变灰、过一会儿才能点**：根源是拉起子进程这几步
   （文件权限检查、`Process.run()`）之前是在主线程上同步执行的，其中系统
   第一次运行这个内嵌可执行文件时会做一次安全评估（Gatekeeper/AMFI 签名
   校验），这个过程偶尔会有明显耗时，主线程被卡住期间整个界面都没法响应
   点击。现在把这几步都挪到了后台线程，只有真正涉及界面状态的部分才切回
   主线程，界面全程保持响应，点击"启动"的瞬间就会立刻看到"正在启动"的反馈，
   不用等后台干完活。

## 这次的改动：Gatekeeper 警告 + 系统版本兼容范围 + 不再占用 Dock

1. **"Apple 无法验证...可能危害 Mac 安全"**：不是签名本身的问题（ad-hoc
   签名一直都有），根源是内嵌的两个 `vless-ws-client` 二进制从最初下载解压
   项目压缩包开始就带着"隔离属性"（quarantine），这个属性会一路跟着从源码
   目录 → `.build` 编译缓存 → 最终打包进 `.app`，就算对着编译出来的 `.app`
   跑过 `xattr -cr` 清干净，下次重新执行 `build-app.sh` 又会用带着隔离属性
   的源文件重新生成一份，等于每次重新打包都"复发"。`build-app.sh` 现在会在
   编译最开始、以及编译完成后，分别对源码目录和 `.build` 缓存自动清一遍，
   一次性解决，不用你自己记得手动清。
2. **系统版本兼容范围**：最低支持从 macOS 13 降到了 macOS 12 (Monterey)。
   具体做的事：
   - 侧边栏导航从 `NavigationSplitView`（macOS 13+ 专属）换成了老式的
     `NavigationView` + tag/selection 版 `NavigationLink`，这套写法从
     SwiftUI 最早期（macOS 10.15）就能用，视觉效果完全一样。
   - 开机自启动：macOS 13+ 继续用 `SMAppService`；macOS 12 用手写的
     LaunchAgent plist 兜底（`LoginItemManager.swift` 里做了版本判断，
     两条路径自动切换，界面上完全无感）。
   - `@FocusState`（自动聚焦输入框）和 `.textSelection`（日志/二维码弹窗
     里选中复制文字）都需要 macOS 12，这是往下能降到的实际极限——再往下
     （比如 macOS 11 或更早）这两个功能就得跟着一起阉割，权衡下来 macOS 12
     是比较合理的下限。
   - 往上（比如以后的 macOS 版本）不需要做任何事，SwiftUI/AppKit 一直是
     向后兼容设计的，新系统直接能跑。
3. **不再出现在 Dock（底部任务栏）里**：之前主窗口打开的时候，App 会临时
   切换成"正常策略"（`.regular`），这时候 Dock 里会短暂出现一个图标，关闭
   窗口后才切回去。现在改成不管主窗口开不开，全程都是纯状态栏模式
   （`.accessory`），只有菜单栏图标，Dock 里永远不会出现。窗口本身该怎么用
   还是怎么用（可以正常输入、复制粘贴、弹出菜单），唯一区别就是不占 Dock。

## 这次修的交互问题

1. **表单里 Cmd+C/Cmd+V 不能用**：根本原因是这个 App 一直没有设置过
   `NSApp.mainMenu`——macOS 上 Cmd+C/V/X/A 这些标准编辑快捷键是靠主菜单里的
   Edit 菜单"翻译"成实际动作的，不是文本框天生就会响应。`AppDelegate.swift`
   里加了一个最小的标准主菜单（App 菜单 + Edit 菜单），这些快捷键现在应该都
   能正常用了。
2. **"高级选项"点击区域太小，只有箭头能点**：一开始以为是 `DisclosureGroup`
   自定义 label 没撑满宽度，加了 `frame(maxWidth: .infinity)` +
   `contentShape` 还是不行——后来确认这是 **macOS 平台本身的限制**：
   `DisclosureGroup` 在 macOS 上不管 label 内容和宽度怎么设置，实际可点击
   展开/收起的热区就是只有那个箭头图标本身，label 文字点了没反应，这个在
   iOS 上是正常的，只有 macOS 有这个问题。所以干脆不用 `DisclosureGroup`了，
   新加了一个 `CollapsibleSection.swift`，用一个 `Button` 把标题文字+箭头
   整行包起来，只依赖 `Button` 本身可靠的点击行为，点这一行任意位置都能用。
3. **App 图标**：`AppIcon.iconset/` 里放了一套蓝紫渐变 + 盾牌 + 闪电主题的
   图标（全部尺寸已经生成好），`build-app.sh` 里加了用 `iconutil`（macOS
   自带工具）把它转成 `.icns` 并塞进 App 包的步骤，`Info.plist` 也加了对应
   的 `CFBundleIconFile` 声明，打包出来的 App 现在会有一个像样的图标，不是
   系统默认的空白方块。
4. **顺手检查了全项目类似的交互问题**（上一版已修）：
   - "系统代理"/"本地代理"/"偏好设置"里的几个开关，标题整行都在开关的点击
     范围内了，跟系统设置里的开关行为一致。
   - "代理配置"列表每一行的图标按钮加了内边距扩大点击热区。
   - 五个图标挤一起容易点错，把有风险的操作（导出、删除）收进了"更多"菜单。
   - 各个弹窗的"取消"按钮加了 Esc 快捷键。
   - "新增/编辑节点"弹窗打开自动聚焦到"节点名称"输入框。

## 已知需要你在自己机器上核实/可能要改的地方

1. **`Bundle.module` 资源路径**：`ProxyProcess.swift` 里用 `Bundle.module` 找
   打包进去的两个二进制，SwiftPM 不同版本生成 bundle 的路径细节可能有出入，
   报"找不到内置可执行文件"的话，去 `.build/release/` 下面看实际生成的
   `.bundle` 目录名，跟 `build-app.sh` 里 `RESOURCE_BUNDLE` 那行对一下。
2. **`Info.plist` 里的 bundle identifier** 是占位符 `com.example.vlessmenubar`，
   建议改成你自己的。
3. **`networksetup` 的网络服务名称**：中文系统下 Wi-Fi 服务名称显示是否跟
   代码假设的一致没有实测过，"设为系统代理"没反应的话，先手动跑一下
   `networksetup -listallnetworkservices` 看输出对不对。
4. **首次开机自启动可能需要手动批准**：系统设置里会要求确认一次，这是系统
   机制不是 bug。
5. **二维码渲染**：用的是系统自带 `CIQRCodeGenerator` 滤镜放大生成，逻辑标准，
   但具体显示效果（清晰度、尺寸是否合适）我这边没法预览，如果显示有问题
   （太糊/太大/太小），`QRCodeGenerator.swift` 里的 `scale` 参数可以调。

## 与 Go 客户端的关系

这个 App 本身不实现任何代理逻辑，是 `vless-ws-client-darwin-amd64` /
`vless-ws-client-darwin-arm64` 的图形界面壳：表单配置转成命令行参数，
`Process` 启动对应架构的二进制。以后 Go 客户端加新参数，对应到
`Config.swift` 的 `commandLineArguments()` 加一行、`ConfigFormFields.swift`
表单里加个输入框即可。
