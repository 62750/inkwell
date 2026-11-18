import UIKit
import SwiftUI

// MARK: - 源商店：内置源 / 订阅 / 一键建源
//
// 这是「替换书源」的总入口。三个 Tab 分别解决：
//   内置：开箱能用的自适应源
//   订阅：从社区 JSON 包批量导入，支持三种合并策略
//   建源：给个域名，自动探测出可用规则

struct SourceStoreView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Int = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("内置源").tag(0)
                    Text("订阅").tag(1)
                    Text("一键建源").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                switch tab {
                case 0: BuiltinSourceList(tab: $tab)
                case 1: SubscriptionList()
                default: AutoBuildView()
                }
            }
            .navigationTitle("源商店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 内置源

struct BuiltinSourceList: View {
    @EnvironmentObject var app: AppState
    @Binding var tab: Int
    @State private var showRecommended = false

    private var seeds: [BookSource] { BuiltinSources.seeds() }

    var body: some View {
        List {
            Section {
                ForEach(seeds) { seed in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: seed.isComic ? "photo.on.rectangle" : "text.book.closed")
                                .foregroundStyle(seed.isComic ? .orange : .accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(seed.displayName).font(.subheadline.weight(.medium))
                                Text(seed.bookSourceGroup).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isInstalled(seed) {
                                Label("已装", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                            } else {
                                Button("安装") { install(seed) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                        Text(seed.bookSourceComment)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("自适应源")
            } footer: {
                Text("规则不写死：首次打开时现场分析页面结构，自动推导选择器。站点改版后点源详情里的「校准」即可修复，不影响原始规则。")
                    .font(.caption2)
            }

            Section {
                Button {
                    tab = 2
                } label: {
                    Label("输入域名 / 网址自动建源", systemImage: "wand.and.stars")
                }
                Button {
                    showRecommended = true
                } label: {
                    Label("社区书源合集", systemImage: "square.grid.2x2")
                }
            } header: {
                Text("更多")
            }

            Section {
                HStack {
                    Text("已启用源")
                    Spacer()
                    Text("\(app.enabledSources.count)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("小说 / 漫画")
                    Spacer()
                    Text("\(app.textSources.count) / \(app.comicSources.count)")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("内置源只是起点。真正长期可用的做法是配置订阅，让书源包自己更新。")
                    .font(.caption2)
            }
        }
        .listStyle(.insetGrouped)

        .sheet(isPresented: $showRecommended) {
            RecommendedPackView()
        }
    }


    private func isInstalled(_ seed: BookSource) -> Bool {
        app.sources.contains {
            $0.bookSourceName == seed.bookSourceName
                && $0.bookSourceGroup == seed.bookSourceGroup
        }
    }

    private func install(_ seed: BookSource) {
        app.saveSource(seed)
        app.showToast("已安装 \(seed.displayName)，填入站点地址后即可用")
    }
}

// MARK: - 订阅

struct SubscriptionList: View {
    @EnvironmentObject var app: AppState
    @StateObject private var packManager = SourcePackManager.shared
    @State private var showAdd = false
    @State private var editingPack: SourcePack?
    @State private var polling = false

    var body: some View {
        List {
            if packManager.packs.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有订阅").font(.subheadline.weight(.medium))
                        Text("订阅 = 一个远程 JSON 地址。拉取时可选择「整包替换 / 增量合并 / 只补缺」，之后随时能换。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                ForEach(packManager.packs) { pack in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name).font(.subheadline.weight(.medium))
                                Text(pack.url).font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if packManager.busyPackId == pack.id {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Button("拉取") {
                                    Task {
                                        let r = await packManager.fetch(pack.id)
                                        if r.error == nil {
                                            app.loadSources()
                                            app.showToast("新增 \(r.added) / 更新 \(r.updated)")
                                        } else {
                                            app.showToast(r.error ?? "失败")
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        HStack(spacing: 8) {
                            Text(pack.mergeMode.label)
                                .font(.system(size: 9))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.13), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                            if let t = pack.lastFetched {
                                Text("上次 \(timeAgo(t)) · \(pack.lastCount) 个")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            if let e = pack.lastError {
                                Text(e).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .swipeActions {
                        Button(role: .destructive) {
                            packManager.remove(pack.id)
                        } label: { Label("删除", systemImage: "trash") }
                        Button {
                            editingPack = pack
                        } label: { Label("策略", systemImage: "slider.horizontal.3") }
                        .tint(.orange)
                    }
                }
            } header: {
                HStack {
                    Text("我的订阅")
                    Spacer()
                    Button {
                        showAdd = true
                    } label: { Image(systemName: "plus.circle") }
                }
            } footer: {
                if !packManager.lastLog.isEmpty {
                    Text(packManager.lastLog.joined(separator: "\n")).font(.caption2)
                }
            }

            Section {
                Button {
                    polling = true
                    Task {
                        let r = await packManager.fetchAll()
                        app.loadSources()
                        polling = false
                        app.showToast("全部拉取完成：新增 \(r.added)，更新 \(r.updated)")
                    }
                } label: {
                    HStack {
                        Label("拉取全部订阅", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if polling { ProgressView().scaleEffect(0.7) }
                    }
                }

                ShareLink(item: packManager.exportEnabled()) {
                    Label("导出当前书源（JSON）", systemImage: "square.and.arrow.up")
                }

                Button {
                    UIPasteboard.general.string = packManager.exportAll()
                    app.showToast("全部书源已复制到剪贴板")
                } label: {
                    Label("复制全部书源到剪贴板", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("批量操作")
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showAdd) {
            AddPackSheet().environmentObject(app)
        }
        .sheet(item: $editingPack) { pack in
            NavigationStack {
                Form {
                    Section("合并策略") {
                        Picker("策略", selection: Binding(
                            get: { pack.mergeMode },
                            set: { mode in
                                var p = pack
                                p.mergeMode = mode
                                packManager.update(p)
                            }
                        )) {
                            ForEach(MergeMode.allCases, id: \.self) {
                                Text($0.label).tag($0)
                            }
                        }
                        Text(pack.mergeMode.note).font(.caption2).foregroundStyle(.secondary)
                    }
                    Section {
                        Text(pack.url).font(.system(size: 10, design: .monospaced))
                    }
                }
                .navigationTitle(pack.name)
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.height(280)])
        }
    }

    private func timeAgo(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s / 60)分钟前" }
        if s < 86400 { return "\(s / 3600)小时前" }
        return "\(s / 86400)天前"
    }
}

struct AddPackSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var packManager = SourcePackManager.shared

    @State private var name = ""
    @State private var url = ""
    @State private var mode: MergeMode = .merge

    var body: some View {
        NavigationStack {
            Form {
                Section("订阅地址") {
                    TextField("名称（可空）", text: $name)
                    TextField("https://…/shuyuan.json", text: $url, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2...4)
                }
                Section("合并策略") {
                    Picker("策略", selection: $mode) {
                        ForEach(MergeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(mode.note).font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        add()
                    } label: {
                        Text("添加并拉取").frame(maxWidth: .infinity)
                    }
                    .disabled(!url.lowercased().hasPrefix("http"))
                }
            }
            .navigationTitle("新建订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard URL(string: url) != nil else {
            app.showToast("地址不合法")
            return
        }
        let pack = packManager.add(name: name, url: url, mode: mode)
        dismiss()
        Task {
            let r = await packManager.fetch(pack.id)
            app.loadSources()
            if r.error == nil {
                app.showToast("导入 \(r.added + r.updated) 个书源")
            } else {
                app.showToast(r.error ?? "拉取失败")
            }
        }
    }
}

// MARK: - 社区合集

struct RecommendedPackView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(BuiltinSources.recommended) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.subheadline.weight(.medium))
                            Text(item.note).font(.caption).foregroundStyle(.secondary)
                            if let u = URL(string: item.url) {
                                Link(destination: u) {
                                    Text(item.url).font(.system(size: 9, design: .monospaced))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("长期维护的书源合集")
                } footer: {
                    Text(BuiltinSources.fallbackPackNote).font(.caption2)
                }
            }
            .navigationTitle("社区书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
