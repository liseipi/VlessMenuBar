import SwiftUI

// 用老式的 NavigationView + tag/selection 版 NavigationLink 实现侧边栏，
// 不用 NavigationSplitView——那个是 macOS 13+ 才有的 API，用了整个 App
// 就没法在 macOS 12 及更早的系统上跑。这一套写法从 SwiftUI 刚出来
// （macOS 10.15）就能用，是长期以来的标准做法，兼容性好很多。
// 视觉效果和之前完全一样，只是底层容器换了一种写法。
struct MainContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)

            // 没有任何一项被选中时（理论上不会发生，selectedSection 有默认值），
            // 给个占位视图，避免 NavigationView 在双栏模式下显示空白。
            Text("请从左侧选择一个页面")
                .foregroundStyle(.secondary)
        }
        // 不需要显式指定 navigationViewStyle：macOS 上 NavigationView 给两个
        // 子视图时，默认就是侧边栏+详情的双栏布局，这是平台自带的行为。
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题区，对应截图左上角的盾牌图标 + "VlessProxy" + 运行状态
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

            // 底部固定显示当前监听地址，对应截图左下角 "监听端口 127.0.0.1:1088"
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
