import SwiftUI

struct MainContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            Text("请从左侧选择一个页面")
                .foregroundStyle(.secondary)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VlessProxy").font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Divider()

            List {
                ForEach(SidebarSection.allCases) { section in
                    NavigationLink(
                        destination: destinationView(for: section),
                        tag: section,
                        selection: $store.selectedSection
                    ) {
                        HStack {
                            Label(section.rawValue, systemImage: section.symbolName)
                            Spacer()
                            if section == .profiles && !store.profiles.isEmpty {
                                Text("\(store.profiles.count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Circle().fill(Color.gray.opacity(0.3)))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("监听端口").font(.caption2).foregroundStyle(.secondary)
                Text(listenAddrText)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func destinationView(for section: SidebarSection) -> some View {
        switch section {
        case .dashboard: DashboardView().frame(minWidth: 560, minHeight: 480)
        case .profiles: ProfilesView().frame(minWidth: 560, minHeight: 480)
        case .systemProxy: SystemProxyView().frame(minWidth: 560, minHeight: 480)
        case .localProxy: LocalProxyView().frame(minWidth: 560, minHeight: 480)
        case .logs: LogsView().frame(minWidth: 560, minHeight: 480)
        case .preferences: PreferencesView().frame(minWidth: 560, minHeight: 480)
        }
    }

    private var statusText: String {
        switch store.proxyStatus {
        case .stopped: return "已停止"
        case .starting: return "正在启动…"
        case .running: return "运行中"
        case .failed: return "启动失败"
        }
    }

    private var listenAddrText: String {
        "\(store.localSettings.localIP):\(store.localSettings.localPort)"
    }
}
