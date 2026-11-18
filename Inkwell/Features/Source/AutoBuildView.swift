import UIKit
import SwiftUI

// MARK: - 一键建源
//
// 给一个域名，自动探测出：搜索表单 → 列表选择器 → 字段规则 → 目录 → 正文。
// 探测结果可以当场试搜，满意就保存。

struct AutoBuildView: View {
    @EnvironmentObject var app: AppState

    @State private var site = ""
    @State private var keyword = "斗破苍穹"
    @State private var isComic = false
    @State private var running = false
    @State private var result: AutoBuildResult?
    @State private var logs: [String] = []
    @State private var testBooks: [Book] = []
    @State private var testing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inputCard
                if !logs.isEmpty { logCard }
                if let result { resultCard(result) }
                if !testBooks.isEmpty { testCard }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: 输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("站点地址").font(.subheadline.weight(.medium))
            TextField("例如 www.example.com 或 https://example.com", text: $site)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            HStack {
                Text("探测关键词").font(.caption).foregroundStyle(.secondary)
                TextField("斗破苍穹", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            Toggle("这是漫画站", isOn: $isComic).font(.caption)

            Button {
                start()
            } label: {
                HStack {
                    if running { ProgressView().tint(.white).scaleEffect(0.8) }
                    Text(running ? "正在探测…" : "开始探测")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running || site.trimmingCharacters(in: .whitespaces).isEmpty)

            Text("会依次尝试：抓首页 → 找搜索表单 → 试几条常见搜索路径 → 分析列表结构。整个过程 3~10 秒。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 日志

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("探测过程").font(.subheadline.weight(.medium))
            ForEach(logs, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 结果

    private func resultCard(_ r: AutoBuildResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("生成的规则").font(.subheadline.weight(.medium))
                Spacer()
                Text(r.success ? "可用" : "待校准")
                    .font(.caption2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((r.success ? Color.green : Color.orange).opacity(0.16),
                                in: Capsule())
                    .foregroundStyle(r.success ? .green : .orange)
            }

            ruleRow("搜索地址", r.source.searchUrl)
            ruleRow("列表", r.source.ruleSearch.bookList)
            ruleRow("书名", r.source.ruleSearch.name)
            ruleRow("作者", r.source.ruleSearch.author)
            ruleRow("详情链接", r.source.ruleSearch.bookUrl)
            ruleRow("封面", r.source.ruleSearch.coverUrl)
            ruleRow("目录", r.source.ruleToc.chapterList)
            ruleRow("正文", r.source.ruleContent.content)

            if !r.source.ruleSearch.bookList.hasPrefix("@auto") {
                Text("置信度 \(Int(r.confidence * 100))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    test(r.source)
                } label: {
                    HStack {
                        if testing { ProgressView().scaleEffect(0.7) }
                        Text("试搜")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(testing)

                Button("保存为书源") {
                    var s = r.source
                    if isComic { s.bookSourceType = SourceType.image.rawValue }
                    app.saveSource(s)
                    app.showToast("已保存：\(s.displayName)")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func ruleRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.tertiary)
            Text(value.isEmpty ? "（空）" : value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .lineLimit(2)
        }
    }

    // MARK: 试搜结果

    private var testCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("试搜结果（\(testBooks.count)）").font(.subheadline.weight(.medium))
            ForEach(testBooks.prefix(6)) { b in
                HStack(spacing: 8) {
                    Text(b.name).font(.caption).lineLimit(1)
                    Spacer()
                    Text(b.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if testBooks.isEmpty {
                Text("没搜到东西，说明规则还需要调整。可以回源详情页点「校准」，或手动改规则。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 动作

    private func start() {
        running = true
        logs = []
        result = nil
        testBooks = []
        let siteURL = site
        let key = keyword
        let comic = isComic

        Task.detached {
            var built = await SourceAutoBuilder.build(siteURL: siteURL, probeKeyword: key)
            if comic {
                built.source.bookSourceType = SourceType.image.rawValue
                SourceAutoBuilder.applyAutoFallback(&built.source)
            }
            let final = built
            await MainActor.run {
                logs = final.log
                result = final
                running = false
            }
        }
    }

    private func test(_ source: BookSource) {
        testing = true
        let key = keyword
        Task.detached {
            do {
                var s = source
                SourceAutoBuilder.applyAutoFallback(&s)
                let books = try await SourceEngine.shared.search(source: s, key: key)
                await MainActor.run {
                    testBooks = books
                    testing = false
                    if books.isEmpty { logs.append("试搜返回 0 条") }
                }
            } catch {
                await MainActor.run {
                    logs.append("试搜失败：\(error.localizedDescription)")
                    testing = false
                }
            }
        }
    }
}
