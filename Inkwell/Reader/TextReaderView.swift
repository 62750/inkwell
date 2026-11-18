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
    }
}

// MARK: - 文本阅读

struct TextReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @State private var contentSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let inner = CGSize(
                width: max(80, geo.size.width - vm.settings.marginH * 2),
                height: max(80, geo.size.height - vm.settings.marginV * 2)
                    - footerHeight
            )

            ZStack {
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
                if vm.settings.showProgress {
                    footer
                }
            }
            .overlay(alignment: .top) {
                if !vm.showMenu {
                    chapterHeader
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
        }
    }

    private var footerHeight: CGFloat { 22 }

    // MARK: 分页模式

    private func pagedBody(size: CGSize) -> some View {
        Group {
            if let paginated = vm.paginated, paginated.pageCount > 0 {
                readerPager(paginated: paginated)
            } else {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private func readerPager(paginated: PaginatedChapter) -> some View {
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
                .overlay(tapZones)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.showMenu = true }
                .frame(maxWidth: .infinity)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.showMenu.toggle() }
                .frame(maxWidth: .infinity)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.showMenu = true }
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: 滚动模式

    private func scrollBody(size: CGSize) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            if vm.pendingText.isEmpty {
                ProgressView().padding(40)
            } else {
                Text(vm.pendingText)
                    .font(Font(vm.settings.uiFont))
                    .lineSpacing(vm.settings.fontSize * (vm.settings.lineHeightMultiple - 1))
                    .foregroundStyle(Color(uiColor: vm.settings.theme.textColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .onTapGesture { vm.showMenu.toggle() }
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
            Text("\(vm.pageIndex + 1) / \(max(1, vm.pageCount))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(uiColor: vm.settings.theme.secondaryColor))
            Spacer()
            Text("\(Int(overallPercent() * 100))%")
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
