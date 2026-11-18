import SwiftUI

// MARK: - 书源编辑器
//
// 两种模式：
//   1. 表单：按「搜索 / 详情 / 目录 / 正文」四段逐条填规则
//   2. JSON：直接改整份书源，方便从别人那里复制一段贴进来

struct SourceEditorView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var source: BookSource
    @State private var isNew: Bool
    @State private var jsonMode = false
    @State private var jsonText = ""
    @State private var jsonError: String?

    init(source: BookSource?) {
        if let source {
            _source = State(initialValue: source)
            _isNew = State(initialValue: false)
        } else {
            var s = BookSource()
            s.bookSourceName = "新书源"
            s.bookSourceUrl = "https://example.com"
            _source = State(initialValue: s)
            _isNew = State(initialValue: true)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if jsonMode {
                    jsonEditor
                } else {
                    formEditor
                }
            }
            .navigationTitle(isNew ? "新建书源" : "编辑书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button(jsonMode ? "表单" : "JSON") {
                            if jsonMode { applyJSON() } else { loadJSON() }
                            jsonMode.toggle()
                        }
                        .font(.footnote)
                        Button("保存") { save() }
                            .bold()
                    }
                }
            }
        }
    }

    // MARK: 表单

    private var formEditor: some View {
        Form {
            Section("基础") {
                labeledField("名称", text: bind(\.bookSourceName))
                labeledField("地址", text: bind(\.bookSourceUrl), keyboard: .URL)
                labeledField("分组", text: bind(\.bookSourceGroup))
                Picker("类型", selection: Binding(
                    get: { source.bookSourceType },
                    set: { source.bookSourceType = $0 }
                )) {
                    ForEach(SourceType.allCases, id: \.rawValue) { t in
                        Text(t.label).tag(t.rawValue)
                    }
                }
                labeledField("备注", text: bind(\.bookSourceComment))
                labeledField("请求头 header", text: bind(\.header), axis: .vertical)
                labeledField("搜索地址 searchUrl", text: bind(\.searchUrl), axis: .vertical)
                labeledField("书详情页匹配 bookUrlPattern", text: bind(\.bookUrlPattern))
            }

            Section {
                ForEach(searchFields, id: \.title) { f in
                    labeledField(f.title, text: bind(f.path), axis: .vertical)
                }
            } header: {
                Text("搜索规则 ruleSearch")
            } footer: {
                Text("bookList 是列表容器选择器，其余字段相对于每个列表项求值。")
                    .font(.caption2)
            }

            Section("详情规则 ruleBookInfo") {
                ForEach(bookInfoFields, id: \.title) { f in
                    labeledField(f.title, text: bind(f.path), axis: .vertical)
                }
            }

            Section("目录规则 ruleToc") {
                ForEach(tocFields, id: \.title) { f in
                    labeledField(f.title, text: bind(f.path), axis: .vertical)
                }
            }

            Section {
                ForEach(contentFields, id: \.title) { f in
                    labeledField(f.title, text: bind(f.path), axis: .vertical)
                }
            } header: {
                Text("正文规则 ruleContent")
            } footer: {
                Text("漫画源在 content 里写图片列表选择器，例如 //div[@id='images']//img/@src")
                    .font(.caption2)
            }
        }
    }

    // MARK: JSON

    private var jsonEditor: some View {
        VStack(spacing: 0) {
            TextEditor(text: $jsonText)
                .font(.system(size: 11, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)
            if let jsonError {
                Text(jsonError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    private func loadJSON() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let d = try? enc.encode(source), let s = String(data: d, encoding: .utf8) {
            jsonText = s
        }
    }

    private func applyJSON() {
        guard let d = jsonText.data(using: .utf8) else { return }
        let parsed = LenientDecoder.decodeSources(from: d)
        if let first = parsed.first {
            var s = first
            s.id = source.id
            source = s
            jsonError = nil
        } else {
            jsonError = "JSON 解析失败：检查括号与逗号"
        }
    }

    // MARK: 保存

    private func save() {
        if source.bookSourceUrl.isEmpty { source.bookSourceUrl = "https://example.com" }
        if source.bookSourceName.isEmpty {
            source.bookSourceName = URL(string: source.bookSourceUrl)?.host ?? "未命名"
        }
        if jsonMode { applyJSON() }
        app.saveSource(source)
        app.showToast("已保存")
        dismiss()
    }

    // MARK: 字段表

    private struct FieldSpec {
        let title: String
        let path: WritableKeyPath<BookSource, String>
    }

    private var searchFields: [FieldSpec] {
        [
            .init(title: "列表 bookList", path: \.ruleSearch.bookList),
            .init(title: "书名 name", path: \.ruleSearch.name),
            .init(title: "作者 author", path: \.ruleSearch.author),
            .init(title: "简介 intro", path: \.ruleSearch.intro),
            .init(title: "分类 kind", path: \.ruleSearch.kind),
            .init(title: "最新章节 lastChapter", path: \.ruleSearch.lastChapter),
            .init(title: "更新时间 updateTime", path: \.ruleSearch.updateTime),
            .init(title: "详情链接 bookUrl", path: \.ruleSearch.bookUrl),
            .init(title: "封面 coverUrl", path: \.ruleSearch.coverUrl)
        ]
    }

    private var bookInfoFields: [FieldSpec] {
        [
            .init(title: "预处理 init", path: \.ruleBookInfo.init),
            .init(title: "书名 name", path: \.ruleBookInfo.name),
            .init(title: "作者 author", path: \.ruleBookInfo.author),
            .init(title: "简介 intro", path: \.ruleBookInfo.intro),
            .init(title: "分类 kind", path: \.ruleBookInfo.kind),
            .init(title: "最新章节 lastChapter", path: \.ruleBookInfo.lastChapter),
            .init(title: "字数 wordCount", path: \.ruleBookInfo.wordCount),
            .init(title: "封面 coverUrl", path: \.ruleBookInfo.coverUrl),
            .init(title: "目录地址 tocUrl", path: \.ruleBookInfo.tocUrl)
        ]
    }

    private var tocFields: [FieldSpec] {
        [
            .init(title: "章节列表 chapterList", path: \.ruleToc.chapterList),
            .init(title: "章节名 chapterName", path: \.ruleToc.chapterName),
            .init(title: "章节链接 chapterUrl", path: \.ruleToc.chapterUrl),
            .init(title: "下一页 nextTocUrl", path: \.ruleToc.nextTocUrl),
            .init(title: "VIP 标记 isVip", path: \.ruleToc.isVip),
            .init(title: "卷名标记 isVolume", path: \.ruleToc.isVolume)
        ]
    }

    private var contentFields: [FieldSpec] {
        [
            .init(title: "正文 content", path: \.ruleContent.content),
            .init(title: "下一页 nextContentUrl", path: \.ruleContent.nextContentUrl),
            .init(title: "网页脚本 webJs", path: \.ruleContent.webJs),
            .init(title: "正文正则 sourceRegex", path: \.ruleContent.sourceRegex),
            .init(title: "替换正则 replaceRegex", path: \.ruleContent.replaceRegex)
        ]
    }

    // MARK: 组件

    private func bind(_ path: WritableKeyPath<BookSource, String>) -> Binding<String> {
        Binding(get: { source[keyPath: path] },
                set: { source[keyPath: path] = $0 })
    }

    private func labeledField(_ title: String, text: Binding<String>,
                              axis: Axis = .horizontal,
                              keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, axis: axis)
                .font(.system(size: 13, design: .monospaced))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(axis == .vertical ? 1...6 : 1...1)
        }
        .padding(.vertical, 2)
    }
}
