import SwiftUI

// MARK: - 我的 / 设置

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var cacheSize = ""
    @State private var showLog = false
    @State private var showWebLogin = false
    @State private var loginURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读") {
                    NavigationLink {
                        GlobalReaderSettings().environmentObject(app)
                    } label: {
                        Label("阅读偏好", systemImage: "textformat")
                    }
                    Toggle("保持屏幕常亮", isOn: Binding(
                        get: { app.settings.keepScreenOn },
                        set: { v in var s = app.settings; s.keepScreenOn = v; app.updateSettings(s) }
                    ))
                }

                Section("书源") {
                    HStack {
                        Text("已导入")
                        Spacer()
                        Text("\(app.sources.count) 个").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("已启用")
                        Spacer()
                        Text("\(app.enabledSources.count) 个").foregroundStyle(.secondary)
                    }
                    Button {
                        loginURL = ""
                        showWebLogin = true
                    } label: {
                        Label("网页登录 / 抓 Cookie", systemImage: "globe")
                    }
                    Button {
                        showLog = true
                    } label: {
                        Label("运行日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("存储") {
                    HStack {
                        Text("图片缓存")
                        Spacer()
                        Text(cacheSize).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        Task {
                            await ImageLoader.shared.clearCache()
                            await refreshCacheSize()
                            app.showToast("已清空图片缓存")
                        }
                    } label: {
                        Label("清空图片缓存", systemImage: "trash")
                    }
                    Button(role: .destructive) {
                        for book in app.books where book.isLocal {
                            app.removeBook(book.id)
                        }
                        app.showToast("已移除本地书籍")
                    } label: {
                        Label("移除所有本地书籍", systemImage: "externaldrive.badge.minus")
                    }
                }

                Section("书籍格式支持") {
                    ForEach(BookFormat.allCases, id: \.self) { f in
                        HStack {
                            Text(f.label)
                            Spacer()
                            Image(systemName: supportIcon(f))
                                .foregroundStyle(supportColor(f))
                        }
                        .font(.footnote)
                    }
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("规则引擎")
                        Spacer()
                        Text("Legado 兼容 · XPath/CSS/JSONPath/JS")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("墨阅 · 自用阅读器。书源规则完全本地执行，不上传任何数据。")
                        .font(.caption2)
                }
            }
            .navigationTitle("我的")
            .task { await refreshCacheSize() }
            .sheet(isPresented: $showLog) {
                LogView()
            }
            .sheet(isPresented: $showWebLogin) {
                WebLoginView(initialURL: loginURL).environmentObject(app)
            }
        }
    }

    private func supportIcon(_ f: BookFormat) -> String {
        switch f {
        case .online, .txt, .epub, .pdf, .html, .markdown, .cbz, .fb2: return "checkmark.circle.fill"
        case .mobi: return "checkmark.circle"
        case .cbr: return "exclamationmark.circle"
        }
    }

    private func supportColor(_ f: BookFormat) -> Color {
        switch f {
        case .cbr: return .orange
        case .mobi: return .yellow
        default: return .green
        }
    }

    private func refreshCacheSize() async {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inkwell-images")
        let bytes = directorySize(dir)
        await MainActor.run {
            cacheSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    private func directorySize(_ url: URL) -> Int {
        guard let en = FileManager.default.enumerator(at: url,
                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for case let f as URL in en {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}

// MARK: - 全局阅读偏好

struct GlobalReaderSettings: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("字号") {
                HStack {
                    Text("\(Int(app.settings.fontSize)) pt")
                    Slider(value: Binding(
                        get: { Double(app.settings.fontSize) },
                        set: { v in var s = app.settings; s.fontSize = CGFloat(v); app.updateSettings(s) }
                    ), in: 12...34, step: 1)
                }
                HStack {
                    Text("行距 \(String(format: "%.2f", app.settings.lineHeightMultiple))")
                    Slider(value: Binding(
                        get: { Double(app.settings.lineHeightMultiple) },
                        set: { v in var s = app.settings; s.lineHeightMultiple = CGFloat(v); app.updateSettings(s) }
                    ), in: 1.2...2.6)
                }
            }
            Section("主题") {
                Picker("配色", selection: Binding(
                    get: { app.settings.theme },
                    set: { v in var s = app.settings; s.theme = v; app.updateSettings(s) }
                )) {
                    ForEach(ReaderTheme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("翻页", selection: Binding(
                    get: { app.settings.turnMode },
                    set: { v in var s = app.settings; s.turnMode = v; app.updateSettings(s) }
                )) {
                    ForEach(PageTurnMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section("漫画") {
                Picker("排版", selection: Binding(
                    get: { app.settings.comicLayout },
                    set: { v in var s = app.settings; s.comicLayout = v; app.updateSettings(s) }
                )) {
                    ForEach(ComicLayoutMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                HStack {
                    Text("图片间隙 \(Int(app.settings.comicPageGap))")
                    Slider(value: Binding(
                        get: { Double(app.settings.comicPageGap) },
                        set: { v in var s = app.settings; s.comicPageGap = CGFloat(v); app.updateSettings(s) }
                    ), in: 0...20)
                }
            }
        }
        .navigationTitle("阅读偏好")
    }
}

// MARK: - 日志

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LogEntry] = []

    var body: some View {
        NavigationStack {
            List(entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.level.rawValue)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(color(e.level))
                        Text(e.tag).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timeString(e.date))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(e.message)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(6)
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { Task { entries = await LogCenter.shared.snapshot() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { entries = await LogCenter.shared.snapshot() }
        }
    }

    private func color(_ l: LogEntry.Level) -> Color {
        switch l {
        case .error: return .red
        case .warn: return .orange
        case .info: return .blue
        case .debug: return .secondary
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - 网页登录（抓 Cookie）

struct WebLoginView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let initialURL: String

    @State private var urlText = ""
    @State private var reloadToken = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("输入书源站点网址", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("打开") { reloadToken = UUID() }
                        .buttonStyle(.bordered)
                }
                .padding(10)

                if !urlText.isEmpty {
                    CookieWebView(url: normalizedURL, reloadToken: reloadToken)
                } else {
                    Spacer()
                    Text("登录后 Cookie 会被保存，后续书源请求自动带上")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .navigationTitle("网页登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if urlText.isEmpty { urlText = initialURL }
            }
        }
    }

    private var normalizedURL: URL? {
        var s = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        return URL(string: s)
    }
}
