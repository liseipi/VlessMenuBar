import SwiftUI

struct SystemProxyView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft: TunSettings = TunSettings()
    @State private var errorMessage: String?
    @State private var savedJustNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统代理（TUN 模式）").font(.title2).bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("实现方式").font(.headline)

                Picker("", selection: Binding(
                    get: { store.systemProxyMode },
                    set: { store.setSystemProxyMode($0) }
                )) {
                    Text("传统模式（写系统代理设置）").tag(SystemProxyMode.legacy)
                    Text("TUN 模式（虚拟网卡接管路由）").tag(SystemProxyMode.tun)
                }
                .pickerStyle(.radioGroup)
                .disabled(store.systemProxyIsOn)
                .labelsHidden()

                Text(store.systemProxyMode == .legacy
                     ? "只对会读取系统代理设置的应用生效，需要先在「仪表板」启动本地代理"
                     : "创建虚拟网卡接管系统默认路由，覆盖面更广，不依赖应用支持读取系统代理设置，但每次开关都要弹一次管理员密码框")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if store.systemProxyIsOn {
                    Label("系统代理开启中，先关闭才能切换方式", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { store.systemProxyIsOn },
                    set: { _ in store.toggleSystemProxy() }
                )) {
                    HStack {
                        Image(systemName: "network")
                            .font(.system(size: 22))
                            .foregroundStyle(store.systemProxyIsOn ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle).font(.headline)
                            Text(statusSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)

                if store.systemProxyMode == .tun && store.activeProfile == nil {
                    Label("还没有可用节点，请先去「代理配置」新增一个", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if store.systemProxyMode == .tun {
                    Label("每次开关都会弹出管理员密码确认框，这是创建/清理虚拟网卡必需的步骤",
                          systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            if store.systemProxyMode == .tun {
                VStack(alignment: .leading, spacing: 12) {
                    Text("虚拟网卡设置").font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("网卡名").font(.caption).foregroundStyle(.secondary)
                        TextField("utun", text: $draft.adapterName)
                            .textFieldStyle(.roundedBorder)
                        Text("留 utun 表示让系统自动分配编号（推荐）；也可以填 utun5 这样的固定编号，但如果被占用会启动失败。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MTU").font(.caption).foregroundStyle(.secondary)
                            TextField("1500", value: $draft.mtu, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("网卡 IPv4 地址").font(.caption).foregroundStyle(.secondary)
                            TextField("198.18.0.1", text: $draft.address4)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Text("改动会在下次开启时生效；如果当前已开启，会自动重建一次网卡。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if savedJustNow {
                            Text("已保存").font(.caption).foregroundStyle(.green)
                        }
                        Button("保存") { save() }
                            .disabled(draft == store.tunSettings)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
            }

            Text(store.systemProxyMode == .tun
                 ? "原理：创建一张 utun 虚拟网卡，把系统写往这张网卡的所有 IP 流量都当成普通的 TCP/UDP 请求重新转发进 VLESS 隧道；同时给\"连接服务器\"这条路径本身的目标 IP 单独加一条例外路由，避免流量自己套自己。关闭时会撤销刚才接管的路由。跟传统模式（调用 networksetup 写系统代理设置）不同——不依赖 App 主动读取系统代理配置，覆盖面更广，但同时也意味着它是系统级的，请确认自己信任当前连接的节点。"
                 : "原理：调用 networksetup 把当前网络服务的 HTTP/HTTPS/SOCKS 代理指向本地监听端口，跟\"系统设置 → 网络 → 代理\"里手动勾选是同一件事，只对会主动读取系统代理设置的 App 生效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .onAppear { draft = store.tunSettings }
    }

    private var statusTitle: String {
        guard store.systemProxyIsOn else { return "系统代理未启用" }
        return store.systemProxyMode == .tun ? "系统代理已启用（TUN）" : "系统代理已启用（传统模式）"
    }

    private var statusSubtitle: String {
        if store.systemProxyMode == .tun {
            return store.systemProxyIsOn
                ? "虚拟网卡已创建，系统默认路由已接管"
                : "开启后会创建一张虚拟网卡并接管系统默认路由，几乎所有联网软件都会自动经过这里，不需要它们支持读取系统代理设置"
        } else {
            return store.systemProxyIsOn
                ? "已写入系统代理设置（HTTP/HTTPS/SOCKS），需要「仪表板」的本地代理保持运行"
                : "开启后写入系统代理设置，只对会读取该设置的应用生效，需要先在「仪表板」启动本地代理"
        }
    }

    private func save() {
        if let err = draft.validationError() {
            errorMessage = err
            return
        }
        errorMessage = nil
        store.updateTunSettings(draft)
        savedJustNow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedJustNow = false }
    }
}
