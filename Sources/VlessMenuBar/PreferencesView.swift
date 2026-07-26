import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var store: AppStore
    @State private var loginItemEnabled = LoginItemManager.isEnabled
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("偏好设置").font(.title2).bold()

            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { loginItemEnabled },
                    set: { toggleLoginItem($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("开机自启动").font(.headline)
                        Text("登录 Mac 后自动在后台启动这个 App（状态：\(LoginItemManager.statusDescription)）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            VStack(alignment: .leading, spacing: 8) {
                Text("关于").font(.headline)
                Text("VlessMenuBar 是 vless-ws-client 的图形界面壳，本身不实现任何代理逻辑，" +
                     "所有连接都是启动内置的 vless-ws-client 命令行工具来完成的。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.06)))

            Spacer()
        }
        .padding(24)
    }

    private func toggleLoginItem(_ enabled: Bool) {
        let result = LoginItemManager.setEnabled(enabled)
        switch result {
        case .success:
            loginItemEnabled = enabled
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
            loginItemEnabled = LoginItemManager.isEnabled
        }
    }
}
