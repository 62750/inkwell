import SwiftUI
import UniformTypeIdentifiers

// MARK: - 封面视图

struct BookCoverView: View {
    let book: Book
    var size: CGSize = CGSize(width: 104, height: 148)

    var body: some View {
        ZStack {
            if let local = LocalBookImporter.coverPath(for: book.id),
               let img = UIImage(contentsOfFile: local) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if !book.coverUrl.isEmpty, book.coverUrl.hasPrefix("http") {
                RemoteImage(url: book.coverUrl, referer: book.bookUrl)
            } else {
                generated
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
    }

    private var generated: some View {
        let palette: [Color] = [.init(red: 0.30, green: 0.42, blue: 0.55),
                                .init(red: 0.45, green: 0.32, blue: 0.40),
                                .init(red: 0.28, green: 0.45, blue: 0.40),
                                .init(red: 0.50, green: 0.40, blue: 0.28)]
        let idx = Int(book.name.stableHash % UInt64(palette.count))
        return LinearGradient(colors: [palette[idx].opacity(0.92),
                                       palette[idx].opacity(0.62)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                VStack(spacing: 6) {
                    Text(book.name.prefix(12))
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundStyle(.white.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 6)
                }
            )
    }
}

// MARK: - 书架

struct BookshelfView: View {
    @EnvironmentObject var app: AppState

    @State private var readingBook: Book?
    @State private var selectedBook: Book?
    @State private var searchText = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var sortMode: SortMode = .recent

    enum SortMode: String, CaseIterable {
        case recent = "最近阅读"
        case added = "加入时间"
        case name = "书名"
        case author = "作者"
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 16)]

    var filtered: [Book] {
        var list = app.books
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.author.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .recent: list.sort { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .name: list.sort { $0.name < $1.name }
        case .author: list.sort { $0.author < $1.author }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                if app.books.isEmpty && !app.phase.isReady {
                    skeletonState
                } else if app.books.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(filtered) { book in
                                Button {
                                    open(book)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        BookCoverView(book: book)
                                            .overlay(alignment: .topTrailing) {
                                                if let p = progressPercent(book) {
                                                    Text(p)
                                                        .font(.system(size: 9, weight: .semibold))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(.black.opacity(0.55), in: Capsule())
                                                        .foregroundStyle(.white)
                                                        .padding(5)
                                                }
                                            }
                                        Text(book.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(2)
                                            .foregroundStyle(.primary)
                                        Text(book.displayAuthor)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        open(book)
                                    } label: { Label("开始阅读", systemImage: "book") }

                                    Button {
                                        Task { await loadToc(book) }
                                    } label: { Label("刷新目录", systemImage: "arrow.clockwise") }

                                    if !book.isLocal {
                                        Button {
                                            app.removeBook(book.id)
                                        } label: { Label("从书架移除", systemImage: "trash") }
                                    } else {
                                        Button(role: .destructive) {
                                            app.removeBook(book.id)
                                        } label: { Label("删除", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("书架")
            .searchable(text: $searchText, prompt: "搜索书架")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("排序", selection: $sortMode) {
                            ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            FilePicker.present { handlePicked($0) }
                        } label: {
                            Label("从「文件」选择", systemImage: "folder")
                        }
                        Button {
                            scanDocumentsFolder()
                        } label: {
                            Label("扫描「墨阅」目录", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }

            .overlay {
                if importing {
                    ProgressView("正在解析…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .fullScreenCover(item: $readingBook) { book in
                ReaderContainerView(book: book)
                    .environmentObject(app)
            }
        }
    }


    /// 首帧骨架：数据还在后台加载，避免闪一下「书架空空如也」
    private var skeletonState: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 104, height: 148)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 78, height: 10)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.07))
                            .frame(width: 48, height: 8)
                    }
                }
            }
            .padding(16)
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(.secondary)
            Text("书架空空如也")
                .font(.headline)
            Text("从「发现」搜索在线书源，或导入本地文件\n支持 TXT / EPUB / PDF / MOBI / AZW3 / FB2 / CBZ / CBR / HTML / MD")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                FilePicker.present { handlePicked($0) }
            } label: {
                Label("导入本地书籍", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding(32)
    }

    private func progressPercent(_ book: Book) -> String? {
        guard let p = LibraryRepository.shared.progress(bookId: book.id),
              p.percent > 0.005 else { return nil }
        return String(format: "%.0f%%", p.percent * 100)
    }

    private func open(_ book: Book) {
        readingBook = book
    }

    /// 扫描「文件」App 里「墨阅」目录（UIFileSharingEnabled 已开启）
    private func scanDocumentsFolder() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let supported: Set<String> = ["txt", "epub", "pdf", "mobi", "azw", "azw3", "fb2",
                                      "cbz", "cbr", "html", "htm", "md", "markdown", "zip"]
        var found: [URL] = []
        if let items = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) {
            for f in items {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                guard supported.contains(f.pathExtension.lowercased()) else { continue }
                found.append(f)
            }
        }
        if found.isEmpty {
            app.showToast("「文件」App → 我的 iPhone → 墨阅 里没有可导入的书")
            return
        }
        handlePicked(found)
    }

    /// asCopy: true 已经把文件复制进沙盒，这里直接读
    private func handlePicked(_ urls: [URL]) {
        guard !urls.isEmpty else {
            importError = "没有拿到文件（选择器返回空）"
            return
        }
        importing = true
        Task.detached {
            var errors: [String] = []
            var imported = 0
            for url in urls {
                do {
                    _ = try LocalBookImporter.importAndStore(at: url)
                    imported += 1
                } catch {
                    errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            let finalErrors = errors
            let count = imported
            await MainActor.run {
                importing = false
                app.loadBooks()
                if !finalErrors.isEmpty {
                    importError = finalErrors.joined(separator: "\n")
                } else {
                    app.showToast("已导入 \(count) 本")
                }
            }
        }
    }


    private func loadToc(_ book: Book) async {
        guard !book.isLocal,
              let source = app.sources.first(where: { $0.id == book.sourceId }) else { return }
        do {
            let result = try await SourceEngine.shared.toc(source: source, book: book)
            await MainActor.run {
                LibraryRepository.shared.saveChapters(result.chapters, bookId: book.id)
                var b = book
                b.totalChapters = result.chapters.count
                if let last = result.chapters.last { b.lastChapter = last.title }
                app.addBook(b)
                app.showToast("目录已更新（\(result.chapters.count) 章）")
            }
        } catch {
            await MainActor.run { app.showToast("目录刷新失败：\(error.localizedDescription)") }
        }
    }
}