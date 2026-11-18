import Foundation
import GRDB

// MARK: - 数据库（惰性打开 + WAL）
//
// 启动速度关键点：
//   1. 不在 App.init 里碰 SQLite —— 首次真正需要数据时才打开
//   2. 打开时一次性设好 WAL / synchronous=NORMAL / mmap，后续查询全部走内存页缓存
//   3. 迁移用 GRDB 的 DatabaseMigrator，靠 user_version 只跑一次
//   4. 提供「轻量投影查询」，列表页不反序列化整份 JSON

struct BookSourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "book_source"
    var id: String
    var payload: String        // BookSource 的 JSON
    var name: String
    var groupName: String
    var type: Int
    var enabled: Bool
    var orderIndex: Int
    var updatedAt: Double

    enum Columns {
        static let id = Column("id")
        static let enabled = Column("enabled")
        static let groupName = Column("groupName")
        static let orderIndex = Column("orderIndex")
        static let name = Column("name")
        static let type = Column("type")
    }
}

/// 列表页用的轻量投影：不读 payload 大字段
struct SourceLite: FetchableRecord, Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var groupName: String
    var type: Int
    var enabled: Bool
}

struct BookRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "book"
    var id: String
    var payload: String
    var name: String
    var author: String
    var sourceId: String
    var isLocal: Bool
    var lastReadAt: Double
    var addedAt: Double

    enum Columns {
        static let id = Column("id")
        static let lastReadAt = Column("lastReadAt")
        static let isLocal = Column("isLocal")
        static let addedAt = Column("addedAt")
    }
}

struct ChapterRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "chapter"
    var id: String
    var bookId: String
    var index: Int
    var title: String
    var url: String
    var baseUrl: String
    var resourcePath: String
    var startOffset: Int
    var endOffset: Int
    var isVip: Bool

    enum Columns {
        static let bookId = Column("bookId")
        static let index = Column("index")
    }
}

struct ContentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "content"
    var id: String            // chapterId
    var text: String
    var imageURLs: String
    var updatedAt: Double
}

struct ProgressRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "progress"
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var pageInChapter: Int
    var charOffset: Int
    var percent: Double
    var updatedAt: Double
    var id: String { bookId }
}

struct BookmarkRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "bookmark"
    var id: String
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var charOffset: Int
    var excerpt: String
    var note: String
    var colorHex: String
    var createdAt: Double
}

// MARK: - 数据库容器

final class AppDatabase: @unchecked Sendable {
    static let shared = AppDatabase()

    private var _queue: DatabaseQueue?
    private let lock = NSLock()
    private(set) var openMilliseconds: Double = 0

    private init() {}

    /// 惰性打开：第一次访问才付出建库/迁移的成本
    var dbQueue: DatabaseQueue {
        lock.lock()
        if let q = _queue {
            lock.unlock()
            return q
        }
        let started = Date()
        let q = Self.openQueue()
        _queue = q
        openMilliseconds = Date().timeIntervalSince(started) * 1000
        lock.unlock()
        return q
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return _queue != nil
    }

    /// 预热：启动完成后在后台调一次，把建库成本挪出首帧
    func warmUp() {
        _ = dbQueue
    }

    private static func openQueue() -> DatabaseQueue {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Inkwell", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("inkwell.sqlite").path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        config.maximumReaderCount = 4

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: path, configuration: config)
        } catch {
            // 极端情况退回内存库，保证 App 不崩
            queue = try! DatabaseQueue(configuration: config)
        }
        try? migrate(queue)
        return queue
    }

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "book_source") { t in
                t.column("id", .text).primaryKey()
                t.column("payload", .text).notNull()
                t.column("name", .text).notNull()
                t.column("groupName", .text).notNull().defaults(to: "")
                t.column("type", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("orderIndex", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "book") { t in
                t.column("id", .text).primaryKey()
                t.column("payload", .text).notNull()
                t.column("name", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
                t.column("sourceId", .text).notNull().defaults(to: "")
                t.column("isLocal", .boolean).notNull().defaults(to: false)
                t.column("lastReadAt", .double).notNull().defaults(to: 0)
                t.column("addedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "chapter") { t in
                t.column("id", .text).primaryKey()
                t.column("bookId", .text).notNull()
                t.column("index", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("url", .text).notNull().defaults(to: "")
                t.column("baseUrl", .text).notNull().defaults(to: "")
                t.column("resourcePath", .text).notNull().defaults(to: "")
                t.column("startOffset", .integer).notNull().defaults(to: -1)
                t.column("endOffset", .integer).notNull().defaults(to: -1)
                t.column("isVip", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_chapter_book", on: "chapter",
                          columns: ["bookId", "index"])
            try db.create(table: "content") { t in
                t.column("id", .text).primaryKey()
                t.column("text", .text).notNull()
                t.column("imageURLs", .text).notNull().defaults(to: "")
                t.column("updatedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "progress") { t in
                t.column("bookId", .text).primaryKey()
                t.column("chapterIndex", .integer).notNull().defaults(to: 0)
                t.column("chapterTitle", .text).notNull().defaults(to: "")
                t.column("pageInChapter", .integer).notNull().defaults(to: 0)
                t.column("charOffset", .integer).notNull().defaults(to: 0)
                t.column("percent", .double).notNull().defaults(to: 0)
                t.column("updatedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "bookmark") { t in
                t.column("id", .text).primaryKey()
                t.column("bookId", .text).notNull()
                t.column("chapterIndex", .integer).notNull()
                t.column("chapterTitle", .text).notNull().defaults(to: "")
                t.column("charOffset", .integer).notNull().defaults(to: 0)
                t.column("excerpt", .text).notNull().defaults(to: "")
                t.column("note", .text).notNull().defaults(to: "")
                t.column("colorHex", .text).notNull().defaults(to: "#E8B85C")
                t.column("createdAt", .double).notNull().defaults(to: 0)
            }
        }

        // v2：列表页索引 + 覆盖层不再依赖 DB（走 UserDefaults），这里只补索引
        migrator.registerMigration("v2") { db in
            try db.create(index: "idx_source_enabled", on: "book_source",
                          columns: ["enabled", "orderIndex"])
            try db.create(index: "idx_book_recent", on: "book",
                          columns: ["lastReadAt"])
        }
        try migrator.migrate(queue)
    }
}
