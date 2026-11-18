import SwiftUI

// MARK: - 书源调试台
//
// 这是「自己替换/修书源」的主战场：改一条规则，立刻看解析结果，
// 不用退出重进、不用猜是哪一步失效。

struct SourceDetailView: View {
    @EnvironmentObject var app: AppState
    @State var source: BookSource

    @State private var keyword = "斗破苍穹"
    @State private var searchResults: [Book] = []
    @State private var selectedBook: Book?
    @State private var chapters: [Chapter] = []
    @State private var selectedChapter: Chapter?
    @State private var contentPreview = ""
    @State private var log: [String] = []
    @State private var busy = false
    @State private var editing = false
    @State private var calibrating = false
    @State private var calibrateLog: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                stageCard(title: "① 搜索",
                          detail: source.searchUrl.isEmpty ? "未配置 searchUrl" : source.searchUrl) {
                    HStack {
                        TextField("关键词", text: $keyword)
                            .textFieldStyle(.roundedBorder)
                        Button("测试") { runSearch() }
                            .buttonStyle(.borderedProminent)
                            .disabled(keyword.isEmpty || busy)
                    }
                    if !searchResults.isEmpty {
                        ForEach(searchResults.prefix(8)) { b in
                            Button {
                                selectedBook = b
                                runBookInfo(b)
                            } label: {
                                HStack {
                                    Text(b.name).font(.subheadline).lineLimit(1)
                                    Spacer()
                                    Text(b.author).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                stageCard(title: "② 详情 + ③ 目录",
                          detail: selectedBook?.bookUrl ?? "先在上一步点一本书") {
                    if let b = selectedBook {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("书名：\(b.name)").font(.caption)
                            Text("作者：\(b.displayAuthor)").font(.caption)
                            Text("封面：\(b.coverUrl)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text("目录地址：\(b.tocUrl)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !chapters.isEmpty {
                            Text("解析到 \(chapters.count) 章").font(.caption).foregroundStyle(.green)
                            ForEach(chapters.prefix(6)) { ch in
                                Button {
                                    selectedChapter = ch
                                    runContent(ch)
                                } label: {
                                    Text(ch.title).font(.system(size: 12)).lineLimit(1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                stageCard(title: "④ 正文",
                          detail: selectedChapter?.title ?? "先选一章") {
                    if !contentPreview.isEmpty {
                        Text(contentPreview)
                            .font(.system(size: 12))
                            .lineLimit(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !log.isEmpty {
                    stageCard(title: "日志", detail: "\(log.count) 条") {
                        ForEach(log, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            SourceEditorView(source: source).environmentObject(app)
        }
        .overlay {
            if busy {
                ProgressView().padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(source.bookSourceUrl)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(source.type.label)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
            }
            if !source.bookSourceComment.isEmpty {
                Text(source.bookSourceComment).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("启用此源", isOn: Binding(
                get: { source.enabled },
                set: { app.toggleSource(source.id, enabled: $0); source.enabled = $0 }
            ))
            .font(.caption)

            HStack(spacing: 10) {
                Button {
                    calibrate()
                } label: {
                    HStack(spacing: 5) {
                        if calibrating { ProgressView().scaleEffect(0.6) }
                        Label("自动校准规则", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(calibrating)

                if RuleOverlay.shared.all(sourceId: source.id).isEmpty == false {
                    Button(role: .destructive) {
                        RuleOverlay.shared.clear(sourceId: source.id)
                        if let s = SourceRepository.shared.source(id: source.id) {
                            source = s
                        }
                        calibrateLog = ["已还原本源规则"]
                    } label: {
                        Label("还原本源", systemImage: "arrow.uturn.backward").font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !calibrateLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(calibrateLog, id: \.self) { l in
                        Text(l).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func stageCard<C: View>(title: String, detail: String,
                                    @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(detail).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(2)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 校准

    private func calibrate() {
        calibrating = true
        let src = source
        Task.detached {
            let (updated, log) = await SourceAutoBuilder.calibrate(source: src)
            // 差异写进覆盖层，原始规则不动
            let pairs: [(String, String, String)] = [
                ("ruleSearch.bookList", src.ruleSearch.bookList, updated.ruleSearch.bookList),
                ("ruleSearch.name", src.ruleSearch.name, updated.ruleSearch.name),
                ("ruleSearch.author", src.ruleSearch.author, updated.ruleSearch.author),
                ("ruleSearch.coverUrl", src.ruleSearch.coverUrl, updated.ruleSearch.coverUrl),
                ("ruleSearch.bookUrl", src.ruleSearch.bookUrl, updated.ruleSearch.bookUrl),
                ("ruleToc.chapterList", src.ruleToc.chapterList, updated.ruleToc.chapterList),
                ("ruleContent.content", src.ruleContent.content, updated.ruleContent.content)
            ]
            for (field, old, new) in pairs where !new.isEmpty && new != old {
                RuleOverlay.shared.set(sourceId: src.id, field: field, value: new)
            }
            await MainActor.run {
                calibrating = false
                calibrateLog = log
                if let refreshed = SourceRepository.shared.source(id: src.id) {
                    source = refreshed
                }
                app.reloadSourcesNow()
            }
        }
    }

    // MARK: 测试动作

    private func runSearch() {
        busy = true
        log = []
        let src = source
        let key = keyword
        Task.detached {
            defer { Task { await MainActor.run { busy = false } } }
            do {
                let books = try await SourceEngine.shared.search(source: src, key: key)
                await MainActor.run {
                    searchResults = books
                    log.append("搜索完成：\(books.count) 条")
                    if books.isEmpty { log.append("⚠️ 结果为空，检查 ruleSearch.bookList / searchUrl") }
                }
            } catch {
                await MainActor.run { log.append("搜索失败：\(error.localizedDescription)") }
            }
        }
    }

    private func runBookInfo(_ book: Book) {
        busy = true
        let src = source
        Task.detached {
            defer { Task { await MainActor.run { busy = false } } }
            do {
                let info = try await SourceEngine.shared.bookInfo(source: src, bookUrl: book.bookUrl, stub: book)
                let toc = try await SourceEngine.shared.toc(source: src, book: info)
                await MainActor.run {
                    selectedBook = info
                    chapters = toc.chapters
                    log.append("详情 OK：\(info.name)")
                    log.append("目录 OK：\(toc.chapters.count) 章")
                    if toc.chapters.isEmpty { log.append("⚠️ 目录为空，检查 ruleToc.chapterList") }
                }
            } catch {
                await MainActor.run { log.append("详情/目录失败：\(error.localizedDescription)") }
            }
        }
    }

    private func runContent(_ chapter: Chapter) {
        busy = true
        let src = source
        let book = selectedBook
        Task.detached {
            defer { Task { await MainActor.run { busy = false } } }
            do {
                guard let book else { return }
                let c = try await SourceEngine.shared.content(source: src, book: book, chapter: chapter)
                await MainActor.run {
                    selectedChapter = chapter
                    if c.isComic {
                        contentPreview = "图片 \(c.imageUrls.count) 张：\n"
                            + c.imageUrls.prefix(3).joined(separator: "\n")
                    } else {
                        contentPreview = String(c.text.prefix(1200))
                    }
                    log.append("正文 \(c.text.count) 字 / 图 \(c.imageUrls.count) 张")
                }
            } catch {
                await MainActor.run { log.append("正文失败：\(error.localizedDescription)") }
            }
        }
    }
}
