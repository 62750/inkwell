import SwiftUI
import UIKit

// MARK: - 漫画阅读器

struct ComicReaderView: View {
    @ObservedObject var vm: ReaderViewModel
    @State private var pageIndex = 0
    @State private var zoomed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.comicImages.isEmpty {
                VStack(spacing: 10) {
                    if vm.loading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 42, weight: .thin))
                            .foregroundStyle(.white.opacity(0.4))
                        Text(vm.errorMessage ?? "本章没有图片")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            } else {
                switch vm.settings.comicLayout {
                case .vertical:
                    verticalReader
                case .pageHorizontal, .doublePage, .rightToLeft:
                    pagedReader
                }
            }

            // 点按呼出菜单
            if !vm.showMenu {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { previous() }
                        .frame(width: 60)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { vm.showMenu = true }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { next() }
                        .frame(width: 60)
                }
            }
        }
    }

    // MARK: 条漫

    private var verticalReader: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: vm.settings.comicPageGap) {
                ForEach(Array(vm.comicImages.enumerated()), id: \.offset) { idx, url in
                    ComicImage(url: url, fitWidth: vm.settings.comicFitWidth)
                        .id(idx)
                }
                footerBar
            }
            .padding(.vertical, 0)
        }
        .background(Color.black)
    }

    // MARK: 页漫

    private var pagedReader: some View {
        TabView(selection: $pageIndex) {
            ForEach(Array(vm.comicImages.enumerated()), id: \.offset) { idx, url in
                ZoomableComicImage(url: url)
                    .tag(idx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            HStack {
                Text("\(pageIndex + 1) / \(vm.comicImages.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.bottom, 8)
            .opacity(vm.showMenu ? 0 : 1)
        }
    }

    private var footerBar: some View {
        VStack(spacing: 12) {
            if vm.chapterIndex + 1 < vm.chapters.count {
                Button {
                    vm.comicNextChapter()
                    pageIndex = 0
                } label: {
                    Text("下一话：\(vm.chapters[vm.chapterIndex + 1].title)")
                        .font(.footnote)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.12), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 24)
            } else {
                Text("已经是最后一话").font(.caption).foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 24)
            }
        }
    }

    private func next() {
        if pageIndex + 1 < vm.comicImages.count {
            pageIndex += 1
        } else {
            vm.comicNextChapter()
            pageIndex = 0
        }
    }

    private func previous() {
        if pageIndex > 0 { pageIndex -= 1 }
    }
}

// MARK: - 图片单元

struct ComicImage: View {
    let url: String
    var fitWidth: Bool = true

    var body: some View {
        Group {
            if url.hasPrefix("/") {
                if let img = UIImage(contentsOfFile: url) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    placeholder
                }
            } else {
                RemoteImage(url: url, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 120)
            }
        }
    }

    private var placeholder: some View {
        Rectangle().fill(Color.white.opacity(0.06))
            .frame(height: 200)
            .overlay(Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.white.opacity(0.3)))
    }
}

// MARK: - 可缩放图片

struct ZoomableComicImage: View {
    let url: String

    var body: some View {
        ZoomableScrollView {
            if url.hasPrefix("/") {
                if let img = UIImage(contentsOfFile: url) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.black
                }
            } else {
                RemoteImage(url: url, contentMode: .fit)
            }
        }
        .ignoresSafeArea()
    }
}

struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 3
        scroll.delegate = context.coordinator
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .black

        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        context.coordinator.host = host
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.host?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var host: UIHostingController<Content>?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            host?.view
        }
    }
}
