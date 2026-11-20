import SwiftUI
import UIKit

// MARK: - 阅读器容器

struct ReaderContainerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let book: Book
    @StateObject private var vm: ReaderViewModel
    @State private var showCatalog = false

    init(book: Book) {
        self.book = book
        _vm = StateObject(wrappedValue: ReaderViewModel(book: book,
                                                        settings: .default))
    }

    var body: some View {
        ZStack {
            Color(uiColor: vm.settings.theme.background).ignoresSafeArea()

            if vm.isComic {
                ComicReaderView(vm: vm)
            } else {
                TextReaderView(vm: vm)
            }

            if vm.loading {
                ProgressView()
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .opacity(vm.showMenu ? 0 : 1)
                    .allowsHitTesting(false)   // 加载中也能点出菜单
            }

            // 顶部/底部菜单
            if vm.showMenu {
                ReaderMenuOverlay(vm: vm, book: book, onClose: { dismiss() },
                                  onCatalog: { showCatalog = true })
                    .transition(.opacity)
            }

            if showCatalog {
                CatalogOverlay(vm: vm, isPresented: $showCatalog)
                    .transition(.move(edge: .leading))
            }

            if vm.showSettings {
                ReaderSettingsPanel(vm: vm, isPresented: $vm.showSettings)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.showMenu)
        .animation(.easeInOut(duration: 0.22), value: showCatalog)
        .animation(.easeInOut(duration: 0.22), value: vm.showSettings)
        .statusBarHidden(!vm.showMenu)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            vm.settings = app.settings
            vm.start()
        }
        .onDisappear {
            vm.saveProgress()
            app.loadBooks()
        }
        .onChange(of: vm.settings) { _, newValue in
            app.updateSettings(newValue)
        }
        .sheet(isPresented: $vm.showSourceSwap) {
            SourceSwapView(vm: vm)
                .environmentObject(app)
        }
    }
}

// MARK: - 文本阅读

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @State private var contentSize: CGSize = .zero
    @State private var scrollPos: Int?

    var body: some View {
        GeometryReader { geo in
            // 竖条占用右侧固定宽度，正文让出来，避免压字
            let showBar = vm.settings.showChapterBar && vm.pageCount > 1
            let barReserve: CGFloat = showBar ? 26 : 0
            let inner = CGSize(
                width: max(80, geo.size.width - vm.settings.marginH * 2 - barReserve),
                height: max(80, geo.size.height - vm.settings.marginV * 2) - footerHeight
            )

            ZStack(alignment: .trailing) {
                // ---- 正文 ----
                Group {
                    if vm.settings.turnMode == .scroll {
                        scrollBody(size: inner)
                    } else {
                        pagedBody(size: inner)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, vm.settings.marginH)
                .padding(.top, vm.settings.marginV)
                .padding(.bottom, vm.settings.marginV)
                .overlay(alignment: .bottom) {
                    if vm.settings.showProgress { footer }
                }
                .overlay(alignment: .top) {
                    if !vm.showMenu { chapterHeader }
                }


                // ---- 右侧章内进度条：ZStack 最上层，直接贴右边缘 ----
                // 之前用 .padding(.trailing, -marginH + 1) 把它推出了屏幕，所以看不见
                if showBar {
                    ChapterProgressBar(
                        progress: vm.chapterProgress,
                        onScrub: { ratio in vm.jumpToProgress(ratio: ratio) }
                    )
                    .frame(width: 24)
                    .padding(.vertical, vm.settings.marginV + 4)
                    .allowsHitTesting(!vm.showMenu)
                }
            }
            .task(id: inner) {
                contentSize = inner
                vm.repaginate(size: inner)
            }
            .onChange(of: vm.pendingText) { _, _ in
                vm.repaginate(size: inner)
            }
            .onChange(of: geo.size) { _, _ in
                vm.repaginate(size: inner)
            }
            .onChange(of: vm.chapterIndex) { _, _ in
                vm.repaginate(size: inner)
            }
        }
    }

    private var footerHeight: CGFloat { 22 }

    // MARK: 分页模式

    private func pagedBody(size: CGSize) -> some View {
        Group {
            if let paginated = vm.paginated, paginated.pageCount > 0 {
                readerPager(paginated: paginated, size: size)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func readerPager(paginated: PaginatedChapter, size: CGSize) -> some View {
        let count = paginated.pageCount
        TabView(selection: Binding(
            get: { min(vm.pageIndex, max(0, count - 1)) },
            set: { vm.pageIndex = $0; vm.saveProgress() }
        )) {
            ForEach(0..<count, id: \.self) { i in
                PageTextView(
                    attributed: Paginator.pageAttributedString(paginated: paginated,
                                                               page: i,
                                                               settings: vm.settings),
                    theme: vm.settings.theme
                )
                .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                guard !vm.showMenu else { return }
                let w = max(1, size.width)
                let x = value.location.x
                if x < w * 0.3 || x > w * 0.7 {
                    vm.showMenu = true
                } else {
                    vm.showMenu.toggle()
                }
            }
        )
    }



    // MARK: 滚动模式

    private func scrollBody(size: CGSize) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                if vm.pendingText.isEmpty {
                    ProgressView().padding(40).id(0)
                } else {
                    LazyVStack(alignment: .leading, spacing: vm.settings.fontSize * 0.5) {
                        ForEach(Array(vm.scrollParagraphs.enumerated()), id: \.offset) { idx, para in
                            Text(para)
                                .font(Font(vm.settings.uiFont))
                                .lineSpacing(vm.settings.fontSize * (vm.settings.lineHeightMultiple - 1))
                                .foregroundStyle(Color(uiColor: vm.settings.theme.textColor))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard !vm.showMenu else { return }
                    let w = max(1, size.width)
                    let x = value.location.x
                    if x < w * 0.3 || x > w * 0.7 {
                        vm.showMenu = true
                    } else {
                        vm.showMenu.toggle()
                    }
                }
            )
            .scrollPosition(id: Binding(
                get: { scrollPos },
                set: { new in
                    scrollPos = new
                    if let new { vm.visibleParagraph = new }
                }
            ))
            .onChange(of: vm.scrollRequest) { req in
                if let req {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(req, anchor: .top)
                    }
                    vm.scrollRequest = nil
                }
            }
        }
    }

    // MARK: 章节抬头 / 页脚

    private var chapterHeader: some View {
        HStack {
            Text(vm.currentChapter?.title ?? "")
                .font(.system(size: 10))
                .foregroundStyle(Color(uiColor: vm.settings.theme.secondaryColor))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, vm.settings.marginH)
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack {
            Text(formattedTime())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(uiColor: vm.settings.theme.secondaryColor))
            Spacer()
            if vm.settings.turnMode == .scroll {
                Text("\(vm.visibleParagraph + 1) / \(max(1, vm.scrollParagraphs.count))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(uiColor: vm.settings.theme.secondaryColor))
            } else {
                Text("\(vm.pageIndex + 1) / \(max(1, vm.pageCount))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(uiColor: vm.settings.theme.secondaryColor))
            }
            Spacer()
            Text("\(Int(vm.chapterProgress * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(uiColor: vm.settings.theme.secondaryColor))
        }
        .padding(.horizontal, vm.settings.marginH)
        .padding(.bottom, 2)
    }

    private func overallPercent() -> Double {
        guard !vm.chapters.isEmpty else { return 0 }
        let c = Double(vm.chapterIndex) / Double(vm.chapters.count)
        let p = vm.pageCount > 0 ? Double(vm.pageIndex) / Double(vm.pageCount) / Double(vm.chapters.count) : 0
        return min(1, c + p)
    }

    private func formattedTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}

// MARK: - 单页文本渲染

struct PageTextView: UIViewRepresentable {
    let attributed: NSAttributedString
    let theme: ReaderTheme

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = []
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.attributedText = attributed
        tv.backgroundColor = .clear
    }
}

// MARK: - 章内进度条（右侧竖条，可拖动）
//
// 早先版本只有 3pt 宽、80% 透明，几乎看不见。现在做成：
//   5pt 轨道 + 实心填充 + 11pt 拇指 + 22pt 触摸区，
//   拖动时右侧浮出百分比，松手即跳到对应页。

struct ChapterProgressBar: View {
    let progress: Double
    let onScrub: (Double) -> Void

    @State private var dragging = false
    @State private var dragValue: Double = 0

    private var display: Double {
        min(1, max(0, dragging ? dragValue : progress))
    }

    var body: some View {
        GeometryReader { geo in
            let h = max(1, geo.size.height)
            let trackW: CGFloat = 5
            let knob: CGFloat = 11

            // 直觉方向：顶部 = 章首(0%)，底部 = 章尾(100%)，填充从上往下长
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.secondary.opacity(0.20))
                    .frame(width: trackW, height: h)

                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: trackW, height: max(knob, h * display))

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .position(x: geo.size.width / 2,
                              y: min(h - knob / 2, max(knob / 2, h * display)))
            }
            .frame(width: geo.size.width, height: h)
            .contentShape(Rectangle())
            // highPriorityGesture：进度条手势优先于 ScrollView 滚动。
            // 高优先级手势一旦识别成功，下层的 ScrollView 就收不到这个触摸，
            // 所以拖进度条不会触发滚动，松手后滚动自然恢复，无需额外禁用。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        // 顶部 = 0，底部 = 1
                        let ratio = value.location.y / h
                        dragValue = min(1, max(0, ratio))
                    }
                    .onEnded { _ in
                        dragging = false
                        onScrub(dragValue)   // 松手才真正跳转
                    }
            )
            .overlay(alignment: .leading) {
                if dragging {
                    Text("\(Int((display * 100).rounded()))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .fixedSize()
                        .offset(x: -46)
                }
            }
        }
        .frame(width: 22)
        .padding(.vertical, 2)
    }
}