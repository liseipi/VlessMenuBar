import SwiftUI
import AppKit

struct QRCodeSheet: View {
    let profileName: String
    let link: String
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(profileName).font(.headline)

            if let image = QRCodeGenerator.generate(from: link) {
                Image(nsImage: image)
                    .interpolation(.none) // 保持二维码块状边缘清晰，不做平滑插值
                    .resizable()
                    .frame(width: 240, height: 240)
            } else {
                Text("二维码生成失败").foregroundStyle(.red)
            }

            Text(link)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            HStack {
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
