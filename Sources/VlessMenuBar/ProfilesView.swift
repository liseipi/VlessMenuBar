import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProfilesView: View {
    @EnvironmentObject var store: AppStore
    @State private var editingProfile: ProxyProfile?
    @State private var showingNewSheet = false
    @State private var qrSheetProfile: ProxyProfile?
    @State private var toastMessage: String?
    @State private var showLinkImportSheet = false
    @State private var linkImportText = ""
    @State private var linkImportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("代理配置").font(.title2).bold()
                Spacer()
                Menu {
                    Button("从文件导入…") { importFromFile() }
                    Button("从 vless:// 链接导入…") { showLinkImportSheet = true }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                Button {
                    editingProfile = ProxyProfile(name: "新节点", config: ProxyConfig())
                    showingNewSheet = true
                } label: {
                    Label("新增节点", systemImage: "plus")
                }
            }
            .padding(20)

            if let toastMessage {
                Text(toastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            if store.profiles.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("还没有保存任何节点").foregroundStyle(.secondary)
                    Button("新增一个节点") {
                        editingProfile = ProxyProfile(name: "新节点", config: ProxyConfig())
                        showingNewSheet = true
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(store.profiles) { profile in
                        profileRow(profile)
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: sheetBinding) { profile in
            ProfileEditSheet(
                profile: profile,
                isNew: showingNewSheet,
                onSave: { saved in
                    if showingNewSheet {
                        store.addProfile(saved)
                    } else {
                        store.updateProfile(saved)
                    }
                    editingProfile = nil
                    showingNewSheet = false
                },
                onCancel: {
                    editingProfile = nil
                    showingNewSheet = false
                }
            )
        }
        .sheet(item: qrSheetBinding) { profile in
            QRCodeSheet(
                profileName: profile.name,
                link: VlessLink.build(from: profile),
                onClose: { qrSheetProfile = nil }
            )
        }
        .sheet(isPresented: $showLinkImportSheet) {
            linkImportSheet
        }
    }

    // MARK: - 节点列表每一行

    private func profileRow(_ profile: ProxyProfile) -> some View {
        HStack {
            Image(systemName: profile.id == store.activeProfileID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == store.activeProfileID ? .green : .secondary)
                .padding(6) // 光一个 SF Symbol 的图形边界太小了，加点内边距扩大可点击范围
                .contentShape(Rectangle())
                .onTapGesture { store.setActiveProfile(profile.id) }
                .help("设为当前使用的节点")

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.body)
                Text("\(profile.config.host):\(profile.config.port)\(profile.config.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if profile.id == store.activeProfileID && store.isRunning {
                Text("运行中").font(.caption2).foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }

            // 常用操作直接露出来，加了统一的内边距扩大点击热区，
            // 图标本身很小，不加 padding 很容易点空或者点到旁边那个。
            Button {
                copyLink(profile)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .padding(6)
            .contentShape(Rectangle())
            .help("复制 vless:// 链接")

            Button {
                qrSheetProfile = profile
            } label: {
                Image(systemName: "qrcode")
            }
            .buttonStyle(.borderless)
            .padding(6)
            .contentShape(Rectangle())
            .help("生成二维码")

            Button {
                editingProfile = profile
                showingNewSheet = false
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .padding(6)
            .contentShape(Rectangle())
            .help("编辑")

            // 不常用、有风险的操作（导出文件、删除）收进一个"更多"菜单里，
            // 避免五个图标挤在一起容易点错——尤其是"删除"紧挨着其他按钮时
            // 很容易手滑点到，放进菜单要多一步确认，安全一些。
            Menu {
                Button {
                    exportToFile(profile)
                } label: {
                    Label("导出为文件…", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    store.deleteProfile(profile.id)
                } label: {
                    Label("删除节点", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("更多操作")
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    // sheet(item:) 需要 Binding<Item?>，手动包一层方便复用。
    private var sheetBinding: Binding<ProxyProfile?> {
        Binding(get: { editingProfile }, set: { editingProfile = $0 })
    }
    private var qrSheetBinding: Binding<ProxyProfile?> {
        Binding(get: { qrSheetProfile }, set: { qrSheetProfile = $0 })
    }

    // MARK: - 复制链接 / 文件导入导出

    private func copyLink(_ profile: ProxyProfile) {
        let link = VlessLink.build(from: profile)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        showToast("已复制「\(profile.name)」的链接")
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择要导入的配置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try ProfileStore.importProfile(from: url)
            store.addProfile(imported)
            showToast("已导入节点「\(imported.name)」")
        } catch {
            showToast("导入失败：\(error.localizedDescription)")
        }
    }

    private func exportToFile(_ profile: ProxyProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        panel.message = "选择导出位置"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ProfileStore.export(profile, to: url)
            showToast("已导出到 \(url.lastPathComponent)")
        } catch {
            showToast("导出失败：\(error.localizedDescription)")
        }
    }

    private func showToast(_ text: String) {
        toastMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if toastMessage == text { toastMessage = nil }
        }
    }

    // MARK: - 从 vless 链接导入

    private var linkImportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("从链接导入节点").font(.headline)
            Text("粘贴一个 vless:// 开头的分享链接：")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $linkImportText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))

            if let linkImportError {
                Text(linkImportError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("取消") {
                    linkImportText = ""
                    linkImportError = nil
                    showLinkImportSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入") { confirmLinkImport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func confirmLinkImport() {
        guard let profile = VlessLink.parse(linkImportText) else {
            linkImportError = "链接格式不对，确认是完整的 vless:// 链接"
            return
        }
        store.addProfile(profile)
        showToast("已导入节点「\(profile.name)」")
        linkImportText = ""
        linkImportError = nil
        showLinkImportSheet = false
    }
}

/// 新增/编辑节点用的表单弹窗，内部复用 ConfigFormFields（多加一个"节点名称"字段）。
struct ProfileEditSheet: View {
    @State var profile: ProxyProfile
    let isNew: Bool
    var onSave: (ProxyProfile) -> Void
    var onCancel: () -> Void

    @State private var validationMessage: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新增节点" : "编辑节点").font(.headline)
                Spacer()
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("节点名称").font(.caption).foregroundStyle(.secondary)
                        TextField("给这个节点起个好记的名字", text: $profile.name)
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFieldFocused)
                    }

                    ConfigFormFields(config: $profile.config)

                    if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                .padding(20)
            }
            .onAppear {
                // 弹窗一打开就能直接开始打字，不用先点一下才能输入。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    nameFieldFocused = true
                }
            }

            Divider()
            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 480, height: 620)
    }

    private func save() {
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
            validationMessage = "节点名称不能为空"
            return
        }
        if let err = profile.config.validationError() {
            validationMessage = err
            return
        }
        validationMessage = nil
        onSave(profile)
    }
}
