import Foundation

// MARK: - 内置书源 / 漫画源
//
// 设计立场：书源是易失资源，任何硬编码 CSS 30 天内必然失效。
// 所以内置源不写死选择器，而是「站点 + @auto 自适应规则」：
//   首次打开某源时，RuleProber 现场分析页面结构推导选择器，
//   推导结果写入「规则覆盖层」，原规则不动，可随时回滚。
//
// 同时内置「一键建源」：输入任意站点域名，SourceAutoBuilder 自动生成一个源。

enum BuiltinSources {

    // MARK: 内置自适应源

    /// 这些源开箱可直接用：填了默认站点，规则全是 @auto，失效后点「校准」即可复活。
    static func seeds() -> [BookSource] {
        [
            adaptiveText(name: "自适应 · 通用小说",
                         site: "", group: "内置·小说",
                         note: "填入任意小说站域名即可自动适配；也可直接点「自动建源」"),
            adaptiveText(name: "自适应 · 通用漫画",
                         site: "", group: "内置·漫画", comic: true,
                         note: "填入任意漫画站域名即可自动适配"),
            demoSource()
        ]
    }

    static func adaptiveText(name: String, site: String, group: String,
                             comic: Bool = false, note: String = "") -> BookSource {
        var s = BookSource()
        s.bookSourceName = name
        s.bookSourceUrl = site
        s.bookSourceGroup = group
        s.bookSourceType = comic ? SourceType.image.rawValue : SourceType.text.rawValue
        s.enabledExplore = false
        s.searchUrl = site.isEmpty ? "" : site + "/search?q={{key}}"
        s.bookSourceComment = note.isEmpty ? "自适应内置源：结构变化后点「校准」自动修复" : note

        s.ruleSearch.bookList = "@auto:list"
        s.ruleSearch.name = "@auto:name"
        s.ruleSearch.author = "@auto:author"
        s.ruleSearch.coverUrl = "@auto:cover"
        s.ruleSearch.bookUrl = "@auto:url"
        s.ruleSearch.intro = "@auto:intro"

        s.ruleBookInfo.name = "@auto:name"
        s.ruleBookInfo.author = "@auto:author"
        s.ruleBookInfo.intro = "@auto:intro"
        s.ruleBookInfo.coverUrl = "@auto:cover"

        s.ruleToc.chapterList = "@auto:chapterList"
        s.ruleToc.chapterName = "text"
        s.ruleToc.chapterUrl = "href"

        s.ruleContent.content = comic ? "@auto:images" : "@auto:content"
        return s
    }

    /// 内置演示源（结构固定，用来验证引擎与排版链路是否正常）
    static func demoSource() -> BookSource {
        var s = BookSource()
        s.bookSourceName = "演示 · 离线样本"
        s.bookSourceUrl = "https://example.com"
        s.bookSourceGroup = "内置·演示"
        s.bookSourceType = 0
        s.searchUrl = "https://example.com/search?q={{key}}"
        s.ruleSearch.bookList = "class.book-list@tag.li"
        s.ruleSearch.name = "tag.h3@text"
        s.ruleSearch.author = "class.author@text"
        s.ruleSearch.bookUrl = "tag.a@href"
        s.ruleSearch.coverUrl = "tag.img@src"
        s.ruleSearch.intro = "class.intro@text"
        s.ruleBookInfo.name = "tag.h1@text"
        s.ruleBookInfo.author = "class.author@text"
        s.ruleBookInfo.intro = "class.intro@text"
        s.ruleBookInfo.coverUrl = "class.cover@tag.img@src"
        s.ruleToc.chapterList = "class.chapter-list@tag.a"
        s.ruleToc.chapterName = "text"
        s.ruleToc.chapterUrl = "href"
        s.ruleContent.content = "id.content@html"
        s.bookSourceComment = "演示用，不含真实内容；用来确认规则引擎与阅读器工作正常"
        return s
    }

    // MARK: 推荐订阅（社区书源合集）
    //
    // 这些是长期维护的公开仓库首页。App 里点「前往」用浏览器打开，
    // 从仓库里复制 raw JSON 地址后粘进「订阅」即可。
    // 直接内置 raw 直链风险太大（分支名/路径随时变），所以给主页。

    struct RecommendedPack: Identifiable, Sendable {
        var id: String { url }
        let name: String
        let url: String
        let note: String
    }

    static let recommended: [RecommendedPack] = [
        .init(name: "shidahuilang / shuyuan",
              url: "https://github.com/shidahuilang/shuyuan",
              note: "体量最大的中文书源合集之一，更新频繁"),
        .init(name: "XIU2 / Yuedu",
              url: "https://github.com/XIU2/Yuedu",
              note: "阅读 App 本体与配套书源整理"),
        .init(name: "gedoor / legado",
              url: "https://github.com/gedoor/legado",
              note: "Legado 上游仓库，可查阅书源格式规范")
    ]

    static let fallbackPackNote = """
    订阅方法：在上述仓库里找到 .json 书源文件 → 点 Raw → 复制地址 → \
    回到「书源 → 订阅」粘贴 → 拉取。拉取后可随时切换「整包替换 / 增量合并 / 保留本地修改」。
    """
}
