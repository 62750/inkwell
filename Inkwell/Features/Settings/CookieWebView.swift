import SwiftUI
import WebKit

// MARK: - 登录用 WebView
//
// 站点要求登录才能看目录/正文时，在这里登录一次。
// WKWebView 的 Cookie 与 URLSession 不共享，所以每次页面变化后
// 把 WKHTTPCookieStore 里的 cookie 同步进 HTTPCookieStorage。

struct CookieWebView: UIViewRepresentable {
    let url: URL?
    let reloadToken: UUID

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.customUserAgent = HTTPClient.defaultUA
        context.coordinator.webView = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.lastToken != reloadToken, let url else { return }
        context.coordinator.lastToken = reloadToken
        web.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastToken: UUID?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookies()
        }

        func syncCookies() {
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                for c in cookies {
                    HTTPCookieStorage.shared.setCookie(c)
                }
            }
        }
    }
}
