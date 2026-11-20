import SwiftUI

// MARK: - 发现页

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @State private var showSearch = false
    @State private var keyword = ""
    @State private var browseTarget: BrowseTarget?

    private let hotWords = ["玄幻", "都市", "悬疑", "科幻", "言情", "历史",
                            "无限流", "修仙", "系统", "群像"]

    struct BrowseTarget: Identifiable {
        let id = UUID()
        let source: BookSource
        let url: String
        let title: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchBar
                    hotWordsSection
                    exploreSection
                    sourceSection
                }
                .padding(16)
            }
            .navigationTitle("发现")
            .sheet(isPresented: $showSearch) {
                SearchView(initialKeyword: keyword).environmentObject(app)
            }
            .sheet(item: $browseTarget) { target in
                SourceBrowseView(source: target.source,
                                 initialURL: target.url,
                                 title: target.title)
                    .environmentObject(app)
            }
        }
    }

    // MARK: 搜索

    private var searchBar: some View {
        Button {
            showSearch = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("搜索书名 / 作者，全源并发").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: 热门搜索

    private var hotWordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("热门搜索").font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(hotWords, id: \.self) { w in
                    Button {
                        keyword = w
                        showSearch = true
                    } label: {
                        Text(w)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 排行榜 / 分类

    @ViewBuilder
    private var exploreSection: some View {
        let sources = app.enabledSources.filter {
            $0.enabledExplore && !$0.exploreCategories.isEmpty
        }
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("排行榜 & 分类").font(.headline)
                ForEach(sources) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(s.exploreCategories) { cat in
                                Button {
                                    browseTarget = BrowseTarget(
                                        source: s, url: cat.url,
                                        title: "\(s.displayName) · \(cat.name)")
                                } label: {
                                    Text(cat.name)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.10), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 书源

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("书源").font(.headline)
                Spacer()
                Text("\(app.enabledSources.count) 个可用")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(app.enabledSources.prefix(20)) { s in
                Button {
                    browseTarget = BrowseTarget(source: s, url: s.bookSourceUrl,
                                                title: s.displayName)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.isComic ? "photo.on.rectangle" : "book")
                            .frame(width: 22)
                            .foregroundStyle(s.isComic ? .orange : .accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.displayName).font(.subheadline)
                            Text(s.host).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            if app.enabledSources.isEmpty {
                Text("还没有启用的书源，去「书源」页导入或新建")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 单源浏览（排行榜 / 分类 / 首页）

struct SourceBrowseView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    var initialURL: String = ""
    var title: String = ""

    @State private var books: [Book] = []
    @State private var loading = false
    @State private var error: String?
    @State private var detail: Book?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                ForEach(books) { b in
                    Button {
                        detail = b
                    } label: {
                        ResultRow(book: b)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if loading { ProgressView() }
            }
            .navigationTitle(title.isEmpty ? source.displayName : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $detail) { b in
                BookDetailView(book: b).environmentObject(app)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let url = initialURL.isEmpty ? source.bookSourceUrl : initialURL
        do {
            books = try await SourceEngine.shared.explore(source: source, url: url)
            if books.isEmpty {
                error = "该页面没有解析出内容。这个入口的规则可能需要调整，可先在「书源体检」里看目录/搜索是否正常。"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 简易流式布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
