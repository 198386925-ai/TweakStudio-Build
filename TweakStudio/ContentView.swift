import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: TweakStore
    @State private var input = TweakInput()
    @State private var problems: [String] = []
    @State private var lastRecord: TweakRecord? = nil
    @State private var shareURL: URL? = nil
    @State private var showZipImporter = false
    @State private var tokenDraft: String = ""
    @State private var hasToken: Bool = TokenStore.load() != nil

    var body: some View {
        TabView {
            NavigationStack { formView }
                .tabItem { Label("生成", systemImage: "doc.badge.gearshape") }
            NavigationStack { HistoryView() }
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
        }
    }

    private var formView: some View {
        Form {
            Section("插件信息") {
                TextField("英文名（PascalCase，如 TouchTrail）", text: $input.name)
                    .autocorrectionDisabled()
                TextField("中文名（显示名，可不填）", text: $input.displayName)
                TextField("小写标识（可不填，自动用英文名小写）", text: $input.slug)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("简单介绍（可不填）", text: $input.descriptionText)
                TextField("要改的 App Bundle ID（不填默认桌面）", text: $input.bundle)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("最低 iOS 版本（不填默认 14.0）", text: $input.minimumIOS)
                    .keyboardType(.decimalPad)
            }
            Section("可选项") {
                Toggle("要设置面板", isOn: $input.preferences)
                Toggle("要滑条（需要设置面板）", isOn: $input.slider)
            }
            if !problems.isEmpty {
                Section("检查提醒") {
                    ForEach(problems, id: \.self) { problem in
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
            Section {
                Button("先检查") {
                    problems = store.check(input: input)
                    if problems.isEmpty {
                        store.statusText = "检查通过（只是格式和文件层面的静态检查）"
                    }
                }
                Button("生成工程") {
                    Task {
                        problems = store.check(input: input)
                        if problems.isEmpty, let record = await store.generate(input: input) {
                            lastRecord = record
                        }
                    }
                }
                .font(.headline)
                Button("导入源码 zip") { showZipImporter = true }
                if let record = currentRecord {
                    Button("分享工程 zip") { shareURL = store.zipURL(record) }
                    Button("送去打成品") {
                        Task { await store.uploadAndBuild(record: record) }
                    }
                    .font(.headline)
                }
                if store.working { ProgressView() }
                if !store.statusText.isEmpty {
                    Text(store.statusText).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("GitHub（打成品用）") {
                if hasToken {
                    Text("令牌已存进钥匙串" + (store.owner.map { "，账号 \($0)" } ?? ""))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("验证令牌") { Task { await store.verifyToken() } }
                    Button("清除令牌", role: .destructive) {
                        TokenStore.clear()
                        hasToken = false
                        store.owner = nil
                    }
                } else {
                    SecureField("粘贴 GitHub 令牌", text: $tokenDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("保存到钥匙串") {
                        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !token.isEmpty {
                            TokenStore.save(token)
                            tokenDraft = ""
                            hasToken = true
                            Task { await store.verifyToken() }
                        }
                    }
                    Text("令牌需要建仓库和推代码的权限。只存这台手机的钥匙串，不上传别处。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("生成出来的是插件工程半成品，送 GitHub 打成 deb 后在历史里下载。手机本地不编译，App 不装插件、不注销。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("插件工坊")
        .sheet(item: shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showZipImporter) {
            ZipDocumentPicker { url in
                showZipImporter = false
                guard let url else { return }
                guard url.pathExtension.lowercased() == "zip" else {
                    store.statusText = "导入失败：请选择 zip 文件"
                    return
                }
                Task {
                    if let record = await store.importProject(from: url) {
                        lastRecord = record
                    }
                }
            }
        }
    }

    private var currentRecord: TweakRecord? {
        if let lastRecord, store.records.contains(lastRecord) { return lastRecord }
        return store.records.first
    }

    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })
    }
}

/// UIKit 文档选择器（绕过 SwiftUI fileImporter 在 TabView 中的回调问题）
struct ZipDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
