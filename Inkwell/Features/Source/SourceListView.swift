import SwiftUI

// MARK: - 书源列表

struct SourceListView: View {
    @EnvironmentObject var app: AppState

    @State private var searchText = ""
    @State private var showImport = false
    @State private var showURLSheet = false
    @State private var urlText = ""
    @State private var editingSource: BookSource?
    @State private var detailSource: BookSource?
    @State private var selectedGroup: String? = nil
    @State private var showNewSheet = false
    @State private var showStore = false
    @State private var showHealth = false

    var groups: [String] {
        var set = Set<String>()
        for s in app.sources { for g in s.groupList { set.insert(g) } }
        return ["全部"] + Array(set).sorted()
    }

    var filtered: [BookSource] {
        var list = app.sources
        if let g = selectedGroup, g != "全部" {
            list = list.filter { $0.groupList.contains(g) }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.host.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        NavigationStack {
            List {
                if groups.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(groups, id: \.self) { g in
                                Button {
                                    selectedGroup = g
                                } label: {
                                    Text(g)
                                        .font(.caption)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(selectedGroup == g
                                                    ? Color.accentColor
                                                    : Color.secondary.opacity(0.14),
                                                    in: Capsule())
                                        .foregroundStyle(selectedGroup == g ? .white : .primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }

                Section {
                    ForEach(filtered) { source in
                        SourceRow(source: source) {
                            app.toggleSource(source.id, enabled: !source.enabled)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { detailSource = source }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                app.deleteSources([source.id])
                            } label: { Label("删除", systemImage: "trash") }

                            Button {
                                editingSource = source
                            } label: { Label("编辑", systemImage: "square.and.pencil") }
                            .tint(.orange)
                        }
                    }
                } header: {
                    HStack {
                        Text("\(filtered.count) 个书源")
                        Spacer()
                        Text("\(app.enabledSources.count) 已启用")
                    }
                } footer: {
                    Text("书源规则兼容「阅读 / Legado」的 JSON 格式，可以直接导入现成书源包。")
                        .font(.caption2)
                }
            }
            .navigationTitle("书源")
            .searchable(text: $searchText, prompt: "搜索书源")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showStore = true
                        } label: { Label("源商店（内置/订阅/建源）", systemImage: "square.grid.2x2") }

                        Button {
                            showHealth = true
                        } label: { Label("书源体检", systemImage: "stethoscope") }

                        Divider()

                        Button {
                            showImport = true
                        } label: { Label("从文件导入", systemImage: "doc.badge.plus") }

                        Button {
                            showURLSheet = true
                        } label: { Label("从网址导入", systemImage: "link") }

                        Button {
                            if let s = UIPasteboard.general.string, !s.isEmpty {
                                let n = app.importSourceJSON(s)
                                if n == 0 { app.showToast("剪贴板里没有书源 JSON") }
                            } else {
                                app.showToast("剪贴板为空")
                            }
                        } label: { Label("从剪贴板导入", systemImage: "doc.on.clipboard") }

                        Divider()

                        Button {
                            showNewSheet = true
                        } label: { Label("新建书源", systemImage: "plus.circle") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showStore) {
                SourceStoreView().environmentObject(app)
            }
            .sheet(isPresented: $showHealth) {
                SourceHealthView().environmentObject(app)
            }
            .sheet(isPresented: $showImport) {
                SourceImportView().environmentObject(app)
            }
            .sheet(isPresented: $showURLSheet) {
                NavigationStack {
                    Form {
                        Section("书源 JSON 地址") {
                            TextField("https://…/sources.json", text: $urlText, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Section {
                            Button("开始导入") { importFromURL() }
                                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .navigationTitle("网址导入")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("关闭") { showURLSheet = false }
                        }
                    }
                }
                .presentationDetents([.height(260)])
            }
            .sheet(item: $editingSource) { source in
                SourceEditorView(source: source).environmentObject(app)
            }
            .sheet(isPresented: $showNewSheet) {
                SourceEditorView(source: nil).environmentObject(app)
            }
            .navigationDestination(item: $detailSource) { source in
                SourceDetailView(source: source).environmentObject(app)
            }
        }
    }

    private func importFromURL() {
        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else {
            app.showToast("网址不合法")
            return
        }
        let captured = raw
        showURLSheet = false
        Task.detached {
            do {
                let r = try await HTTPClient.shared.request(url: captured)
                await MainActor.run {
                    let n = app.importSourceJSON(r.text)
                    if n == 0 { app.showToast("该地址不是有效的书源 JSON") }
                    urlText = ""
                }
            } catch {
                await MainActor.run {
                    app.showToast("下载失败：\(error.localizedDescription)")
                }
                _ = url
            }
        }
    }
}

struct SourceRow: View {
    let source: BookSource
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(source.isComic
                          ? Color.orange.opacity(0.16)
                          : Color.accentColor.opacity(0.14))
                Image(systemName: source.isComic ? "photo.on.rectangle" : "text.book.closed")
                    .font(.system(size: 14))
                    .foregroundStyle(source.isComic ? Color.orange : Color.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(source.host)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !source.bookSourceGroup.isEmpty {
                        Text(source.bookSourceGroup)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { source.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
                .scaleEffect(0.85)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 导入页

struct SourceImportView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var showFilePicker = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("粘贴 Legado / 阅读 的书源 JSON\n支持数组、单对象、以及 {data:[...]} 包装形式")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .padding(14)
                                .allowsHitTesting(false)
                        }
                    }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        if let s = UIPasteboard.general.string { text = s }
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("选文件", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        busy = true
                        let n = app.importSourceJSON(text)
                        busy = false
                        if n > 0 { dismiss() }
                    } label: {
                        Text(busy ? "导入中…" : "导入")
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.json, .plainText, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        text = String(data: data, encoding: .utf8) ?? ""
                    }
                }
            }
        }
    }
}
