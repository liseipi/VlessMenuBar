import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusBanner
                statsCards
                currentNodeSection
                featureStatusSection
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }

    private var statusBanner: some View {
        HStack {
            HStack(spacing: 14) {
                Circle()
                    .fill(bannerDotColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bannerTitle).font(.headline)
                    Text(bannerSubtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: toggleProxy) {
                Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(store.isRunning ? Color.red : Color.green))
            }
            .buttonStyle(.plain)
            .disabled(store.activeProfile == nil)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(bannerBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(bannerBorderColor, lineWidth: 1)
        )
    }

    private var bannerDotColor: Color {
        switch store.proxyStatus {
        case .stopped: return .red
        case .starting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }
    private var bannerBackgroundColor: Color {
        switch store.proxyStatus {
        case .running: return Color.green.opacity(0.08)
        case .failed: return Color.red.opacity(0.08)
        default: return Color.orange.opacity(0.08)
        }
    }
    private var bannerBorderColor: Color {
        switch store.proxyStatus {
        case .running: return Color.green.opacity(0.3)
        case .failed: return Color.red.opacity(0.3)
        default: return Color.orange.opacity(0.3)
        }
    }
    private var bannerTitle: String {
        switch store.proxyStatus {
        case .stopped: return "代理已停止"
        case .starting: return "正在启动…"
        case .running: return "代理运行中"
        case .failed: return "启动失败"
        }
    }
    private var bannerSubtitle: String {
        switch store.proxyStatus {
        case .stopped: return "点击启动代理开始使用"
        case .starting: return "正在连接服务器…"
        case .running: return "一切正常"
        case .failed(let reason): return reason
        }
    }

    private func toggleProxy() {
        if store.isRunning {
            store.stop()
        } else {
            store.start()
        }
    }

    private var statsCards: some View {
        HStack(spacing: 16) {
            statCard(
                title: "本地端口",
                value: store.localSettings.localPort,
                subtitle: "SOCKS5 + HTTP(S) 混合代理"
            )
            statCard(
                title: "运行时长",
                value: formattedUptime(store.uptimeSeconds),
                subtitle: store.isRunning ? "运行中" : "已停止"
            )
        }
    }

    private func statCard(title: String, value: String, subtitle: String, valueColor: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.1)))
    }

    private func formattedUptime(_ seconds: Int) -> String {
        guard store.isRunning else { return "—" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private var currentNodeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("当前节点", systemImage: "rectangle.stack")
                .font(.headline)
                .padding(.bottom, 10)

            if let profile = store.activeProfile {
                infoRow("配置名称", profile.name)
                infoRow("服务器", "\(profile.config.host):\(profile.config.port)")
                infoRow("UUID", maskedUUID(profile.config.uuid))
                infoRow("传输方式", profile.config.useTLS ? "WS over TLS" : "WS (无 TLS)")
                infoRow("路径", profile.config.path)
                infoRow("SNI", profile.config.sni.isEmpty ? profile.config.host : profile.config.sni)
                infoRow("Token", profile.config.token.isEmpty ? "未设置" : "已设置", isLast: true)
            } else {
                Text("还没有配置任何节点，去「代理配置」页面添加一个吧。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }

    private func maskedUUID(_ uuid: String) -> String {
        guard uuid.count > 12 else { return uuid }
        let prefix = uuid.prefix(8)
        return "\(prefix)..."
    }

    private func infoRow(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(.body, design: .monospaced))
            }
            .padding(.vertical, 10)
            if !isLast { Divider() }
        }
    }

    private var featureStatusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("代理功能状态", systemImage: "checkmark.shield")
                .font(.headline)
                .padding(.bottom, 10)

            featureRow("globe", "系统代理", store.systemProxyIsOn ? "已启用" : "未启用", isOn: store.systemProxyIsOn)
            featureRow("wifi", "局域网共享", store.localSettings.lanEnabled ? "已开启" : "未开启",
                       isOn: store.localSettings.lanEnabled, isLast: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))
    }

    private func featureRow(_ symbol: String, _ label: String, _ value: String, isOn: Bool, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(label, systemImage: symbol)
                Spacer()
                Text(value).foregroundStyle(isOn ? .green : .secondary)
            }
            .padding(.vertical, 10)
            if !isLast { Divider() }
        }
    }
}
