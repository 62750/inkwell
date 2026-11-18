import SwiftUI

// MARK: - 发现页

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @State private var showSearch = false
    @State private var keyword = ""
    @State private var selectedSource: BookSource?
    @State private var exploreBooks: [Book] = []
    @State private var loading = false

    private let hotWords = ["玄幻", "都市", "悬疑", "科幻", "言情", "历史",
                            "无限流", "修仙", "系统", "群像"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchBar

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

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("书源").font(.headline)
                            Spacer()
                            Text("\(app.enabledSources.count) 个可用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(app.enabledSources.prefix(20)) { s in
                            Button {
                                selectedSource = s
                                explore(s)
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
                .padding(16)
            }
            .navigationTitle("发现")
            .sheet(isPresented: $showSearch) {
                SearchView(initialKeyword: keyword).environmentObject(app)
            }
            .sheet(item: $selectedSource) { source in
                SourceBrowseView(source: source).environmentObject(app)
            }
            .overlay {
                if loading {
                    ProgressView().padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

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

    private func explore(_ source: BookSource) {
        guard source.enabledExplore else { return }
        loading = true
        Task.detached {
            defer { Task { await MainActor.run { loading = false } } }
            _ = try? await SourceEngine.shared.explore(source: source, url: "")
            await MainActor.run { loading = false }
        }
    }
}

// MARK: - 单源浏览

struct SourceBrowseView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let source: BookSource

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
                    Button { detail = b } label: { ResultRow(book: b) }
                        .buttonStyle(.plain)
                }
            }
            .overlay {
                if loading { ProgressView() }
            }
            .navigationTitle(source.displayName)
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
        do {
            books = try await SourceEngine.shared.explore(source: source, url: source.bookSourceUrl)
            if books.isEmpty {
                error = "该源没有发现规则，或 exploreUrl 为空。请用搜索，或在书源编辑里填 exploreUrl。"
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
        var rows: CGFloat = 1
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += rowHeight + spacing
                rows += 1
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
