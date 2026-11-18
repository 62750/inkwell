# 墨阅 Inkwell

iOS 上的自用阅读器：**自定义书源 / 漫画源**、**全格式本地电子书**、**自动分章**、**自动排版**、**条漫 + 页漫双阅读器**。

书源规则格式与「阅读 3.0 / Legado」**JSON 完全兼容** —— 现成的书源包、漫画源包可以直接导入用，不用重写。

---

## 一、为什么必须自签

书源类 App 拿不到 App Store 上架资格（会被认定为「未经授权抓取第三方内容」）。所以分发路线只有一条：

```
源码 → GitHub Actions 出未签名 IPA → 自签工具签名装进手机
```

iPhone 17 Pro Max / iOS 27.2.1 属于新系统，装之前先看第 5 节的三条路线，选能用的那条。

---

## 二、功能矩阵

| 能力 | 状态 | 说明 |
|---|---|---|
| 书源导入（Legado JSON） | ✅ | 数组 / 单对象 / `{data:[...]}` 三种包装都能吃 |
| 规则引擎 XPath | ✅ | 自研子集：`//`、`@attr`、`text()`、谓词、`contains()`、`|` 联合 |
| 规则引擎 CSS / jsoup | ✅ | `class.xxx`、`tag.li`、`id.xxx`、`selector@extract` 链式 |
| 规则引擎 JSONPath | ✅ | `$.data.list[*].name`、`..` 递归、`[?(...)]` 等值过滤 |
| 规则引擎正则链 | ✅ | `##pattern##replacement`、`##pattern##`、捕获组 `$1` |
| 规则引擎 JS | ✅ | JavaScriptCore + `java.ajax`/`org.jsoup.Jsoup.parse` 兼容层 |
| 多源并发搜索 | ✅ | 全源并行，令牌桶限速，单源失败不影响其他 |
| 书源调试台 | ✅ | 搜索→详情→目录→正文 四段逐级验证 + 实时日志 |
| 本地 TXT | ✅ | 编码三级探测（BOM/meta/GB18030/Big5）+ 7 套分章正则打分 |
| 本地 EPUB 2/3 | ✅ | nav.xhtml / toc.ncx 双目录解析，段落结构保留 |
| 本地 PDF | ✅ | 文本型抽字分章；扫描件自动识别为逐页图片阅读 |
| 本地 MOBI/AZW/AZW3 | ✅（无 DRM） | PalmDOC LZ77 解压；HUFF/CDIC 与加密文件会明确报错 |
| 本地 FB2 / HTML / Markdown | ✅ | XML 结构 / 网页正文提取 / `#` 标题切章 |
| 本地 CBZ | ✅ | ZIP 图片包，按目录/文件名分组为「话」 |
| 本地 CBR | ⚠️ | RAR 无系统解码器，建议转 CBZ |
| 排版：分页 | ✅ | NSLayoutManager 实测分页，字符锚点跨字号不丢位置 |
| 排版：中文避头尾 | ✅ | 行首禁则 + WORD JOINER 绑定 |
| 排版：首行缩进/行距/字距/两端对齐 | ✅ | 全部可调 |
| 漫画：条漫纵向 | ✅ | LazyVStack 无限流 |
| 漫画：页漫/双页/日漫右开 | ✅ | 分页 + 双指缩放 |
| 进度同步 | ✅ | 章内字符偏移，换设备/换字号都准 |
| 书签 / 标注 | ✅ | 数据库已建表，UI 已接书签 |
| 网页登录抓 Cookie | ✅ | WKWebView 登录 → cookie 同步到 URLSession |

---

## 三、架构

```
┌──────────────────── SwiftUI ────────────────────┐
│ 书架  发现  书源  我的  │ 阅读器(文本/漫画)        │
└──────────────┬──────────────────────────────────┘
               │
     ┌─────────▼──────────┐   ┌──────────────────┐
     │  ReaderViewModel   │   │  SourceEngine    │
     │  分页/翻页/进度      │   │  搜索/详情/目录/正文│
     └─────────┬──────────┘   └────────┬─────────┘
               │                       │
     ┌─────────▼──────────┐   ┌────────▼─────────┐
     │   Paginator        │   │  RuleEvaluator   │
     │  NSLayoutManager   │   │  || && %% ## 管线 │
     └────────────────────┘   └────────┬─────────┘
                                       │
          ┌────────────┬───────────────┼─────────────┬────────────┐
          ▼            ▼               ▼             ▼            ▼
      XPath引擎    SelectorBridge  JSONPathLite  RegexChain   JSEngine
      (自研)       (SwiftSoup)     (自研)        (自研)       (JSC+shim)
                                       │
                              ┌────────▼────────┐
                              │   HTTPClient    │
                              │ Cookie/限速/编码 │
                              └─────────────────┘
```

**关键设计取舍**

- iOS 上没有 `NSXMLDocument`，SwiftSoup 只有 CSS。XPath 是自研的，覆盖 Legado 书源里 80% 的实际写法（详见 `Core/Rule/XPath.swift` 顶部注释）。
- Legado 的规则语法不是纯 XPath，而是 `选择器@取值` 的多段链。所以在 `RuleEvaluator` 里先做**语法分流**（`@js:` / `@json:` / `@xpath:` / `//` / `$.` / jsoup），再进各自的引擎。
- 分页用「字符区间」而不是「页索引」做锚点。这样换字号、转屏、换设备，位置都不会飘。

---

## 四、目录结构

```
Inkwell/
├── project.yml                       # XcodeGen 工程定义
├── .github/workflows/build-ipa.yml   # 云端出 IPA
└── Inkwell/
    ├── Info.plist                    # ATS 全放开 + 文档类型注册
    ├── App/
    │   ├── InkwellApp.swift          # 入口 / TabShell
    │   └── AppState.swift            # 全局状态 + 图片缓存
    ├── Core/
    │   ├── Models/                   # BookSource(宽松解码) / Book / Chapter
    │   ├── Util/                     # 编码探测 / 字符工具 / 摘要 / 日志
    │   ├── Network/HTTPClient.swift   # 请求 / Cookie / 限速 / 重试
    │   ├── Rule/
    │   │   ├── XPath.swift           # 自研 XPath 求值器
    │   │   ├── SelectorBridge.swift  # class./tag./id. → CSS
    │   │   ├── JSONPathLite.swift
    │   │   ├── RegexChain.swift
    │   │   ├── JSRuntime.swift       # JSC + java/jsoup 兼容层
    │   │   └── RuleEvaluator.swift   # 规则主调度
    │   ├── Source/SourceEngine.swift # 书源执行
    │   ├── Parsers/                  # TXT/EPUB/PDF/MOBI/FB2/CBZ/HTML/MD
    │   └── Store/                    # GRDB 建表 + 仓库
    ├── Reader/
    │   ├── ReadingSettings.swift
    │   ├── Paginator.swift           # 分页 + 避头尾
    │   ├── ReaderViewModel.swift
    │   ├── TextReaderView.swift
    │   ├── ComicReaderView.swift
    │   └── ReaderPanels.swift        # 菜单/目录/设置
    └── Features/
        ├── Bookshelf/  Discover/  Search/  Source/  Settings/
```

---

## 五、构建

### 路线 A：有 Mac（最省事）

```bash
brew install xcodegen
cd Inkwell
xcodegen generate
open Inkwell.xcodeproj
```

Xcode 里：

1. Target `Inkwell` → Signing & Capabilities → Team 选你的 Apple ID
2. Bundle Identifier 改成**全局唯一**（`com.你的名字.inkwell`），免费账号同一个 ID 7 天内只能签 3 个 App
3. 连上 iPhone 17 Pro Max → 选真机 → Run

iOS 27 首次运行会提示「不受信任的开发者」：
**设置 → 通用 → VPN与设备管理 → 开发者App → 信任**

### 路线 B：没有 Mac（GitHub Actions 出 IPA）

1. 把整个 `Inkwell/` 推到你自己的 GitHub 仓库
2. Actions 会自动跑 `.github/workflows/build-ipa.yml`
3. 跑完在 Artifacts 下载 `Inkwell-ipa`（里面是未签名 IPA）
4. 用第 5.3 节的工具自签装机

> workflow 默认用 `macos-15` + 自动挑选可用 Xcode。如果 Xcode 27 SDK 尚未在 runner 上，把 `deploymentTarget` 与 Xcode 版本对齐即可，代码本身不依赖新 SDK。

### 路线 C：Xcode Cloud / 自建 Mac runner

同 A，只是把归档交给 CI。

---

## 六、装进 iPhone 17 Pro Max（iOS 27.2.1）

### 6.1 免费 Apple ID 自签（0 成本）

| 工具 | 特点 |
|---|---|
| **SideStore** | 手机上直接续签，需要一台常开的电脑或 WireGuard 中继 |
| **AltStore Classic** | 经典方案，电脑端 AltServer 每 7 天刷新一次 |
| **Sideloadly** | Windows 也能用，插线签一次，7 天有效 |

限制：**7 天到期**、最多 3 个 App、无推送、无 iCloud。

### 6.2 付费开发者账号（$99/年）

证书 1 年有效，可装 100 台设备。适合你只给自己用、又不想每 7 天折腾的情况。

### 6.3 自签命令（拿到未签名 IPA 后）

```bash
# macOS
unzip -o Inkwell-unsigned.ipa -d out
codesign -f -s "Apple Development: you@example.com (TEAMID)" \
  --entitlements entitlements.plist \
  out/Payload/Inkwell.app
zip -qr Inkwell-signed.ipa out/Payload
```

`entitlements.plist` 至少要有：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>TEAMID.com.你的名字.inkwell</string>
    <key>com.apple.developer.team-identifier</key>
    <string>TEAMID</string>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
```

Windows 上用 **Sideloadly** 最省事：拖入 IPA → 填 Apple ID → Start。

### 6.4 首次启动要给的权限

- 网络：无提示（HTTP 明文已在 `Info.plist` 放开 ATS）
- 相册写入：保存漫画图（可选）
- 本地网络：局域网导入书源（可选）

---

## 七、书源规则速查

### 7.1 书源 JSON 骨架（Legado 兼容）

```json
{
  "bookSourceName": "示例站",
  "bookSourceUrl": "https://example.com",
  "bookSourceType": 0,
  "bookSourceGroup": "自建",
  "enabled": true,
  "searchUrl": "https://example.com/search?q={{key}}&page={{page}}",
  "header": "{\"User-Agent\":\"Mozilla/5.0\",\"Referer\":\"https://example.com\"}",
  "ruleSearch": {
    "bookList": "class.book-list@tag.li",
    "name": "tag.h3@text",
    "author": "class.author@text",
    "bookUrl": "tag.a@href",
    "coverUrl": "tag.img@src",
    "intro": "class.intro@text",
    "lastChapter": "class.last@text"
  },
  "ruleBookInfo": {
    "name": "tag.h1@text",
    "author": "class.author@text",
    "intro": "class.intro@text",
    "coverUrl": "class.cover@tag.img@src",
    "tocUrl": ""
  },
  "ruleToc": {
    "chapterList": "class.chapter-list@tag.a",
    "chapterName": "text",
    "chapterUrl": "href"
  },
  "ruleContent": {
    "content": "id.content@html"
  }
}
```

`bookSourceType`：`0` 小说、`1` 有声、`2` 漫画、`3` 文件下载。

### 7.2 `searchUrl` 三种写法

```
# 1. 纯 GET
https://a.com/search?q={{key}}&page={{page}}

# 2. POST + 自定义头（尾部接 ,{...}）
https://a.com/search,{\"method\":\"POST\",\"body\":\"kw={{key}}&p={{page}}\",
  \"charset\":\"gbk\",\"headers\":{\"X-Requested-With\":\"XMLHttpRequest\"}}

# 3. 全动态
@js: java.ajax(baseUrl + "/api/search?kw=" + encodeURIComponent(key))
```

`{{key}}` 在 URL 里自动百分号编码，在 body 里保持原文。

### 7.3 规则语法（重要）

一条规则从右往左拆，顺序固定：

```
规则 && 规则        → 结果拼接（合并多字段）
规则 || 规则        → 取第一个非空
规则 %% 排除规则     → 结果里剔除
规则 ## 正则 ## 替换  → 正则链
```

引擎分流：

| 写法 | 引擎 | 例 |
|---|---|---|
| `//` `/` `(` 开头 | XPath | `//div[@class="list"]/li` |
| `@xpath:` | XPath | `@xpath://a[contains(@href,"/book/")]` |
| `@css:` | CSS | `@css:div.list > li` |
| `class.` `tag.` `id.` | jsoup 链 | `class.cover@tag.img@src` |
| `$.` `$[` | JSONPath | `$.data.list[*].title` |
| `@json:` | JSONPath | `@json:$.chapters[*].name` |
| `@js:` `<js>…</js>` | JavaScriptCore | `@js: result.match(/id=(\\d+)/)[1]` |

取值后缀：`@text`、`@ownText`、`@html`、`@textNodes`、`@outerHtml`、`@任意属性名`。

### 7.4 XPath 支持范围

```
轴：      /  //  .  ..  @attr  text()  node()
谓词：    [1] [last()] [last()-1] [position()>2]
          [@class] [@class="x"] [@class!="x"]
          [contains(@href,"/book/")] [starts-with(...)] [ends-with(...)]
          [text()="x"] [contains(text(),"x")] [not(...)] [matches(...,"re")]
          [string-length(text())>10] [div] [.//a]
联合：    A | B
```

### 7.5 JS 兼容层能跑什么

```js
// 网络
java.ajax(url)                    // 同步 GET，返回字符串
java.post(url, body, headers)
java.connect(url).body()
java.getCookie(url)

// 工具
java.base64Encode(s) / java.base64Decode(s)
java.md5Encode(s) / java.md5Encode16(s)
java.hexEncodeToString(s)
java.timeFormat(ts)

// 共享变量
java.put("k", v) / java.get("k")

// DOM
var doc = org.jsoup.Jsoup.parse(result)
doc.select("div.list > a").eachAttr("href")
```

内置数据：`result`（当前 HTML/文本）、`baseUrl`、`key`、`page`、`source`（书源对象）、`book`。

### 7.6 漫画源

`bookSourceType` 设 `2`，正文规则返回**图片地址列表**：

```json
"ruleContent": {
  "content": "//div[@id='images']//img/@src",
  "nextContentUrl": ""
}
```

也支持直接返回 `<img>` 标签，引擎会自己抽 `data-src` / `data-original` / `src`。
没配规则时也有兜底：抓页面里所有 `img`，过滤掉 1x1 占位图。

---

## 八、使用流程

```
① 「书源」页 → + → 从文件/网址/剪贴板导入 Legado 书源包
② 点进一个源 → 调试台 → 关键词测试
   搜索 ✅ → 点书 → 详情 ✅ → 目录 ✅ → 点章 → 正文 ✅
   哪一步 ❌ 就改对应字段，四步全绿这个源就能用
③ 「发现」页 → 搜索 → 加入书架
④ 书架点开阅读；长按可刷新目录/移除
⑤ 本地书：书架右上角 + → 选文件（可多选）
```

调试台的意义：书源失效九成是「网站改版 → CSS class 变了」，在调试台改一个字段立刻能看到结果，不用整份重写。

---

## 八点五、内置源

内置了 **4 个实测可用的源**（截至 2026-11 逐段抓取验证：搜索 → 列表 → 详情 → 目录 → 正文）：

| 源 | 模板 | 搜索 | 正文容器 |
|---|---|---|---|
| 笔趣阁 · fsshu | 笔趣阁 v5 | `GET /search.php?q=` | `article` |
| 笔趣阁 · biquguo | 笔趣阁 v5 | `GET /search.php?q=` | `article` |
| 笔趣阁 · biquge7 | 新笔趣阁 | `GET /search?keyword=` | `.text` |
| 全本同人 · qbtr | 帝国CMS | `POST /e/search/index.php` + GBK | `.read_chapterDetail` |

另外还有一个「自定义站点（填域名）」模板，规则全是 `@auto:*`，配合「自动校准规则」和「一键建源」可以接任意站。

**为什么不再硬编码 CSS**：书源是易失资源，站点改版后写死的选择器 30 天内必然失效。所以四个内置源都只是「起点」，真正的长期方案是配订阅，让书源包自己更新。

### 自适应兜底

```
自定义站点 + @auto 规则
   → 首次打开时 RuleProber 现场分析 DOM
   → 结构聚类（重复同构块）+ 文本密度（Readability 思路）
   → 推导选择器 → 写入「规则覆盖层」，原始 JSON 不动
```

**校准**：源详情页 →「自动校准规则」→ 重新探测 → 差异写进覆盖层 →「还原本源」一键回滚。

### 一键建源

```
输入 www.example.com
  ↓ 抓首页 → 找 <form> 搜索 input（q/kw/keyword/wd/searchkey）
  ↓ 找不到就试 8 条常见搜索路径
  ↓ 抓搜索结果页 → 结构探测 → 产出 bookList/name/author/cover/bookUrl
  ↓ 当场「试搜」验证 → 保存
```


书源是**易失资源**。任何一个硬编码 CSS 的源，在站点改版后 30 天内必然失效 —— 这也是社区书源包需要几个月一更新的原因。

所以内置源的设计换了思路：

```
站点地址 + @auto 规则
   ↓ 首次打开
RuleProber 现场分析 DOM：
   1. 结构聚类 —— 找出页面里「同构重复块」最多的容器
   2. 文本密度 —— 找正文容器（Readability 思路）
   ↓ 推导出选择器
写入「规则覆盖层」，原始书源 JSON 一个字都不改
```

**三种内置源**

| 名称 | 组 | 说明 |
|---|---|---|
| 自适应 · 通用小说 | 内置·小说 | `@auto:*` 全自动，填入任意小说站域名即可 |
| 自适应 · 通用漫画 | 内置·漫画 | `@auto:images` 自动找图集容器 |
| 演示 · 离线样本 | 内置·演示 | 固定规则，用来验证引擎/排版链路是否正常 |

**校准机制**：源详情页 →「自动校准规则」→ 重新探测并把差异写进覆盖层 → 点「还原本源」一键回滚。原规则与覆盖层分开存，导出的 JSON 永远是源头那份。

### 一键建源（细节）

「书源 → ＋ → 源商店 → 一键建源」或「内置源 → 输入域名自动建源」：

```
输入 www.example.com
  ↓ 抓首页
  ↓ 找 <form> 里的搜索 input（q/kw/keyword/wd/searchkey…）
  ↓ 找不到就试 8 条常见搜索路径
  ↓ 抓搜索结果页
  ↓ 结构探测 → 产出 bookList / name / author / cover / bookUrl
  ↓ 当场「试搜」验证
保存
```

探测过程全程可见，失败也能保存（规则退化成 `@auto:`，运行时再现场推导）。

---

## 八点六、替换接口（三套独立机制）

| 机制 | 作用 | 位置 |
|---|---|---|
| **订阅 SourcePack** | 远程 JSON 整包拉取，三种合并策略 | `SourcePackManager` |
| **覆盖层 RuleOverlay** | 校准/手调结果独立存放，原规则不动 | `RuleOverlay` |
| **导出/导入** | 整包 JSON 分享、剪贴板、文件、URL | `SourcePackManager.export*` |

**三种合并策略**

| 策略 | 行为 | 适用 |
|---|---|---|
| 整包替换 | 以订阅为准，同源覆盖（保留本地 id，书架引用不断） | 订阅源是权威版本 |
| 增量合并 | 本地已有同名源就跳过 | 日常更新（**默认**） |
| 只补缺 | 绝不覆盖任何本地已有的源 | 自己改了很多规则 |

**书源身份判定**：`规范化URL + 名称 + 类型`。所以同一个站的 http/https 会被视为同一个源，改名后则视为新源。

---

## 八点七、启动速度

冷启动路径被重新拆过：

| 优化 | 改动前 | 改动后 |
|---|---|---|
| 数据库打开 | `App.init` 里同步开库 + 迁移 | 惰性打开，首次真正需要数据时才开，且在后台线程 |
| 数据加载 | `bootstrap()` 在主线程同步读全部书源 + 全部书 | 首帧之后 `RootView.task` 里分三段异步，读完一段刷一段 |
| 内置源写入 | 启动路径里写 DB | 只在「确实是首次启动」时后台写 |
| SQLite 参数 | 默认（rollback journal） | `WAL + synchronous=NORMAL + mmap 256MB + temp_store=MEMORY` |
| 索引 | 只有 chapter 复合索引 | 新增 `(enabled, orderIndex)`、`(lastReadAt)` |
| 书架首帧 | 数据没到就闪「书架空空如也」 | 骨架屏占位，数据到了直接替换 |
| 书架刷新 | 每次改动全量重读 | 局部替换（`toggleSource` 直接改数组元素） |

启动耗时可以从「我的 → 关于」下面的 `launch` 日志里看到：

```
[launch] sources 38.2ms
[launch] library 12.7ms
[launch] total   61.5ms
```

（Debug 构建下首次会慢一些，Release 会明显更快。）

---

## 八点八、IPA 交付

### 路线 1：有 Mac

```bash
./scripts/build_ipa.sh                 # 未签名 IPA → dist/
./scripts/build_ipa.sh --sign --team ABCD123456 \
    --identity "Apple Development: you@example.com (ABCD123456)"
```

产物：`dist/Inkwell-<version>-<时间戳>-unsigned.ipa`

### 路线 2：Windows / 没有 Mac（推荐）

```powershell
winget install --id GitHub.cli
gh auth login

pwsh ./scripts/build_ipa.ps1 -RepoOwner 你的用户名 -RepoName inkwell
```

脚本会：建仓库 → 推送 → 触发 Actions → 轮询构建 → 把 IPA 抓到 `dist/`。

### 拿到 IPA 后先验一下

```powershell
pwsh ./scripts/verify_ipa.ps1 -Ipa .\dist\Inkwell-xxxx-unsigned.ipa
```

检查项：`Payload/*.app`、`Info.plist`、arm64 Mach-O 头（`CF FA ED FE`）、`Assets.car`、Bundle ID、体积。

全部通过再丢给侧载工具，能省掉「装上了但打不开」的一大半情况。

### 侧载

| 平台 | 工具 | 期限 |
|---|---|---|
| Windows | **Sideloadly** | 7 天（免费账号） |
| macOS / iOS | **SideStore** | 7 天，可在手机上续签 |
| macOS | **AltStore Classic** | 7 天，电脑常开 AltServer |
| 任意 | 开发者证书 $99/年 | 1 年 |

---
## 九、已知限制

| 项 | 说明 | 处理 |
|---|---|---|
| CBR/RAR | iOS 无系统 RAR 解码器 | 用工具转 CBZ（`unrar x` + 重新 zip） |
| MOBI HUFF/CDIC | 压缩算法复杂，未实现 | 用 Calibre 转 EPUB |
| DRM 电子书 | 加密文件不支持 | 无解，这是设计边界 |
| Cloudflare 5秒盾 | 纯 URLSession 过不去 | 已留 `webJs` 钩子 + 网页登录抓 cookie；极端情况需要 WKWebView 代取 |
| 验证码登录 | 未做打码 | 网页登录后复用 cookie |
| 分页极限 | 单章 > 20 万字会明显卡 | 已按 4000 字兜底切段 |

---

## 十、想继续加东西改哪里

| 目标 | 文件 |
|---|---|
| 加书源规则语法（如 `@regex:` 前置、`@@` 链） | `Core/Rule/RuleEvaluator.swift` 的 `evalCore` |
| 加 XPath 谓词 | `Core/Rule/XPath.swift` 的 `XPredicate` + `nodeMatches` |
| 加电子书格式 | `Core/Parsers/` 新建 `XxxParser.swift`，在 `LocalBookImporter.load` 里加 case |
| 改排版算法 | `Reader/Paginator.swift` |
| 加阅读主题 | `Reader/ReadingSettings.swift` 的 `ReaderTheme` |
| 加双语/听书 | `Reader/` 新建 ViewModel，复用 `SourceEngine` |

---

## 十一、免责

自用工具。书源规则由使用者自行提供，程序只在本地执行规则、拉取公开页面；不内置任何内容源，不绕过付费墙，不分发受版权保护的文本。
