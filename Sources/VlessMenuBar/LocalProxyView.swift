import SwiftUI
import AppKit

struct LocalProxyView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft: LocalProxySettings = LocalProxySettings()
    @State private var lanIPs: [String] = []
    @State private var errorMessage: String?
    @State private var savedJustNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("本地代理").font(.title2).bold()
            Text("这是全局设置：本地监听的 IP 和端口，跟你连的是哪个远程节点无关，所有节点共用同一份本地代理设置。")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("监听地址").font(.headline)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地 IP").font(.caption).foregroundStyle(.secondary)
                        TextField("127.0.0.1", text: $draft.localIP)
                            .textFieldStyle(.roundedBorder)
                            .disabled(draft.lanEnabled)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地端口").font(.caption).foregroundStyle(.secondary)
                        TextField("1080", text: $draft.localPort)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                Text("SOCKS5 和 HTTP(S) 代理共用同一个端口，系统代理里两项都填这个端口即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { draft.lanEnabled },
                    set: { draft.lanEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("允许局域网内其他设备连接").font(.headline)
                        Text(draft.lanEnabled
                             ? "本地 IP 已固定为 0.0.0.0，同一局域网的手机/电脑可以把这台 Mac 当代理用"
                             : "关闭时本地 IP 是 127.0.0.1，只有这台 Mac 自己能用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if draft.lanEnabled {
                    Divider()
                    Text("局域网内其他设备连接方式").font(.subheadline).bold()
                    if lanIPs.isEmpty {
                        Text("没有检测到局域网 IP（可能没连 Wi-Fi/网线）")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(lanIPs, id: \.self) { ip in
                            HStack {
                                Text("\(ip):\(draft.localPort)")
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button {
                                    copyToClipboard("\(ip):\(draft.localPort)")
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .padding(6)
                                .contentShape(Rectangle())
                                .help("复制这个地址")
                            }
                        }
                    }
                    Text("⚠️ 局域网内任何知道这个地址的设备都能使用你的代理，公共/不受信任的网络环境建议关闭。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if store.isRunning {
                    Label("保存后代理会自动重启以应用新设置", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if savedJustNow {
                    Text("已保存").font(.caption).foregroundStyle(.green)
                }
                Button("保存") { save() }
                    .disabled(draft == store.localSettings)
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            draft = store.localSettings
            lanIPs = Self.localIPv4Addresses()
        }
    }

    private func save() {
        if let err = draft.validationError() {
            errorMessage = err
            return
        }
        errorMessage = nil
        store.updateLocalSettings(draft)
        savedJustNow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedJustNow = false }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let addr = current.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(current.pointee.ifa_addr, socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty, !addresses.contains(ip) {
                addresses.append(ip)
            }
        }
        return addresses
    }
}
