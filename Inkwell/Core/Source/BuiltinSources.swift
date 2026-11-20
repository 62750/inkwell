import Foundation

// MARK: - 内置书源
//
// 这些不是"模板"，是**实测可用**的源：搜索接口、列表结构、详情、目录、正文
// 都在 2026-11 用 iPhone UA 逐段抓取验证过。
//
// 站点会变，所以每个源都保留 @auto 兜底思路 + App 内「自动校准」入口。
// 想要更多源就走「源商店 → 订阅」，导入社区书源包。

enum BuiltinSources {

    static let mobileUA = HTTPClient.defaultUA

    // MARK: 内置清单

    static func seeds() -> [BookSource] {
        [
            biQuGeV5(name: "笔趣阁 · fsshu", site: "https://www.fsshu.com"),
            biQuGeV5(name: "笔趣阁 · biquguo", site: "https://www.biquguo.com"),
            biQuGe7(),
            tongRen(),
            comicSource(name: "漫画 · 包子镜像", site: "https://www.webmota.com",
                        searchPath: "/search?q={{key}}", note: "搜索可用；章节页为 JS 渲染，若目录为空请改用社区漫画源包"),
            comicSource(name: "漫画 · MacCMS", site: "https://www.yoyomanga.com",
                        searchPath: "/search?type=1&searchString={{key}}", note: "MacCMS 站点；搜索接口常被 Cloudflare 拦，作为发现入口"),
            customTemplate(),
            demoSource()
        ]
    }

    // MARK: 模板一：笔趣阁 v5（Bootstrap 栅格）
    //
    // 结构（实测）：
    //   搜索 /search.php?q=KEY&p=1
    //   列表 .col-12.col-md-6 > dl
    //        dt > a > img[src]             封面
    //        dd > h3 > a[href]             书名/详情
    //        dd.book_other > span          作者
    //        dd.book_other > a             最新章节
    //   详情 h1 / .img-thumbnail / #intro_pc
    //   目录 .book_list > li > a
    //   正文 article（class 随字号变，用标签选择器避开）

    static func biQuGeV5(name: String, site: String) -> BookSource {
        var s = BookSource()
        s.bookSourceName = name
        s.bookSourceUrl = site
        s.bookSourceGroup = "内置·小说"
        s.bookSourceType = SourceType.text.rawValue
        s.enabledExplore = true
        s.weight = 100
        s.header = headerJSON(referer: site + "/")
        s.searchUrl = "/search.php?q={{key}}&p={{page}}"
        s.exploreUrl = "热门::\(site)/top/\n玄幻::\(site)/list1/\n武侠::\(site)/list2/\n都市::\(site)/list3/\n历史::\(site)/list4/\n网游::\(site)/list5/\n科幻::\(site)/list6/\n言情::\(site)/list7/\n其他::\(site)/list8/"
        s.bookSourceComment = "笔趣阁v5模板，实测可用"

        // 排行榜 / 分类页与搜索页同结构，复用同一套规则
        s.ruleExplore.bookList = "class.col-md-6@tag.dl"
        s.ruleExplore.name = "tag.h3@tag.a@text"
        s.ruleExplore.bookUrl = "tag.h3@tag.a@href"
        s.ruleExplore.author = "class.book_other@tag.span@text"
        s.ruleExplore.coverUrl = "tag.dt@tag.img@src"

        s.ruleSearch.bookList = "class.col-md-6@tag.dl"
        s.ruleSearch.name = "tag.h3@tag.a@text"
        s.ruleSearch.bookUrl = "tag.h3@tag.a@href"
        s.ruleSearch.author = "class.book_other@tag.span@text"
        s.ruleSearch.coverUrl = "tag.dt@tag.img@src"
        s.ruleSearch.lastChapter = "class.book_other@tag.a@text"

        s.ruleBookInfo.name = "tag.h1@text"
        s.ruleBookInfo.author = "class.options@tag.li@tag.a@text"
        s.ruleBookInfo.coverUrl = "class.img-thumbnail@src"
        s.ruleBookInfo.intro = "id.intro_pc@text"
        s.ruleBookInfo.lastChapter = "class.options@tag.li@tag.a@text"

        s.ruleToc.chapterList = "class.book_list@tag.a"
        s.ruleToc.chapterName = "text"
        s.ruleToc.chapterUrl = "href"

        s.ruleContent.content = "tag.article@html"
        s.ruleContent.replaceRegex = "(本章未完|请记住本站|手机用户请|加入书签|投推荐票)[^\\n]*"
        return s
    }

    // MARK: 模板二：新笔趣阁 biquge7
    //
    // 结构（实测）：
    //   搜索 /search?keyword=KEY
    //   列表 .tui_1_item
    //        a[href] > img[src]
    //        .item_title > .title > a[href]    书名
    //        .item_title > .author             作者
    //        p                                 简介
    //   详情 /50045 : .list > ul > li > a
    //   正文 /50045/1 : .text

    static func biQuGe7() -> BookSource {
        var s = BookSource()
        s.bookSourceName = "笔趣阁 · biquge7"
        s.bookSourceUrl = "https://www.biquge7.xyz"
        s.bookSourceGroup = "内置·小说"
        s.bookSourceType = SourceType.text.rawValue
        s.enabledExplore = true
        s.weight = 90
        s.header = headerJSON(referer: "https://www.biquge7.xyz/")
        s.exploreUrl = "首页::https://www.biquge7.xyz/"
        s.ruleExplore.bookList = "@auto:list"
        s.ruleExplore.name = "@auto:name"
        s.ruleExplore.bookUrl = "@auto:url"
        s.ruleExplore.author = "@auto:author"
        s.ruleExplore.coverUrl = "@auto:cover"
        s.searchUrl = "/search?keyword={{key}}"
        s.bookSourceComment = "新笔趣阁模板，实测可用；章节地址无 .html 后缀"

        s.ruleSearch.bookList = "class.tui_1_item"
        s.ruleSearch.name = "class.title@tag.a@text"
        s.ruleSearch.bookUrl = "class.title@tag.a@href"
        s.ruleSearch.author = "class.author@text"
        s.ruleSearch.coverUrl = "tag.img@src"
        s.ruleSearch.intro = "tag.p@text"

        s.ruleBookInfo.name = "tag.h1@text"
        s.ruleBookInfo.intro = "tag.p.des@text"
        s.ruleBookInfo.coverUrl = "tag.img@src"

        s.ruleToc.chapterList = "class.list@tag.li@tag.a"
        s.ruleToc.chapterName = ""
        s.ruleToc.chapterUrl = "href"

        s.ruleContent.content = "class.text@html"
        return s
    }

    // MARK: 模板三：帝国CMS（qtr 系）
    //
    // 结构（实测）：
    //   搜索 POST /e/search/index.php   keyboard=KEY&show=title&classid=0   GBK
    //   列表 .bk
    //        h3 > a[href]        书名
    //        .booknews           作者 + 日期
    //        p                   简介
    //   详情 /tongren/10214.html : h1、.date、.book_info p
    //   目录 .book_list > a
    //   正文 .read_chapterDetail（混有书名作者，靠 replaceRegex 清）

    static func tongRen() -> BookSource {
        var s = BookSource()
        s.bookSourceName = "全本同人 · qbtr"
        s.bookSourceUrl = "https://www.qbtr.cc"
        s.bookSourceGroup = "内置·小说"
        s.bookSourceType = SourceType.text.rawValue
        s.enabledExplore = true
        s.weight = 80
        s.header = headerJSON(referer: "https://www.qbtr.cc/")
        s.exploreUrl = "热门::https://www.qbtr.cc/hot/\n同人::https://www.qbtr.cc/tongren/\n常规::https://www.qbtr.cc/changgui/"
        s.ruleExplore.bookList = "class.bk"
        s.ruleExplore.name = "tag.h3@tag.a@text"
        s.ruleExplore.bookUrl = "tag.h3@tag.a@href"
        s.searchUrl = "/e/search/index.php,{\"method\":\"POST\",\"body\":\"keyboard={{key}}&show=title&classid=0\",\"charset\":\"gbk\"}"
        s.bookSourceComment = "帝国CMS 模板；搜索走 POST + GBK 编码"

        s.ruleSearch.bookList = "class.bk"
        s.ruleSearch.name = "tag.h3@tag.a@text"
        s.ruleSearch.bookUrl = "tag.h3@tag.a@href"
        s.ruleSearch.author = "class.booknews@ownText##作者[：:]\\s*##"
        s.ruleSearch.intro = "tag.p@text"
        s.ruleSearch.updateTime = "class.date@text"

        s.ruleBookInfo.name = "tag.h1@text"
        s.ruleBookInfo.author = "class.date@tag.span@text##作者[：:]\\s*##"
        s.ruleBookInfo.intro = "class.book_info@tag.p@text"

        s.ruleToc.chapterList = "class.book_list@tag.a"
        s.ruleToc.chapterName = "text"
        s.ruleToc.chapterUrl = "href"

        s.ruleContent.content = "class.read_chapterDetail@html"
        return s
    }

    // MARK: 漫画源
    //
    // 漫画站普遍是客户端渲染 + Cloudflare，纯 HTML 能抓到的少。
    // 这里给的是「站点 + 自适应规则」：搜索/封面/标题走真实结构，
    // 章节与图片交给运行时 RuleProber 现场推导。

    static func comicSource(name: String, site: String, searchPath: String,
                            note: String = "") -> BookSource {
        var s = BookSource()
        s.bookSourceName = name
        s.bookSourceUrl = site
        s.bookSourceGroup = "内置·漫画"
        s.bookSourceType = SourceType.image.rawValue
        s.enabledExplore = false
        s.weight = 70
        s.header = headerJSON(referer: site + "/")
        s.searchUrl = searchPath
        s.bookSourceComment = note.isEmpty ? "自适应漫画源" : note

        s.ruleSearch.bookList = "@auto:list"
        s.ruleSearch.name = "@auto:name"
        s.ruleSearch.bookUrl = "@auto:url"
        s.ruleSearch.coverUrl = "@auto:cover"
        s.ruleSearch.author = "@auto:author"

        s.ruleBookInfo.name = "@auto:name"
        s.ruleBookInfo.coverUrl = "@auto:cover"
        s.ruleBookInfo.intro = "@auto:intro"

        s.ruleToc.chapterList = "@auto:chapterList"
        s.ruleToc.chapterName = "text"
        s.ruleToc.chapterUrl = "href"

        s.ruleContent.content = "@auto:images"
        return s
    }

    // MARK: 自定义站点模板（用户填域名）

    static func customTemplate() -> BookSource {
        var s = BookSource()
        s.bookSourceName = "自定义站点（填域名）"
        s.bookSourceUrl = ""
        s.bookSourceGroup = "内置·自定义"
        s.bookSourceType = SourceType.text.rawValue
        s.enabledExplore = false
        s.enabled = false
        s.searchUrl = ""
        s.bookSourceComment = "点开填入站点地址，再用「自动校准规则」或「一键建源」生成规则"

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

        s.ruleContent.content = "@auto:content"
        return s
    }

    /// 兼容旧调用
    static func adaptiveText(name: String, site: String, group: String,
                             comic: Bool = false, note: String = "") -> BookSource {
        var s = customTemplate()
        s.bookSourceName = name
        s.bookSourceUrl = site
        s.bookSourceGroup = group
        s.bookSourceType = comic ? SourceType.image.rawValue : SourceType.text.rawValue
        s.bookSourceComment = note
        return s
    }

    // MARK: 演示源（离线，验证引擎用）

    static func demoSource() -> BookSource {
        var s = BookSource()
        s.bookSourceName = "演示 · 离线样本"
        s.bookSourceUrl = "https://example.com"
        s.bookSourceGroup = "内置·演示"
        s.bookSourceType = 0
        s.enabled = false
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
        s.bookSourceComment = "演示用，不含真实内容；默认关闭"
        return s
    }

    // MARK: 工具

    static func headerJSON(referer: String) -> String {
        let dict: [String: String] = [
            "User-Agent": mobileUA,
            "Referer": referer,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: 推荐订阅

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
    回到「书源 → 订阅」粘贴 → 拉取。拉取后可随时切换「整包替换 / 增量合并 / 只保留本地」。
    """
}
