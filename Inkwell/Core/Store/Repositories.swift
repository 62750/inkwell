import Foundation
import GRDB

// MARK: - 书源仓库

final class SourceRepository: @unchecked Sendable {
    static let shared = SourceRepository()
    private let db = AppDatabase.shared

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func all() -> [BookSource] {
        let raw = (try? db.dbQueue.read { dbase in
            try BookSourceRecord.order(Column("orderIndex")).fetchAll(dbase)
        })?.compactMap { rec -> BookSource? in
            guard let d = rec.payload.data(using: .utf8) else { return nil }
            guard var s = try? decoder.decode(BookSource.self, from: d) else { return nil }
            s.id = rec.id
            s.enabled = rec.enabled
            s.bookSourceGroup = rec.groupName
            return s
        } ?? []
        // 校准 / 手动微调的覆盖层在这里合并，原始 JSON 保持不动
        return raw.map { RuleOverlay.shared.apply($0) }
    }

    /// 只取计数，不反序列化，用于启动阶段快速判断是否需要写入内置源
    func count() -> Int {
        let n = (try? db.dbQueue.read { dbase in
            try Int.fetchOne(dbase, sql: "SELECT COUNT(*) FROM book_source")
        }) ?? nil
        return n ?? 0
    }

    func source(id: String) -> BookSource? {
        let fetched = (try? db.dbQueue.read { dbase in
            try BookSourceRecord.fetchOne(dbase, key: id)
        }) ?? nil
        guard let rec = fetched, let d = rec.payload.data(using: .utf8) else { return nil }
        guard var s = try? decoder.decode(BookSource.self, from: d) else { return nil }
        s.id = rec.id
        s.enabled = rec.enabled
        return RuleOverlay.shared.apply(s)
    }

    func save(_ source: BookSource) {
        guard let data = try? encoder.encode(source),
              let payload = String(data: data, encoding: .utf8) else { return }
        let maxOrder = (try? db.dbQueue.read { dbase in
            try Int.fetchOne(dbase, sql: "SELECT COALESCE(MAX(orderIndex), 0) FROM book_source")
        }) ?? nil
        let order = (maxOrder ?? 0) + 1
        let rec = BookSourceRecord(id: source.id,
                                   payload: payload,
                                   name: source.displayName,
                                   groupName: source.bookSourceGroup,
                                   type: source.bookSourceType,
                                   enabled: source.enabled,
                                   orderIndex: order,
                                   updatedAt: Date().timeIntervalSince1970)
        try? db.dbQueue.write { dbase in try rec.insert(dbase, onConflict: .replace) }
    }

    func saveAll(_ sources: [BookSource]) {
        for s in sources { save(s) }
    }

    func delete(ids: [String]) {
        try? db.dbQueue.write { dbase in
            _ = try BookSourceRecord.deleteAll(dbase, keys: ids)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        try? db.dbQueue.write { dbase in
            if var rec = try BookSourceRecord.fetchOne(dbase, key: id) {
                rec.enabled = enabled
                try rec.insert(dbase, onConflict: .replace)
            }
        }
    }

    /// 导入 JSON（数组或单对象），返回新增数量
    @discardableResult
    func importData(_ data: Data) -> [BookSource] {
        let sources = LenientDecoder.decodeSources(from: data)
        saveAll(sources)
        return sources
    }

    @discardableResult
    func importText(_ text: String) -> [BookSource] {
        guard let d = text.data(using: .utf8) else { return [] }
        return importData(d)
    }

    func groups() -> [String] {
        let all = all()
        var set = Set<String>()
        for s in all {
            for g in s.groupList { set.insert(g) }
        }
        return Array(set).sorted()
    }
}

// MARK: - 书库仓库

final class LibraryRepository: @unchecked Sendable {
    static let shared = LibraryRepository()
    private let db = AppDatabase.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: 书

    func allBooks() -> [Book] {
        (try? db.dbQueue.read { dbase in
            try BookRecord.order(Column("lastReadAt").desc).fetchAll(dbase)
        })?.compactMap { decodeBook($0) } ?? []
    }

    func book(id: String) -> Book? {
        guard let rec = try? db.dbQueue.read({ dbase in
            try BookRecord.fetchOne(dbase, key: id)
        }), let rec else { return nil }
        return decodeBook(rec)
    }

    private func decodeBook(_ rec: BookRecord) -> Book? {
        guard let d = rec.payload.data(using: .utf8) else { return nil }
        return try? decoder.decode(Book.self, from: d)
    }

    func saveBook(_ book: Book) {
        guard let data = try? encoder.encode(book),
              let payload = String(data: data, encoding: .utf8) else { return }
        let rec = BookRecord(id: book.id, payload: payload, name: book.name,
                             author: book.author, sourceId: book.sourceId,
                             isLocal: book.isLocal,
                             lastReadAt: book.lastReadAt?.timeIntervalSince1970 ?? 0,
                             addedAt: book.addedAt.timeIntervalSince1970)
        try? db.dbQueue.write { dbase in try rec.insert(dbase, onConflict: .replace) }
    }

    func deleteBook(id: String) {
        try? db.dbQueue.write { dbase in
            _ = try BookRecord.deleteOne(dbase, key: id)
            _ = try ChapterRecord.deleteAll(dbase, Column("bookId") == id)
            _ = try ProgressRecord.deleteOne(dbase, key: id)
            _ = try BookmarkRecord.deleteAll(dbase, Column("bookId") == id)
        }
    }

    // MARK: 章节

    func chapters(bookId: String) -> [Chapter] {
        (try? db.dbQueue.read { dbase in
            try ChapterRecord.filter(Column("bookId") == bookId)
                .order(Column("index")).fetchAll(dbase)
        })?.map { rec in
            Chapter(bookId: rec.bookId, index: rec.index, title: rec.title,
                    url: rec.url, baseUrl: rec.baseUrl,
                    isVip: rec.isVip, isVolume: false,
                    startOffset: rec.startOffset, endOffset: rec.endOffset,
                    resourcePath: rec.resourcePath)
        } ?? []
    }

    func saveChapters(_ chapters: [Chapter], bookId: String) {
        guard !chapters.isEmpty else { return }
        let recs = chapters.map {
            ChapterRecord(id: $0.id, bookId: $0.bookId, index: $0.index,
                          title: $0.title, url: $0.url, baseUrl: $0.baseUrl,
                          resourcePath: $0.resourcePath,
                          startOffset: $0.startOffset, endOffset: $0.endOffset,
                          isVip: $0.isVip)
        }
        try? db.dbQueue.write { dbase in
            _ = try ChapterRecord.deleteAll(dbase, Column("bookId") == bookId)
            for r in recs { try r.insert(dbase) }
        }
    }

    // MARK: 正文缓存

    func content(chapterId: String) -> ContentResult? {
        guard let rec = try? db.dbQueue.read({ dbase in
            try ContentRecord.fetchOne(dbase, key: chapterId)
        }), let rec else { return nil }
        let imgs = rec.imageURLs.components(separatedBy: "\n").filter { !$0.isEmpty }
        return ContentResult(text: rec.text, html: "", imageUrls: imgs,
                             nextPageUrl: nil, isComic: !imgs.isEmpty)
    }

    func saveContent(_ content: ContentResult, chapterId: String) {
        let rec = ContentRecord(id: chapterId, text: content.text,
                                imageURLs: content.imageUrls.joined(separator: "\n"),
                                updatedAt: Date().timeIntervalSince1970)
        try? db.dbQueue.write { dbase in try rec.insert(dbase, onConflict: .replace) }
    }

    func clearContent(bookId: String) {
        let ids = chapters(bookId: bookId).map { $0.id }
        guard !ids.isEmpty else { return }
        try? db.dbQueue.write { dbase in
            _ = try ContentRecord.deleteAll(dbase, keys: ids)
        }
    }

    // MARK: 进度

    func progress(bookId: String) -> ReadingProgress? {
        guard let rec = try? db.dbQueue.read({ dbase in
            try ProgressRecord.fetchOne(dbase, key: bookId)
        }), let rec else { return nil }
        return ReadingProgress(bookId: rec.bookId, chapterIndex: rec.chapterIndex,
                               chapterTitle: rec.chapterTitle,
                               pageInChapter: rec.pageInChapter,
                               charOffset: rec.charOffset, percent: rec.percent,
                               updatedAt: Date(timeIntervalSince1970: rec.updatedAt))
    }

    func saveProgress(_ p: ReadingProgress) {
        let rec = ProgressRecord(bookId: p.bookId, chapterIndex: p.chapterIndex,
                                 chapterTitle: p.chapterTitle,
                                 pageInChapter: p.pageInChapter,
                                 charOffset: p.charOffset, percent: p.percent,
                                 updatedAt: Date().timeIntervalSince1970)
        try? db.dbQueue.write { dbase in
            try rec.insert(dbase, onConflict: .replace)
            // 同步书的最后阅读时间
            if var b = try BookRecord.fetchOne(dbase, key: p.bookId),
               let d = b.payload.data(using: .utf8),
               var book = try? self.decoder.decode(Book.self, from: d) {
                book.lastReadAt = Date()
                if let nd = try? self.encoder.encode(book),
                   let payload = String(data: nd, encoding: .utf8) {
                    b.payload = payload
                    b.lastReadAt = Date().timeIntervalSince1970
                    try b.insert(dbase, onConflict: .replace)
                }
            }
        }
    }

    // MARK: 书签

    func bookmarks(bookId: String) -> [Bookmark] {
        let fetched = (try? db.dbQueue.read { dbase in
            try BookmarkRecord.filter(Column("bookId") == bookId)
                .order(Column("createdAt").desc).fetchAll(dbase)
        }) ?? nil
        guard let recs = fetched else { return [] }
        return recs.map {
            Bookmark(id: $0.id, bookId: $0.bookId, chapterIndex: $0.chapterIndex,
                     chapterTitle: $0.chapterTitle, charOffset: $0.charOffset,
                     excerpt: $0.excerpt, note: $0.note,
                     createdAt: Date(timeIntervalSince1970: $0.createdAt),
                     colorHex: $0.colorHex)
        }
    }

    func saveBookmark(_ b: Bookmark) {
        let rec = BookmarkRecord(id: b.id, bookId: b.bookId, chapterIndex: b.chapterIndex,
                                 chapterTitle: b.chapterTitle, charOffset: b.charOffset,
                                 excerpt: b.excerpt, note: b.note, colorHex: b.colorHex,
                                 createdAt: b.createdAt.timeIntervalSince1970)
        try? db.dbQueue.write { dbase in try rec.insert(dbase, onConflict: .replace) }
    }

    func deleteBookmark(id: String) {
        try? db.dbQueue.write { dbase in
            _ = try BookmarkRecord.deleteOne(dbase, key: id)
        }
    }
}
