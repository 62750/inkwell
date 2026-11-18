import SwiftUI

@main
struct InkwellApp: App {
    @StateObject private var app = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    // init 里不做任何 IO：数据库与数据加载全部推迟到首帧之后（见 RootView.task）

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(app.settings.theme.isDark ? .dark : nil)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                AppState.shared.loadBooks()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabShell()
            .task {
                // 首帧渲染完成后才开始加载数据
                await app.bootstrap()
            }
            .onOpenURL { url in
                // 从「文件」「微信」「QQ」等用「用其他应用打开」唤起
                guard url.isFileURL else { return }
                app.importFile(url)
            }
            .overlay(alignment: .bottom) {
                if let toast = app.toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 70)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: app.toast)
    }
}

struct TabShell: View {
    @EnvironmentObject var app: AppState
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            DiscoverView()
                .tabItem { Label("发现", systemImage: "safari") }
                .tag(1)

            SourceListView()
                .tabItem { Label("书源", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)

            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(3)
        }
        .tint(.accentColor)
    }
}
