import Foundation

// MARK: - 书源订阅 / 规则覆盖层 / 替换接口
//
// 三个独立机制，互不干扰：
//   1. 订阅（SourcePack）：从远程 JSON 拉整包书源，三种合并策略
//   2. 覆盖层（RuleOverride）：校准/手调的结果单独存，原规则不变，可回滚
//   3. 替换（Swap）：整包导出/导入/分享，换一套源 = 换一个 JSON

// MARK: 订阅模型

enum MergeMode: String, Codable, CaseIterable, Sendable {
    case replace      // 整包替换：同 URL 的本地源被覆盖
    case merge        // 增量合并：只加新的，同名同址跳过
    case keepLocal    // 保留本地：只补本地没有的

    var label: String {
        switch self {
        case .replace: return "整包替换"
        case .merge: return "增量合并"
        case .keepLocal: return "只补缺"
        }
    }

    var note: String {
        switch self {
        case .replace: return "以订阅包为准，本地对该源的修改会被覆盖"
        case .merge: return "本地已有同名源就跳过，只补新源"
        case .keepLocal: return "本地已存在的绝不覆盖，最安全"
        }
    }
}

struct SourcePack: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var enabled: Bool = true
    var mergeMode: MergeMode = .merge
    var lastFetched: Date?
    var lastCount: Int = 0
    var lastError: String?
}

// MARK: 覆盖层

struct RuleOverride: Codable, Hashable, Sendable {
    var sourceId: String
    var field: String        // 形如 "ruleSearch.bookList"
    var value: String
    var updatedAt: Date
}

// MARK: 订阅管理

final class SourcePackManager: ObservableObject {
    static let shared = SourcePackManager()

    @Published private(set) var packs: [SourcePack] = []
    @Published private(set) var busyPackId: String?
    @Published private(set) var lastLog: [String] = []

    private let key = "inkwell.source.packs.v1"

    private init() { load() }

    // MARK: 存取

    func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SourcePack].self, from: d) else {
            packs = []
            return
        }
        packs = list
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(packs) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    func add(name: String, url: String, mode: MergeMode = .merge) -> SourcePack {
        var p = SourcePack(name: name.isEmpty ? (URL(string: url)?.host ?? "订阅") : name,
                           url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                           mergeMode: mode)
        packs.append(p)
        persist()
        return p
    }

    func update(_ pack: SourcePack) {
        if let i = packs.firstIndex(where: { $0.id == pack.id }) {
            packs[i] = pack
            persist()
        }
    }

    func remove(_ id: String) {
        packs.removeAll { $0.id == id }
        persist()
    }

    // MARK: 拉取

    @discardableResult
    func fetch(_ packId: String) async -> (added: Int, updated: Int, error: String?) {
        guard let pack = packs.first(where: { $0.id == packId }) else {
            return (0, 0, "订阅不存在")
        }
        await MainActor.run {
            self.busyPackId = packId
            self.lastLog = []
        }
        defer {
            Task { @MainActor in self.busyPackId = nil }
        }

        guard let url = URL(string: pack.url), url.scheme != nil else {
            await self.patch(packId: packId, error: "地址不合法")
            return (0, 0, "地址不合法")
        }

        do {
            let r = try await HTTPClient.shared.request(url: pack.url)
            let incoming = LenientDecoder.decodeSources(from: r.data)
            guard !incoming.isEmpty else {
                let msg = "该地址没有解析出书源（需要 Legado 格式 JSON）"
                await self.patch(packId: packId, error: msg)
                return (0, 0, msg)
            }
            let result = apply(incoming, mode: pack.mergeMode)
            await self.markFetched(packId: packId, count: result.added + result.updated)
            await MainActor.run {
                self.lastLog.append("\\(pack.name)：新增 \\(result.added)，更新 \\(result.updated)，跳过 \\(result.skipped)")
            }
            return (result.added, result.updated, nil)
        } catch {
            await self.patch(packId: packId, error: error.localizedDescription)
            return (0, 0, error.localizedDescription)
        }
    }

    @MainActor
    private func patch(packId: String, error: String) {
        if let i = packs.firstIndex(where: { $0.id == packId }) {
            packs[i].lastError = error
            persist()
        }
    }

    @MainActor
    private func markFetched(packId: String, count: Int) {
        if let i = packs.firstIndex(where: { $0.id == packId }) {
            packs[i].lastFetched = Date()
            packs[i].lastCount = count
            packs[i].lastError = nil
            persist()
        }
    }

    @discardableResult
    func fetchAll() async -> (added: Int, updated: Int) {
        var a = 0, u = 0
        for p in packs where p.enabled {
            let r = await fetch(p.id)
            a += r.added
            u += r.updated
        }
        return (a, u)
    }

    // MARK: 合并策略

    struct MergeResult {
        var added = 0
        var updated = 0
        var skipped = 0
    }

    private func apply(_ incoming: [BookSource], mode: MergeMode) -> MergeResult {
        let repo = SourceRepository.shared
        let existing = repo.all()
        // 以「书源地址 + 名称」作为身份
        var index: [String: BookSource] = [:]
        for s in existing { index[Self.identity(s)] = s }

        var result = MergeResult()
        for var src in incoming {
            let id = Self.identity(src)
            if let old = index[id] {
                switch mode {
                case .replace:
                    src.id = old.id          // 保持 id，书架引用不断
                    repo.save(src)
                    result.updated += 1
                case .merge, .keepLocal:
                    // 本地存在即跳过，保留用户的改动
                    result.skipped += 1
                }
            } else {
                repo.save(src)
                result.added += 1
            }
        }
        return result
    }

    private static func identity(_ s: BookSource) -> String {
        let u = s.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return u + "|" + s.bookSourceName + "|" + String(s.bookSourceType)
    }

    // MARK: 导出 / 分享

    func exportAll() -> String {
        let all = SourceRepository.shared.all()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(all),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    func exportEnabled() -> String {
        let all = SourceRepository.shared.all().filter { $0.enabled }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(all),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }
}

// MARK: - 规则覆盖层
//
// 校准与手动微调写这里，原书源 JSON 保持不变：
// 用户随时能「还原本源」，也能把覆盖一起导出分享。

final class RuleOverlay {
    static let shared = RuleOverlay()

    private let key = "inkwell.rule.overlay.v1"
    private var cache: [String: [String: String]] = [:]   // sourceId -> field -> value
    private let lock = NSLock()

    private init() { load() }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: [String: String]].self, from: d) else {
            return
        }
        cache = m
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    func set(sourceId: String, field: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        var m = cache[sourceId] ?? [:]
        m[field] = value
        cache[sourceId] = m
        persist()
    }

    func get(sourceId: String, field: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[sourceId]?[field]
    }

    func all(sourceId: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return cache[sourceId] ?? [:]
    }

    func clear(sourceId: String) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: sourceId)
        persist()
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return cache.values.reduce(0) { $0 + $1.count }
    }

    /// 把覆盖层盖到书源上（读的时候用）
    func apply(_ source: BookSource) -> BookSource {
        let m = all(sourceId: source.id)
        guard !m.isEmpty else { return source }
        var s = source
        for (field, value) in m {
            switch field {
            case "ruleSearch.bookList": s.ruleSearch.bookList = value
            case "ruleSearch.name": s.ruleSearch.name = value
            case "ruleSearch.author": s.ruleSearch.author = value
            case "ruleSearch.coverUrl": s.ruleSearch.coverUrl = value
            case "ruleSearch.bookUrl": s.ruleSearch.bookUrl = value
            case "ruleSearch.intro": s.ruleSearch.intro = value
            case "ruleBookInfo.name": s.ruleBookInfo.name = value
            case "ruleBookInfo.author": s.ruleBookInfo.author = value
            case "ruleBookInfo.intro": s.ruleBookInfo.intro = value
            case "ruleBookInfo.coverUrl": s.ruleBookInfo.coverUrl = value
            case "ruleBookInfo.tocUrl": s.ruleBookInfo.tocUrl = value
            case "ruleToc.chapterList": s.ruleToc.chapterList = value
            case "ruleToc.chapterName": s.ruleToc.chapterName = value
            case "ruleToc.chapterUrl": s.ruleToc.chapterUrl = value
            case "ruleToc.nextTocUrl": s.ruleToc.nextTocUrl = value
            case "ruleContent.content": s.ruleContent.content = value
            case "ruleContent.nextContentUrl": s.ruleContent.nextContentUrl = value
            case "searchUrl": s.searchUrl = value
            default: break
            }
        }
        return s
    }
}
