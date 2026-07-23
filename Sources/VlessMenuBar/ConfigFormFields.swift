import SwiftUI

/// 纯粹的表单字段集合（不含节点名称、不含保存/取消按钮），
/// 被 ProfileEditSheet 包一层节点名称 + 按钮之后使用。
/// 抽出来是因为"新增节点"和"编辑节点"用的是同一套字段，只是外层壳不一样。
struct ConfigFormFields: View {
    @Binding var config: ProxyConfig
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地监听 IP/端口是全局设置，在侧边栏「本地代理」页面统一配置，不属于某一个节点。")
                .font(.caption)
                .foregroundStyle(.secondary)

            groupBox("服务器") {
                labeledField("服务器地址", "example.com（不要带 ws:// 或 wss://）", $config.host)
                HStack {
                    labeledField("端口", "443", $config.port)
                    labeledField("路径", "/api", $config.path)
                }
                Toggle("使用 TLS（wss://）", isOn: $config.useTLS)
                    .help("生产环境（有 Nginx/Caddy 做 TLS）请保持开启；只有直连裸端口调试才关")
            }

            groupBox("鉴权") {
                labeledField("UUID", "必须和服务端一致", $config.uuid)
                labeledField("Token（可选）", "服务端启用了 TOKEN 校验时必填", $config.token)
            }

            CollapsibleSection(title: "高级选项", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        labeledField("SNI（留空=同服务器地址）", "", $config.sni)
                        labeledField("Host 头（留空=同服务器地址）", "", $config.wsHost)
                    }
                    HStack {
                        stepperField("失败重试次数", value: $config.connectRetries, range: 0...10)
                        stepperField("重试基准(ms)", value: $config.retryBaseMs, range: 0...5000, step: 100)
                    }
                    stepperField("KeepAlive(秒)", value: $config.keepAliveSec, range: 0...300, step: 5)
                    Toggle(isOn: $config.insecure) {
                        Text("跳过证书校验（自签名证书调试用，正式环境不要开）")
                    }
                    Picker("日志级别", selection: $config.logLevel) {
                        Text("debug").tag("debug")
                        Text("info").tag("info")
                        Text("warn").tag("warn")
                        Text("error").tag("error")
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, 4)
            }

            if let errorMessage = config.validationError() {
                Text(errorMessage)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func groupBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
    }

    private func labeledField(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func stepperField(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue)")
            }
        }
    }
}
