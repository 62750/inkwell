import SwiftUI

// MARK: - 多源搜索

struct SearchState {
    var results: [Book] = []
    var running: Int = 0
    var finished: Int = 0
    var total: Int = 0
    var errors: [String] = []
}

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let initialKeyword: String
    @State private var keyword: String = ""
    @State private var state = SearchState()
    @State private var addingBook: Book?
    @State private var detailBook: Book?

    var body: some View {
        NavigationStack {
            List {
                if state.total > 0 {
                    Section {
                        HStack {
                            ProgressView(value: Double(state.finished),
                                         total: Double(max(state.total, 1)))
                            Text("\(state.finished)/\(state.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("将使用 \(app.enabledSources.count) 个已启用书源并发搜索")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !state.results.isEmpty {
                    Section("搜到 \(state.results.count) 本") {
                        ForEach(state.results) { book in
                            Button {
                                detailBook = book
                            } label: {
                                ResultRow(book: book)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button {
                                    app.addBook(book)
                                    app.showToast("已加入书架")
                                } label: {
                                    Label("加书架", systemImage: "plus")
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                } else if state.finished > 0 && state.finished == state.total {
                    Section {
                        Text("没有结果。可尝试换关键词，或检查书源的搜索规则是否失效。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !state.errors.isEmpty {
                    Section("失败的书源") {
                        ForEach(state.errors, id: \.self) { e in
                            Text(e).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "书名 / 作者")
            .onSubmit(of: .search) { startSearch() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if keyword.isEmpty { keyword = initialKeyword }
                if !keyword.isEmpty && state.total == 0 { startSearch() }
            }
            .sheet(item: $detailBook) { book in
                BookDetailView(book: book)
                    .environmentObject(app)
            }
        }
    }

    private func startSearch() {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let sources = app.enabledSources
        guard !sources.isEmpty else {
            app.showToast("先启用至少一个书源")
            return
        }
        state = SearchState()
        state.total = sources.count
        state.running = sources.count

        for source in sources {
            Task.detached {
                do {
                    let books = try await SourceEngine.shared.search(source: source, key: key)
                    await MainActor.run {
                        var existing = Set(state.results.map { $0.name + $0.author })
                        for b in books where !existing.contains(b.name + b.author) {
                            state.results.append(b)
                            existing.insert(b.name + b.author)
                        }
                        state.finished += 1
                        state.running -= 1
                    }
                } catch {
                    await MainActor.run {
                        state.finished += 1
                        state.running -= 1
                        state.errors.append("\(source.displayName)：\(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

struct ResultRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(book: book, size: CGSize(width: 52, height: 74))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(book.displayAuthor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !book.lastChapter.isEmpty {
                    Text(book.lastChapter)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(book.sourceName)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    Text(book.type.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }
}

// MARK: - 书籍详情

struct BookDetailView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State var book: Book
    @State private var chapters: [Chapter] = []
    @State private var loading = false
    @State private var error: String?
    @State private var reading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        BookCoverView(book: book, size: CGSize(width: 96, height: 136))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.name).font(.title3.bold())
                            Text(book.displayAuthor).font(.subheadline).foregroundStyle(.secondary)
                            if !book.kind.isEmpty {
                                Text(book.kind).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("来源：\(book.sourceName)").font(.caption2).foregroundStyle(.tertiary)
                            if !book.lastChapter.isEmpty {
                                Text("最新：\(book.lastChapter)")
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                            }
                        }
                        Spacer()
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task { await inLibraryAndRead() }
                        } label: {
                            Label("开始阅读", systemImage: "book.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            app.addBook(book)
                            app.showToast("已加入书架")
                        } label: {
                            Image(systemName: "plus")
                                .padding(.vertical, 10)
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.bordered)
                    }

                    if !book.intro.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("简介").font(.headline)
                            Text(book.intro).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("目录").font(.headline)
                            Spacer()
                            if loading { ProgressView().scaleEffect(0.7) }
                            Text("\(chapters.count) 章").font(.caption).foregroundStyle(.secondary)
                        }
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        ForEach(chapters.prefix(400)) { ch in
                            HStack {
                                Text(ch.title).font(.subheadline).lineLimit(1)
                                Spacer()
                                if ch.isVip {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        if chapters.count > 400 {
                            Text("… 共 \(chapters.count) 章")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadDetail() }
            .fullScreenCover(isPresented: $reading) {
                ReaderContainerView(book: book).environmentObject(app)
            }
        }
    }

    private func loadDetail() async {
        guard let source = app.sources.first(where: { $0.id == book.sourceId }) else { return }
        loading = true
        do {
            let info = try await SourceEngine.shared.bookInfo(source: source,
                                                              bookUrl: book.bookUrl,
                                                              stub: book)
            let toc = try await SourceEngine.shared.toc(source: source, book: info)
            await MainActor.run {
                book = info
                book.totalChapters = toc.chapters.count
                chapters = toc.chapters
                loading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func inLibraryAndRead() async {
        if chapters.isEmpty { await loadDetail() }
        let repo = LibraryRepository.shared
        var b = book
        b.totalChapters = chapters.count
        repo.saveBook(b)
        repo.saveChapters(chapters, bookId: b.id)
        app.loadBooks()
        reading = true
    }
}
