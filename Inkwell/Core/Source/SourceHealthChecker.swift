import Foundation

// MARK: - 书源体检
//
// 一个源"能不能用"要过五关：配置 → 搜索 → 详情 → 目录 → 正文。
// 哪一关挂了一目了然，不用猜。

struct HealthCheck: Identifiable, Sendable {
    var id: String { sourceName }
    let sourceName: String
    var config: Step = .pending
    var search: Step = .pending
    var bookInfo: Step = .pending
    var toc: Step = .pending
    var content: Step = .pending
    var sampleBook: String = ""
    var firstChapter: String = ""

    enum Step: Sendable {
        case pending
        case pass(String)
        case fail(String)

        var isFail: Bool { if case .fail = self { return true }; return false }
        var isPass: Bool { if case .pass = self { return true }; return false }

        var symbol: String {
            switch self {
            case .pending: return "—"
            case .pass: return "✓"
            case .fail: return "✗"
            }
        }

        var text: String {
            switch self {
            case .pending: return "未测试"
            case .pass(let m): return m
            case .fail(let m): return m
            }
        }
    }

    var allPassed: Bool {
        config.isPass && search.isPass && bookInfo.isPass && toc.isPass && content.isPass
    }

    var summary: String {
        if allPassed { return "完全可用" }
        if search.isFail || config.isFail { return "不可用" }
        if toc.isFail || content.isFail { return "目录/正文有问题" }
        return "部分可用"
    }
}

enum SourceHealthChecker {

    static func check(source: BookSource, keyword: String = "斗破") async -> HealthCheck {
        var r = HealthCheck(sourceName: source.displayName)

        // 1) 配置
        if source.bookSourceUrl.isEmpty {
            r.config = .fail("站点地址为空")
            return r
        }
        if source.searchUrl.isEmpty {
            r.config = .fail("searchUrl 为空")
            return r
        }
        if source.ruleSearch.bookList.isEmpty {
            r.config = .fail("列表规则为空")
            return r
        }
        r.config = .pass(source.bookSourceUrl)

        // 2) 搜索
        let books: [Book]
        do {
            books = try await SourceEngine.shared.search(source: source, key: keyword)
            if books.isEmpty {
                r.search = .fail("搜索返回 0 条（换关键词再试，或站点结构变了）")
                return r
            }
            r.search = .pass("搜到 \(books.count) 条")
        } catch {
            r.search = .fail(short(error))
            return r
        }

        guard let first = books.first else {
            r.search = .fail("无结果")
            return r
        }
        r.sampleBook = first.name

        // 3) 详情
        var info = first
        if !source.ruleBookInfo.name.isEmpty || !source.ruleBookInfo.intro.isEmpty {
            do {
                info = try await SourceEngine.shared.bookInfo(source: source,
                                                              bookUrl: first.bookUrl,
                                                              stub: first)
                r.bookInfo = .pass(info.name.isEmpty ? "取到页面但书名为空" : info.name)
            } catch {
                r.bookInfo = .fail(short(error))
            }
        } else {
            r.bookInfo = .pass("跳过（未配详情规则）")
        }

        // 4) 目录
        var chapters: [Chapter] = []
        do {
            let toc = try await SourceEngine.shared.toc(source: source, book: info)
            chapters = toc.chapters
            if chapters.isEmpty {
                r.toc = .fail("目录 0 章")
            } else {
                r.toc = .pass("\(chapters.count) 章")
            }
        } catch {
            r.toc = .fail(short(error))
        }

        guard let ch = chapters.first else { return r }
        r.firstChapter = ch.title

        // 5) 正文
        do {
            let c = try await SourceEngine.shared.content(source: source, book: info, chapter: ch)
            if c.isComic {
                r.content = c.imageUrls.isEmpty
                    ? .fail("漫画章节 0 张图")
                    : .pass("\(c.imageUrls.count) 张图")
            } else {
                r.content = c.text.count < 50
                    ? .fail("正文只有 \(c.text.count) 字")
                    : .pass("\(c.text.count) 字")
            }
        } catch {
            r.content = .fail(short(error))
        }

        return r
    }

    static func checkAll(_ sources: [BookSource], keyword: String = "斗破",
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [HealthCheck] {
        var out: [HealthCheck] = []
        for (i, s) in sources.enumerated() {
            progress?(i, sources.count)
            out.append(await check(source: s, keyword: keyword))
        }
        progress?(sources.count, sources.count)
        return out
    }

    private static func short(_ e: Error) -> String {
        let m = e.localizedDescription
        return m.count > 90 ? String(m.prefix(90)) + "…" : m
    }
}
