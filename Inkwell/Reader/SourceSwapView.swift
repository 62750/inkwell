import SwiftUI

// MARK: - 换书源
//
// 当前源失效 / 章节缺失时，拿书名去其它已启用源里搜同样的书，
// 选中后保留书籍条目和阅读进度比例，只换数据来源。

struct SourceSwapView: View {
    @ObservedObject var vm: ReaderViewModel
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var results: [Book] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("当前源")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(vm.book.sourceName)
                            .font(.caption)
                    }
                    HStack {
                        Text("书名")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(vm.book.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    if !vm.chapters.isEmpty {
                        HStack {
                            Text("当前进度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("第 \(vm.chapterIndex + 1)/\(vm.chapters.count) 章")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("正在阅读")
                } footer: {
                    Text("换源后自动按相同比例定位到对应章节。")
                        .font(.caption2)
                }

                if loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在其它书源里搜索同名书…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else if results.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("没有找到其它来源").font(.subheadline)
                            Text(message ?? "其它已启用的书源里没有搜到这本书。可以先去「书源」页导入更多源，再回来换。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        Button {
                            Task { await load() }
                        } label: {
                            Label("重新搜索", systemImage: "arrow.clockwise")
                        }
                    }
                } else {
                    Section("找到 \(results.count) 个来源") {
                        ForEach(results) { b in
                            Button {
                                vm.switchSource(to: b)
                                dismiss()
                            } label: {
                                ResultRow(book: b)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("换书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        message = nil
        let found = await vm.findSameBookInOtherSources()
        await MainActor.run {
            // 按书名完全匹配优先、章节数多的优先
            results = found.sorted { a, b in
                let an = a.name == vm.book.name
                let bn = b.name == vm.book.name
                if an != bn { return an }
                return a.lastChapter > b.lastChapter
            }
            loading = false
            if found.isEmpty {
                let enabled = app.enabledSources.filter { $0.id != vm.book.sourceId }
                message = "已尝试 \(enabled.count) 个其它源：\(enabled.map { $0.displayName }.joined(separator: "、"))"
            }
        }
    }
}
