import SwiftUI
import AppKit

struct LogsView: View {
    @EnvironmentObject var store: AppStore
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("运行日志").font(.title2).bold()
                Spacer()
                if justCopied {
                    Text("已复制").font(.caption).foregroundStyle(.green)
                }
                Button("复制") { copyLogs() }
                    .disabled(store.logLines.isEmpty)
                Button("清空") { store.clearLogs() }
            }
            .padding(20)

            Divider()

            if store.logLines.isEmpty {
                Spacer()
                Text("代理还没有启动，或者还没有产生任何日志。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(store.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: store.logLines.count) { _ in
                        if let last = store.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func copyLogs() {
        let text = store.logLines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { justCopied = false }
    }
}
