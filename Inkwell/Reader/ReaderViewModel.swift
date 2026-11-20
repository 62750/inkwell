import Foundation
import SwiftUI
import Combine

// MARK: - 阅读器状态机
//
// 负责：加载章节 → 取正文（本地缓存优先 / 网络兜底）→ 排版分页 → 翻页 → 存进度
// 跨章翻页、预取下一章、字号变化后按字符偏移复位，都在这里。
//
// 注意：这里不用 @MainActor 标注整个类，因为 View 的 init 不是 MainActor 上下文；
// 所有 UI 状态的更新都显式包在 MainActor.run 里。

final class ReaderViewModel: ObservableObject {
    @Published var book: Book
    private let libraryRepo = LibraryRepository.shared

    @Published var chapters: [Chapter] = []
    @Published var chapterIndex: Int = 0
    @Published var pageIndex: Int = 0
    @Published var paginated: PaginatedChapter?
    @Published var pendingText: String = ""
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var isComic = false
    @Published var comicImages: [String] = []
    @Published var showMenu = false
    @Published var showTOC = false
    @Published var showSettings = false
    @Published var showSourceSwap = false
    @Published var settings: ReadingSettings

    private var anchorChar: Int = 0
    private var lastLayoutSize: CGSize = .zero
    private var contentCache: [Int: String] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var started = false

    init(book: Book, settings: ReadingSettings) {
        self.book = book
        self.settings = settings
        self.isComic = (book.type == .image) || book.format.isComicLike
    }

    /// 由视图在出现时调用一次
    func start() {
        guard !started else { return }
        started = true

        let cached = libraryRepo.chapters(bookId: book.id)
        chapters = cached
        restoreProgress()

        if cached.isEmpty && !book.isLocal {
            // 在线书第一次打开：先拉目录，拿到后再开章
            loadTocThenChapter()
        } else {
            Task { await loadChapter(at: chapterIndex) }
        }
    }

    /// 在线书首次进入：拉目录 → 落缓存 → 自动打开上次/第一章
    private func loadTocThenChapter(seekRatio: Double? = nil) {
        guard let source = SourceRepository.shared.source(id: book.sourceId) else {
            Task { await loadChapter(at: 0) }
            return
        }
        loading = true
        Task {
            do {
                let toc = try await SourceEngine.shared.toc(source: source, book: book)
                guard !toc.chapters.isEmpty else {
                    await MainActor.run {
                        self.loading = false
                        self.errorMessage = "目录为空：书源的目录规则可能需要调整"
                    }
                    return
                }
                self.libraryRepo.saveChapters(toc.chapters, bookId: book.id)
                await MainActor.run {
                    self.chapters = toc.chapters
                    if let r = seekRatio, !toc.chapters.isEmpty {
                        self.chapterIndex = min(toc.chapters.count - 1,
                                                max(0, Int(r * Double(toc.chapters.count))))
                    } else {
                        self.chapterIndex = min(self.chapterIndex, toc.chapters.count - 1)
                    }
                    self.loading = false
                }
                await self.loadChapter(at: self.chapterIndex)
            } catch {
                await MainActor.run {
                    self.loading = false
                    self.errorMessage = "目录加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func restoreProgress() {
        guard let p = libraryRepo.progress(bookId: book.id) else { return }
        anchorChar = p.charOffset
        pageIndex = p.pageInChapter
        guard !chapters.isEmpty else { return }
        chapterIndex = min(max(0, p.chapterIndex), chapters.count - 1)
    }

    // MARK: 加载一章

    func loadChapter(at index: Int, targetChar: Int? = nil) async {
        let snapshot = libraryRepo.chapters(bookId: book.id)
        if !snapshot.isEmpty, snapshot.count != chapters.count {
            await MainActor.run { self.chapters = snapshot }
        }
        guard index >= 0, index < chapters.count else { return }
        await MainActor.run {
            self.chapterIndex = index
            self.loading = true
            self.errorMessage = nil
            self.paginated = nil
            self.pageIndex = 0
            self.anchorChar = targetChar ?? 0
        }
        let chapter = chapters[index]

        if isComic {
            await MainActor.run { self.loadComic(chapter) }
            return
        }

        let text: String
        if let cached = contentCache[index] {
            text = cached
        } else if let stored = libraryRepo.content(chapterId: chapter.id), !stored.text.isEmpty {
            text = stored.text
            contentCache[index] = text
        } else if book.isLocal {
            text = loadLocalText(chapter)
            contentCache[index] = text
        } else if let source = SourceRepository.shared.source(id: book.sourceId) {
            do {
                let result = try await SourceEngine.shared.content(source: source,
                                                                   book: book, chapter: chapter)
                text = result.text.isEmpty
                    ? "（本章内容为空：可能是 VIP 章节，或正文规则需要调整）"
                    : result.text
                contentCache[index] = text
                libraryRepo.saveContent(result, chapterId: chapter.id)
            } catch {
                text = "加载失败：\(error.localizedDescription)"
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        } else {
            text = "书源已被删除，无法加载在线章节"
        }

        await MainActor.run {
            self.pendingText = text
            self.loading = false
        }
        prefetchNeighbors()
    }

    private func loadLocalText(_ chapter: Chapter) -> String {
        if book.format == .epub, !chapter.resourcePath.isEmpty {
            let name = URL(fileURLWithPath: book.localPath).deletingPathExtension().lastPathComponent
            let base = LocalBookImporter.libraryDir
                .appendingPathComponent("unpack_" + StringExt.safeFileName(name, maxLength: 60))
            let file = base.appendingPathComponent(chapter.resourcePath)
            if let data = try? Data(contentsOf: file) {
                let html = CharsetDetector.decode(data)
                if let parsed = try? HTMLTextParser.parse(html: html, title: chapter.title, format: .epub) {
                    return parsed.chapters.map { $0.text }.joined(separator: "\n\n")
                }
            }
        }
        if chapter.startOffset >= 0, chapter.endOffset > chapter.startOffset {
            if let t = try? TXTParser.readChapterText(fileURL: URL(fileURLWithPath: chapter.url),
                                                     range: chapter.startOffset..<chapter.endOffset) {
                return t
            }
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: chapter.url)) {
            return CharsetDetector.decode(data)
        }
        return ""
    }

    // MARK: 排版

    func repaginate(size: CGSize, force: Bool = false) {
        guard !isComic else { return }
        let text = pendingText
        guard !text.isEmpty else { return }
        if !force, size == lastLayoutSize, paginated != nil,
           paginated?.text.count == text.count { return }
        lastLayoutSize = size

        let prepared = ReaderTextPreparer.prepare(text, settings: settings)
        let cfg = settings
        let keepAnchor = anchorChar

        Task.detached(priority: .userInitiated) {
            let result = Paginator.paginate(text: prepared, settings: cfg, size: size)
            await MainActor.run {
                self.paginated = result
                let idx = Paginator.pageIndex(forCharacter: keepAnchor, in: result)
                self.pageIndex = min(idx, max(0, result.pageCount - 1))
                self.anchorChar = 0
            }
        }
    }

    // MARK: 翻页

    var currentChapter: Chapter? {
        guard chapterIndex >= 0, chapterIndex < chapters.count else { return nil }
        return chapters[chapterIndex]
    }

    var pageCount: Int { paginated?.pageCount ?? 0 }

    func nextPage() {
        guard let p = paginated else { return }
        if pageIndex + 1 < p.pageCount {
            pageIndex += 1
            recordAnchor()
            saveProgress()
        } else if chapterIndex + 1 < chapters.count {
            Task { await loadChapter(at: chapterIndex + 1) }
        }
    }

    func previousPage() {
        if pageIndex > 0 {
            pageIndex -= 1
            recordAnchor()
            saveProgress()
        } else if chapterIndex > 0 {
            Task {
                await loadChapter(at: chapterIndex - 1)
                await MainActor.run {
                    if let p = self.paginated {
                        self.pageIndex = max(0, p.pageCount - 1)
                        self.recordAnchor()
                    }
                    self.saveProgress()
                }
            }
        }
    }

    func jump(toChapter index: Int, char: Int = 0) {
        anchorChar = char
        Task { await loadChapter(at: index, targetChar: char) }
    }

    private func recordAnchor() {
        guard let p = paginated, pageIndex < p.ranges.count else { return }
        anchorChar = p.ranges[pageIndex].location
    }

    // MARK: 进度

    func saveProgress() {
        guard !chapters.isEmpty else { return }
        let total = max(1, chapters.count)
        let chapterPart = Double(chapterIndex) / Double(total)
        let pagePart = pageCount > 0
            ? Double(pageIndex) / Double(max(1, pageCount)) / Double(total)
            : 0
        let percent = min(1.0, chapterPart + pagePart)
        let p = ReadingProgress(bookId: book.id, chapterIndex: chapterIndex,
                                chapterTitle: currentChapter?.title ?? "",
                                pageInChapter: pageIndex,
                                charOffset: anchorChar,
                                percent: percent, updatedAt: Date())
        libraryRepo.saveProgress(p)
    }

    // MARK: 预取

    /// 预取后续 N 章（N 由「设置 → 提前缓存」决定，0 表示不预取）
    private func prefetchNeighbors() {
        prefetchTask?.cancel()
        let depth = max(0, min(10, settings.prefetchChapters))
        guard depth > 0, !book.isLocal, !isComic,
              let source = SourceRepository.shared.source(id: book.sourceId) else { return }

        var targets: [Chapter] = []
        var idx = chapterIndex + 1
        while idx < chapters.count, targets.count < depth {
            let ch = chapters[idx]
            let hasCache = contentCache[idx] != nil
                || libraryRepo.content(chapterId: ch.id) != nil
            if !hasCache { targets.append(ch) }
            idx += 1
        }
        guard !targets.isEmpty else { return }

        let b = book
        logD("prefetch", "预取 \(targets.count) 章：\(targets.map { $0.title }.joined(separator: " / "))")
        prefetchTask = Task.detached(priority: .background) {
            for ch in targets {
                if Task.isCancelled { return }
                if let result = try? await SourceEngine.shared.content(source: source,
                                                                       book: b, chapter: ch) {
                    LibraryRepository.shared.saveContent(result, chapterId: ch.id)
                }
            }
        }
    }

    /// 章内按比例跳页（右侧竖条拖动用）
    func jumpToPage(ratio: Double) {
        guard let p = paginated, p.pageCount > 0 else { return }
        let clamped = min(1, max(0, ratio))
        let target = min(p.pageCount - 1, max(0, Int((Double(p.pageCount - 1) * clamped).rounded())))
        if target != pageIndex {
            pageIndex = target
            recordAnchor()
            saveProgress()
        }
    }

    /// 当前页在本章的进度 0...1
    var chapterProgress: Double {
        guard let p = paginated, p.pageCount > 0 else { return 0 }
        if p.pageCount == 1 { return 1 }
        return Double(pageIndex) / Double(p.pageCount - 1)
    }

    // MARK: 刷新 / 换源

    /// 刷新当前章：清掉内存与磁盘缓存，重新拉一次
    func reloadChapter() {
        guard let ch = currentChapter else { return }
        contentCache[chapterIndex] = nil
        libraryRepo.deleteContent(chapterId: ch.id)
        showMenu = false
        pendingText = ""
        paginated = nil
        Task { await loadChapter(at: chapterIndex, targetChar: anchorChar) }
    }

    /// 在所有已启用源里找同名书（排除当前源）
    func findSameBookInOtherSources() async -> [Book] {
        let name = book.name
        let currentSourceId = book.sourceId
        let sources = SourceRepository.shared.all().filter {
            $0.enabled && $0.id != currentSourceId && !$0.searchUrl.isEmpty
        }
        guard !sources.isEmpty else { return [] }

        var collected: [Book] = []
        await withTaskGroup(of: [Book].self) { group in
            for s in sources {
                group.addTask {
                    (try? await SourceEngine.shared.search(source: s, key: name)) ?? []
                }
            }
            for await list in group {
                collected.append(contentsOf: list)
            }
        }
        // 只保留书名相近的，避免搜出一堆无关结果
        let normalized = name.replacingOccurrences(of: " ", with: "")
        return collected.filter {
            let n = $0.name.replacingOccurrences(of: " ", with: "")
            return n == normalized || n.contains(normalized) || normalized.contains(n)
        }
    }

    /// 换源：保留书籍条目、id 与阅读进度比例，只把数据来源换掉
    func switchSource(to target: Book) {
        guard !chapters.isEmpty || chapterIndex == 0 else { return }
        let ratio = chapters.isEmpty
            ? 0
            : Double(chapterIndex) / Double(max(1, chapters.count))

        var updated = book
        updated.sourceId = target.sourceId
        updated.sourceName = target.sourceName
        updated.bookUrl = target.bookUrl
        updated.tocUrl = target.tocUrl.isEmpty ? target.bookUrl : target.tocUrl
        if !target.coverUrl.isEmpty { updated.coverUrl = target.coverUrl }
        if !target.intro.isEmpty { updated.intro = target.intro }
        if !target.lastChapter.isEmpty { updated.lastChapter = target.lastChapter }
        book = updated
        libraryRepo.saveBook(updated)

        libraryRepo.deleteChapters(bookId: book.id)
        chapters = []
        contentCache.removeAll()
        paginated = nil
        pendingText = ""
        chapterIndex = 0
        pageIndex = 0
        anchorChar = 0
        showSourceSwap = false

        loadTocThenChapter(seekRatio: ratio)
    }

    // MARK: 漫画

    private func loadComic(_ chapter: Chapter) {
        if !chapter.resourcePath.isEmpty {
            comicImages = chapter.resourcePath
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
            loading = false
            saveProgress()
            return
        }
        guard let source = SourceRepository.shared.source(id: book.sourceId) else {
            comicImages = []
            loading = false
            return
        }
        if let stored = libraryRepo.content(chapterId: chapter.id), !stored.imageUrls.isEmpty {
            comicImages = stored.imageUrls
            loading = false
            return
        }
        Task {
            do {
                let result = try await SourceEngine.shared.content(source: source, book: book,
                                                                   chapter: chapter)
                await MainActor.run {
                    self.comicImages = result.imageUrls
                    self.loading = false
                    self.saveProgress()
                }
                self.libraryRepo.saveContent(result, chapterId: chapter.id)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    func comicNextChapter() {
        guard chapterIndex + 1 < chapters.count else { return }
        Task { await loadChapter(at: chapterIndex + 1) }
    }

    // MARK: 设置变更

    func apply(settings newSettings: ReadingSettings) {
        let size = lastLayoutSize
        let oldPrefetch = settings.prefetchChapters
        let shouldRepaginate = newSettings.fontSize != settings.fontSize
            || newSettings.lineHeightMultiple != settings.lineHeightMultiple
            || newSettings.fontFamily != settings.fontFamily
            || newSettings.marginH != settings.marginH
            || newSettings.marginV != settings.marginV
            || newSettings.letterSpacing != settings.letterSpacing
            || newSettings.justify != settings.justify
            || newSettings.firstLineIndent != settings.firstLineIndent
        settings = newSettings
        if shouldRepaginate, size.width > 0 {
            repaginate(size: size, force: true)
        }
        if newSettings.prefetchChapters != oldPrefetch { prefetchNeighbors() }
    }
}
