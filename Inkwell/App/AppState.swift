import Foundation
import SwiftUI

// MARK: - 启动阶段

enum LaunchPhase: String, Sendable {
    case booting      // 还没碰数据库
    case sources      // 正在读书源
    case library      // 正在读书架
    case ready

    var isReady: Bool { self == .ready }
}

// MARK: - 全局状态
//
// 启动速度设计：
//   1. init 里什么都不做（不碰 SQLite、不解析 JSON）
//   2. bootstrap() 分三段异步推进，每段完成就立刻刷 UI，不等全部
//   3. 数据库在后台第一次被访问时惰性打开，成本落在后台线程
//   4. 内置源只在「确实是首次启动」时写入，且写完再刷新一次列表

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var phase: LaunchPhase = .booting
    @Published var sources: [BookSource] = []
    @Published var books: [Book] = []
    @Published var settings: ReadingSettings = .default
    @Published var toast: String?
    @Published private(set) var launchMetrics: [String: Double] = [:]

    private let sourceRepo = SourceRepository.shared
    private let libraryRepo = LibraryRepository.shared
    private let settingsKey = "inkwell.reading.settings.v1"
    private var bootstrapped = false
    private let launchStart = Date()

    private init() {
        // 只读一次 UserDefaults（微秒级），保证首帧就用上正确的主题，避免闪白
        loadSettings()
    }

    // MARK: 启动

    /// 由 RootView 的 .task 调用，保证在首帧之后才开始
    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true

        let t0 = Date()

        // —— 阶段 1：DB 预热 + 书源
        await MainActor.run { self.phase = .sources }
        let sources = await Self.readSourcesOffMain()
        await MainActor.run {
            self.sources = sources
            self.mark("sources", since: t0)
        }

        // 内置源同步：只在版本变化时跑一次（清理旧空壳 + 更新规则），不影响启动速度
        let synced = await Self.syncBuiltinsOffMain()
        if synced.changed {
            let reloaded = await Self.readSourcesOffMain()
            await MainActor.run {
                self.sources = reloaded
                if synced.removed > 0 {
                    self.showToast("已清理 \(synced.removed) 个失效内置源，更新 \(synced.updated) 个")
                } else if synced.updated > 0 {
                    self.showToast("已更新 \(synced.updated) 个内置书源")
                }
            }
        }

        // —— 阶段 2：书架
        await MainActor.run { self.phase = .library }
        let t1 = Date()
        let books = await Self.readBooksOffMain()
        await MainActor.run {
            self.books = books
            self.mark("library", since: t1)
        }

        // —— 阶段 3：设置 + 收尾
        await MainActor.run {
            self.loadSettings()
            self.phase = .ready
            self.mark("total", since: self.launchStart)
        }

        // 启动完成后后台预热剩下的东西
        Task.detached(priority: .background) {
            AppDatabase.shared.warmUp()
            InboxImporter.purgeOldFiles()
            // 订阅本身不自动拉取：联网行为交给用户
        }
    }

    private func mark(_ key: String, since: Date) {
        launchMetrics[key] = Date().timeIntervalSince(since) * 1000
        logD("launch", String(format: "%@ %.1fms", key, launchMetrics[key] ?? 0))
    }

    // 后台读取（SQLite 不在主线程跑）

    private nonisolated static func readSourcesOffMain() async -> [BookSource] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: SourceRepository.shared.all())
            }
        }
    }

    private nonisolated static func readBooksOffMain() async -> [Book] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: LibraryRepository.shared.allBooks())
            }
        }
    }

    /// 内置源同步版本：每次改内置源内容就 +1
    nonisolated static let builtinSyncVersion = 5
    static let builtinSyncKey = "inkwell.builtin.sync.version"

    /// 清理过期内置源 + 用新版规则覆盖同名内置源。
    /// 只在内置源版本变化时执行，正常启动零开销。
    nonisolated static func syncBuiltinsOffMain() async -> (changed: Bool, removed: Int, updated: Int) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let current = UserDefaults.standard.integer(forKey: builtinSyncKey)
                guard current != builtinSyncVersion else {
                    cont.resume(returning: (false, 0, 0))
                    return
                }
                let repo = SourceRepository.shared
                let existing = repo.all()
                let seeds = BuiltinSources.seeds()
                let seedNames = Set(seeds.map { $0.bookSourceName })

                // 1) 删掉不再存在的内置源（旧版空壳、废弃站点）
                let stale = existing.filter { s in
                    guard s.bookSourceGroup.hasPrefix("内置") else { return false }
                    return !seedNames.contains(s.bookSourceName)
                }
                if !stale.isEmpty {
                    repo.delete(ids: stale.map { $0.id })
                }

                // 2) 同名则用新规则覆盖（保留 id 和用户的启停状态）
                var toWrite: [BookSource] = []
                var updated = 0
                for seed in seeds {
                    if let old = existing.first(where: { $0.bookSourceName == seed.bookSourceName }) {
                        var merged = seed
                        merged.id = old.id
                        merged.enabled = old.enabled
                        toWrite.append(merged)
                        updated += 1
                    } else {
                        toWrite.append(seed)
                        updated += 1
                    }
                }
                repo.saveAll(toWrite)
                UserDefaults.standard.set(builtinSyncVersion, forKey: builtinSyncKey)
                cont.resume(returning: (true, stale.count, updated))
            }
        }
    }

    private nonisolated static func writeSourcesOffMain(_ list: [BookSource]) async {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                SourceRepository.shared.saveAll(list)
                cont.resume()
            }
        }
    }

    // MARK: 书源

    func loadSources() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = SourceRepository.shared.all()
            Task { @MainActor in self.sources = list }
        }
    }

    /// 同步刷新（保存/删除后立刻反映）
    func reloadSourcesNow() {
        sources = sourceRepo.all()
    }

    /// 一键清理：keepBuiltin=true 时只保留「内置·」分组的源，并强制重新同步内置源
    func clearAllSources(keepBuiltin: Bool = true) {
        let targets: [BookSource]
        if keepBuiltin {
            targets = sources.filter { !$0.bookSourceGroup.hasPrefix("内置") }
        } else {
            targets = sources
        }
        guard !targets.isEmpty else {
            showToast(keepBuiltin ? "除了内置源，没有其它源可删" : "没有书源可删")
            return
        }
        let ids = targets.map { $0.id }
        sourceRepo.delete(ids: ids)
        for id in ids { RuleOverlay.shared.clear(sourceId: id) }
        reloadSourcesNow()
        showToast("正在清理 \(ids.count) 个源…")

        // 强制下一轮重新同步内置源
        UserDefaults.standard.set(0, forKey: Self.builtinSyncKey)
        Task {
            let r = await Self.syncBuiltinsOffMain()
            await MainActor.run {
                self.reloadSourcesNow()
                self.showToast("已删除 \(ids.count) 个源，内置源 \(r.updated) 个已就绪")
            }
        }
    }

    func saveSource(_ source: BookSource) {
        sourceRepo.save(source)
        reloadSourcesNow()
    }

    func saveSources(_ list: [BookSource]) {
        sourceRepo.saveAll(list)
        reloadSourcesNow()
    }

    func deleteSources(_ ids: [String]) {
        sourceRepo.delete(ids: ids)
        for id in ids { RuleOverlay.shared.clear(sourceId: id) }
        reloadSourcesNow()
    }

    func toggleSource(_ id: String, enabled: Bool) {
        sourceRepo.setEnabled(id, enabled)
        if let i = sources.firstIndex(where: { $0.id == id }) {
            sources[i].enabled = enabled
        }
    }

    @discardableResult
    func importSourceJSON(_ text: String) -> Int {
        let imported = sourceRepo.importText(text)
        reloadSourcesNow()
        showToast(imported.isEmpty ? "没有识别到书源" : "已导入 \(imported.count) 个书源")
        return imported.count
    }

    var enabledSources: [BookSource] { sources.filter { $0.enabled } }

    var comicSources: [BookSource] { sources.filter { $0.isComic } }
    var textSources: [BookSource] { sources.filter { !$0.isComic } }

    // MARK: 书架

    func loadBooks() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = LibraryRepository.shared.allBooks()
            Task { @MainActor in self.books = list }
        }
    }

    /// 外部文件导入（「用其他应用打开」→ 墨阅，或 .onOpenURL）
    func importFile(_ url: URL) {
        let name = url.lastPathComponent
        showToast("正在导入 \(name)…")
        Task.detached {
            do {
                let staged = try InboxImporter.stage(url)
                let book = try LocalBookImporter.importAndStore(at: staged)
                InboxImporter.cleanUp(staged)
                await MainActor.run {
                    self.loadBooks()
                    self.showToast("已导入：\(book.name)（\(book.totalChapters) 章）")
                }
            } catch {
                await MainActor.run {
                    self.showToast("导入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func addBook(_ book: Book) {
        libraryRepo.saveBook(book)
        loadBooks()
    }

    func removeBook(_ id: String) {
        libraryRepo.deleteBook(id: id)
        books.removeAll { $0.id == id }
    }

    // MARK: 设置

    func loadSettings() {
        if let d = UserDefaults.standard.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(ReadingSettings.self, from: d) {
            settings = s
        }
    }

    func updateSettings(_ s: ReadingSettings) {
        settings = s
        if let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: settingsKey)
        }
    }

    // MARK: Toast

    func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == msg { toast = nil }
        }
    }
}

// MARK: - 图片加载（带磁盘缓存与并发去重）

actor ImageLoader {
    static let shared = ImageLoader()

    private var memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let cacheDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("inkwell-images", isDirectory: true)
        memory.countLimit = 160
        memory.totalCostLimit = 220 << 20
    }

    private func ensureDir() {
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }

    func image(url: String, referer: String? = nil) async -> UIImage? {
        let key = url as NSString
        if let cached = memory.object(forKey: key) { return cached }
        if let t = inFlight[url] { return await t.value }

        let dir = cacheDir
        let task = Task<UIImage?, Never> {
            let file = dir.appendingPathComponent(InsecureDigest.sha1Hex(url) + ".img")
            if let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
                return img
            }
            guard let data = try? await HTTPClient.shared.imageData(url: url, referer: referer),
                  let img = UIImage(data: data) else { return nil }
            try? data.write(to: file)
            return img
        }
        inFlight[url] = task
        let img = await task.value
        if let img {
            memory.setObject(img, forKey: key,
                             cost: Int(img.size.width * img.size.height * 4))
        }
        inFlight[url] = nil
        return img
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        ensureDir()
    }
}

// MARK: - 异步图片视图

struct RemoteImage: View {
    let url: String
    var referer: String? = nil
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Rectangle().fill(Color.secondary.opacity(0.12))
                    .overlay(Image(systemName: "photo")
                        .foregroundStyle(.secondary.opacity(0.5)))
            } else {
                Rectangle().fill(Color.secondary.opacity(0.10))
                    .overlay(ProgressView().scaleEffect(0.7))
            }
        }
        .task(id: url) {
            guard !url.isEmpty else { failed = true; return }
            failed = false
            let img = await ImageLoader.shared.image(url: url, referer: referer)
            image = img
            if img == nil { failed = true }
        }
    }
}
