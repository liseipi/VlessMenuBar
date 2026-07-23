import SwiftUI

struct SystemProxyView: View {
    @EnvironmentObject var store: AppStore
    @State private var services: [SystemProxyManager.NetworkService] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统代理").font(.title2).bold()

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { store.systemProxyIsOn },
                    set: { _ in store.toggleSystemProxy() }
                )) {
                    HStack {
                        Image(systemName: "globe")
                            .font(.system(size: 22))
                            .foregroundStyle(store.systemProxyIsOn ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.systemProxyIsOn ? "系统代理已启用" : "系统代理未启用")
                                .font(.headline)
                            Text(store.systemProxyIsOn
                                 ? "系统的 SOCKS5 / HTTP / HTTPS 代理已指向本地代理端口"
                                 : "开启后，Mac 上所有走系统代理设置的 App 都会经过这里")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .disabled(!store.isRunning)

                if !store.isRunning {
                    Label("请先在「仪表板」启动代理，再开启这个开关", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("当前网络服务").font(.headline)
                    Spacer()
                    Button("刷新") { refreshServices() }
                }
                if services.isEmpty {
                    Text("没有检测到已启用的网络服务").foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(services, id: \.name) { service in
                        HStack {
                            Image(systemName: "wifi")
                            Text(service.name)
                            Spacer()
                            if store.systemProxyIsOn {
                                Text("已应用代理").font(.caption).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            Text("原理：调用 macOS 自带的 networksetup 命令，把当前网络服务的 SOCKS5/HTTP/HTTPS 代理都设置成 127.0.0.1:本地端口。关闭这个开关只是把代理状态设为「关」，不会清空已经填好的地址，下次开启还是一样的设置。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .onAppear { refreshServices() }
    }

    private func refreshServices() {
        services = SystemProxyManager.listActiveServices()
    }
}
