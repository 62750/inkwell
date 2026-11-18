import SwiftUI

// MARK: - 阅读器顶部/底部菜单

struct ReaderMenuOverlay: View {
    @ObservedObject var vm: ReaderViewModel
    let book: Book
    let onClose: () -> Void
    let onCatalog: () -> Void

    @State private var sliderValue: Double = 0
    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { vm.showMenu = false }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(book.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(vm.currentChapter?.title ?? "")
                    .font(.system(size: 11))
                    .opacity(0.6)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                vm.jump(toChapter: vm.chapterIndex)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
            }
        }
        .foregroundStyle(Color(uiColor: vm.settings.theme.textColor))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            // 进度条
            HStack(spacing: 10) {
                Text("\(Int(boundValue * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 34, alignment: .leading)
                Slider(value: Binding(
                    get: { boundValue },
                    set: { v in
                        sliderValue = v
                        if !dragging {
                            jumpToPercent(v)
                        }
                    }
                ), in: 0...1, onEditingChanged: { editing in
                    dragging = editing
                    if !editing { jumpToPercent(sliderValue) }
                })
                .tint(.accentColor)
            }
            .padding(.horizontal, 18)

            HStack(spacing: 0) {
                toolButton("目录", "list.bullet") {
                    onCatalog()
                }
                toolButton("设置", "textformat.size") {
                    vm.showSettings = true
                    vm.showMenu = false
                }
                toolButton("上一章", "chevron.left.to.line") {
                    if vm.chapterIndex > 0 { vm.jump(toChapter: vm.chapterIndex - 1) }
                }
                toolButton("下一章", "chevron.right.to.line") {
                    if vm.chapterIndex + 1 < vm.chapters.count {
                        vm.jump(toChapter: vm.chapterIndex + 1)
                    }
                }
                toolButton("书签", "bookmark") {
                    addBookmark()
                }
            }
            .padding(.bottom, 6)
        }
        .padding(.top, 12)
        .foregroundStyle(Color(uiColor: vm.settings.theme.textColor))
        .background(.ultraThinMaterial)
    }

    private var boundValue: Double {
        if dragging { return sliderValue }
        guard !vm.chapters.isEmpty else { return 0 }
        let c = Double(vm.chapterIndex) / Double(vm.chapters.count)
        let p = vm.pageCount > 0
            ? Double(vm.pageIndex) / Double(vm.pageCount) / Double(vm.chapters.count)
            : 0
        return min(1, max(0, c + p))
    }

    private func jumpToPercent(_ v: Double) {
        guard !vm.chapters.isEmpty else { return }
        let idx = min(vm.chapters.count - 1, max(0, Int(v * Double(vm.chapters.count))))
        if idx != vm.chapterIndex { vm.jump(toChapter: idx) }
    }

    private func toolButton(_ title: String, _ icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .light))
                Text(title).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func addBookmark() {
        guard let ch = vm.currentChapter else { return }
        let excerpt: String = {
            guard let p = vm.paginated, vm.pageIndex < p.ranges.count else { return "" }
            let ns = p.text as NSString
            let r = p.ranges[vm.pageIndex]
            guard r.location + min(r.length, 80) <= ns.length else { return "" }
            return ns.substring(with: NSRange(location: r.location, length: min(r.length, 80)))
        }()
        let bm = Bookmark(bookId: book.id, chapterIndex: ch.index,
                          chapterTitle: ch.title, charOffset: vm.pageIndex,
                          excerpt: excerpt, note: "")
        LibraryRepository.shared.saveBookmark(bm)
        AppState.shared.showToast("已加书签")
    }
}

// MARK: - 目录抽屉

struct CatalogOverlay: View {
    @ObservedObject var vm: ReaderViewModel
    @Binding var isPresented: Bool
    @State private var keyword = ""
    @State private var reversed = false

    var filtered: [Chapter] {
        var list = vm.chapters
        if !keyword.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        }
        return reversed ? list.reversed() : list
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                HStack {
                    Text("目录").font(.headline)
                    Spacer()
                    Button {
                        reversed.toggle()
                    } label: {
                        Image(systemName: reversed ? "arrow.up" : "arrow.down")
                            .font(.system(size: 13))
                    }
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 13))
                    }
                    .padding(.leading, 12)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                TextField("搜索章节", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                Divider()

                ScrollViewReader { proxy in
                    List(filtered) { ch in
                        Button {
                            vm.jump(toChapter: ch.index)
                            isPresented = false
                        } label: {
                            HStack {
                                Text(ch.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                    .foregroundStyle(ch.index == vm.chapterIndex
                                                     ? Color.accentColor : .primary)
                                Spacer()
                                if ch.isVip {
                                    Image(systemName: "lock.fill").font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .id(ch.index)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .listStyle(.plain)
                    .onAppear {
                        proxy.scrollTo(vm.chapterIndex, anchor: .center)
                    }
                }
            }
            .frame(width: min(320, UIScreen.main.bounds.width * 0.82))
            .background(.regularMaterial)
            .ignoresSafeArea(edges: .vertical)
        }
    }
}

// MARK: - 阅读设置面板

struct ReaderSettingsPanel: View {
    @ObservedObject var vm: ReaderViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 16) {
                HStack {
                    Text("阅读设置").font(.headline)
                    Spacer()
                    Button("完成") { isPresented = false }
                        .font(.subheadline.bold())
                }

                // 字号
                HStack {
                    Text("字号").font(.subheadline).frame(width: 48, alignment: .leading)
                    Button { update { $0.fontSize = max(12, $0.fontSize - 1) } } label: {
                        Image(systemName: "minus").frame(width: 36, height: 32)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("\(Int(vm.settings.fontSize))")
                        .font(.system(size: 14, design: .monospaced))
                        .frame(width: 34)
                    Button { update { $0.fontSize = min(34, $0.fontSize + 1) } } label: {
                        Image(systemName: "plus").frame(width: 36, height: 32)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    Toggle("首行缩进", isOn: Binding(
                        get: { vm.settings.firstLineIndent },
                        set: { v in update { $0.firstLineIndent = v } }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.8)
                    Text("缩进").font(.caption2).foregroundStyle(.secondary)
                }

                // 行距
                HStack {
                    Text("行距").font(.subheadline).frame(width: 48, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(vm.settings.lineHeightMultiple) },
                        set: { v in update { $0.lineHeightMultiple = CGFloat(v) } }
                    ), in: 1.2...2.6)
                    Text(String(format: "%.2f", vm.settings.lineHeightMultiple))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 34)
                }

                // 页边距
                HStack {
                    Text("边距").font(.subheadline).frame(width: 48, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(vm.settings.marginH) },
                        set: { v in update { $0.marginH = CGFloat(v) } }
                    ), in: 8...44)
                    Text("\(Int(vm.settings.marginH))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 34)
                }

                // 字体
                HStack {
                    Text("字体").font(.subheadline).frame(width: 48, alignment: .leading)
                    ForEach(ReadingSettings.fontOptions, id: \.id) { opt in
                        Button {
                            update { $0.fontFamily = opt.id }
                        } label: {
                            Text(opt.name)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(vm.settings.fontFamily == opt.id
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.secondary.opacity(0.10),
                                            in: Capsule())
                                .foregroundStyle(vm.settings.fontFamily == opt.id
                                                 ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // 主题
                HStack(spacing: 10) {
                    ForEach(ReaderTheme.allCases, id: \.self) { t in
                        Button {
                            update { $0.theme = t }
                        } label: {
                            Circle()
                                .fill(Color(uiColor: t.background))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(
                                    vm.settings.theme == t ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: vm.settings.theme == t ? 2 : 0.5))
                                .overlay(Text(t.label).font(.system(size: 8))
                                    .foregroundStyle(Color(uiColor: t.textColor)))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // 翻页模式 / 漫画模式
                Picker("翻页", selection: Binding(
                    get: { vm.settings.turnMode },
                    set: { v in update { $0.turnMode = v } }
                )) {
                    ForEach(PageTurnMode.allCases, id: \.self) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                if vm.isComic {
                    Picker("漫画", selection: Binding(
                        get: { vm.settings.comicLayout },
                        set: { v in update { $0.comicLayout = v } }
                    )) {
                        ForEach(ComicLayoutMode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func update(_ mutate: (inout ReadingSettings) -> Void) {
        var s = vm.settings
        mutate(&s)
        vm.apply(settings: s)
    }
}
