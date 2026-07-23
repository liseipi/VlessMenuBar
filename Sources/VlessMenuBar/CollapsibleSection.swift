import SwiftUI

/// 替代 DisclosureGroup 的自制可折叠区域。
///
/// 为什么不直接用 SwiftUI 自带的 DisclosureGroup：在 macOS 上，
/// DisclosureGroup 就算换成自定义 label（哪怕撑满整行宽度、显式声明
/// contentShape），点击展开/收起的实际热区依然只有那个箭头图标本身，
/// label 内容点了没反应——这是 macOS 平台自己的行为，不是宽度或
/// contentShape 设置的问题，iOS 上是好的，macOS 上就是不行。
///
/// 这里改用一个 `Button` 把标题文字 + 箭头图标整个包起来，点击这一整行
/// 任意位置都能触发展开/收起，这样只依赖 Button 本身的点击行为，不依赖
/// DisclosureGroup 在 macOS 上这个不可靠的细节。
struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle()) // 保证标题和箭头之间的空白区域也算在点击范围内
            }
            .buttonStyle(.plain) // 去掉系统默认按钮外观，看起来还是普通的一行文字+箭头

            if isExpanded {
                content()
            }
        }
    }
}
