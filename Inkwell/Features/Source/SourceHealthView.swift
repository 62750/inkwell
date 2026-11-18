import SwiftUI
import UIKit

// MARK: - 书源体检页
//
// 五关全过 = 这个源真的能用。挂在哪一关，一眼就能看到。

struct SourceHealthView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var results: [HealthCheck] = []
    @State private var running = false
    @State private var current = 0
    @State private var total = 0
    @State private var keyword = "斗破"
    @State private var onlyEnabled = true

    private var targets: [BookSource] {
        onlyEnabled ? app.enabledSources : app.sources
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("测试关键词")
                        TextField("斗破", text: $keyword)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("只测已启用的源", isOn: $onlyEnabled)
                    Button {
                        runCheck()
                    } label: {
                        HStack {
                            if running {
                                ProgressView().scaleEffect(0.8)
                                Text("测试中 \(current)/\(total)…")
                            } else {
                                Image(systemName: "stethoscope")
                                Text("开始体检（\(targets.count) 个源）")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || targets.isEmpty)
                } footer: {
                    Text("每个源依次测试：配置 → 搜索 → 详情 → 目录 → 正文。全过程只读取公开页面，不改任何源。")
                        .font(.caption2)
                }

                if results.isEmpty && !running {
                    Section {
                        Text("还没有结果。点上面按钮开始。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                ForEach(results) { r in
                    Section {
                        stepRow("配置", r.config)
                        stepRow("搜索", r.search)
                        stepRow("详情", r.bookInfo)
                        stepRow("目录", r.toc)
                        stepRow("正文", r.content)
                        if !r.sampleBook.isEmpty {
                            HStack {
                                Text("样本").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(r.sampleBook).font(.caption).lineLimit(1)
                            }
                        }
                    } header: {
                        HStack {
                            Text(r.sourceName)
                            Spacer()
                            Text(r.summary)
                                .font(.caption2)
                                .foregroundStyle(r.allPassed ? .green
                                                 : (r.search.isPass ? .orange : .red))
                        }
                    }
                }

                if !results.isEmpty {
                    Section {
                        Button {
                            UIPasteboard.general.string = reportText()
                            app.showToast("报告已复制")
                        } label: {
                            Label("复制报告", systemImage: "doc.on.clipboard")
                        }
                        let bad = results.filter { !$0.search.isPass }.count
                        if bad > 0 {
                            Button(role: .destructive) {
                                let ids = results.filter { !$0.search.isPass }
                                    .compactMap { r in app.sources.first { $0.displayName == r.sourceName }?.id }
                                app.deleteSources(ids)
                                results.removeAll { !$0.search.isPass }
                                app.showToast("已删除 \(ids.count) 个不可用源")
                            } label: {
                                Label("删除 \(bad) 个搜索不通的源", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("书源体检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func stepRow(_ name: String, _ step: HealthCheck.Step) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(step.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(step.isFail ? .red : (step.isPass ? .green : .secondary))
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(step.text)
                .font(.system(size: 12))
                .foregroundStyle(step.isFail ? .red : .primary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    private func runCheck() {
        running = true
        results = []
        let list = targets
        total = list.count
        current = 0
        let kw = keyword.isEmpty ? "斗破" : keyword

        Task {
            var acc: [HealthCheck] = []
            for s in list {
                await MainActor.run { current += 1 }
                let r = await SourceHealthChecker.check(source: s, keyword: kw)
                acc.append(r)
                let snapshot = acc
                await MainActor.run { results = snapshot }
            }
            await MainActor.run {
                running = false
                let ok = acc.filter { $0.allPassed }.count
                app.showToast("体检完成：\(ok)/\(acc.count) 个源完全可用")
            }
        }
    }

    private func reportText() -> String {
        var lines: [String] = ["墨阅书源体检报告 \(Date())"]
        for r in results {
            lines.append("")
            lines.append("【\(r.sourceName)】\(r.summary)")
            lines.append("  配置 \(r.config.symbol) \(r.config.text)")
            lines.append("  搜索 \(r.search.symbol) \(r.search.text)")
            lines.append("  详情 \(r.bookInfo.symbol) \(r.bookInfo.text)")
            lines.append("  目录 \(r.toc.symbol) \(r.toc.text)")
            lines.append("  正文 \(r.content.symbol) \(r.content.text)")
            if !r.sampleBook.isEmpty { lines.append("  样本 \(r.sampleBook)") }
        }
        return lines.joined(separator: "\n")
    }
}
