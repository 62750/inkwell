import Foundation
import WebKit

// MARK: - Cookie 罐
// 站点登录态、Cloudflare 过渡 cookie 全靠它。用 WKWebsiteDataStore 做持久化，
// 这样 WebView 里登录一次，URLSession 请求也带上。

actor CookieJar {
    static let shared = CookieJar()
    private var cache: [String: [HTTPCookie]] = [:]

    func setCookies(from response: HTTPURLResponse, url: URL) {
        guard let host = url.host else { return }
        let headers = response.allHeaderFields
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers as? [String: String] ?? [:],
                                         for: url)
        guard !cookies.isEmpty else { return }
        var list = cache[host] ?? []
        for c in cookies {
            list.removeAll { $0.name == c.name && $0.path == c.path }
            list.append(c)
            HTTPCookieStorage.shared.setCookie(c)
        }
        cache[host] = list
    }

    func cookieHeader(for url: URL) -> String? {
        let all = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !all.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: all)["Cookie"]
    }

    func manualSet(_ raw: String, host: String) {
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let name = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if let c = HTTPCookie(properties: [
                .domain: host, .path: "/", .name: name, .value: value,
                .secure: "FALSE"
            ]) {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }

    func clear(host: String? = nil) {
        if let host {
            for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.contains(host) {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        } else {
            for c in HTTPCookieStorage.shared.cookies ?? [] {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
    }

    /// 生成给 JS 的 cookie 字符串（document.cookie 形式）
    func jsCookieString(for url: URL) -> String {
        let all = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return all.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: - HTTP 客户端

struct HTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    let finalURL: URL
    let text: String

    var isHTML: Bool {
        let ct = headers["Content-Type"]?.lowercased() ?? ""
        return ct.contains("html") || ct.contains("xml") || ct.contains("json")
    }
}

enum HTTPError: LocalizedError {
    case badURL(String)
    case status(Int, String)
    case empty
    case decoding
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "URL 不合法：\(u)"
        case .status(let c, let u): return "HTTP \(c) — \(u)"
        case .empty: return "响应为空"
        case .decoding: return "解码失败"
        case .blocked(let r): return "被站点拦截：\(r)"
        }
    }
}

final class HTTPClient: @unchecked Sendable {
    static let shared = HTTPClient()

    private let session: URLSession
    private let config: URLSessionConfiguration
    /// 全局 QPS 限速（书源 concurrentRate）
    private var rateLimiter = RateLimiter()

    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init() {
        config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 8
        session = URLSession(configuration: config, delegate: nil, delegateQueue: opQueue)
    }

    // MARK: 主请求

    func request(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        encoding: String? = nil,
        referer: String? = nil,
        timeout: TimeInterval? = nil,
        allowRedirect: Bool = true,
        maxRetry: Int = 2
    ) async throws -> HTTPResponse {
        guard let u = URL(string: url), u.scheme != nil else { throw HTTPError.badURL(url) }

        await rateLimiter.acquire(host: u.host ?? "")

        var attempt = 0
        var lastError: Error = HTTPError.empty
        while attempt <= maxRetry {
            do {
                var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: timeout ?? 20)
                req.httpMethod = method
                req.httpBody = body
                req.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
                req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
                req.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
                if let referer, !referer.isEmpty {
                    req.setValue(referer, forHTTPHeaderField: "Referer")
                }
                for (k, v) in headers {
                    if k.lowercased() == "referer", !v.isEmpty { continue }
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if let cookie = await CookieJar.shared.cookieHeader(for: u) {
                    req.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
                if req.value(forHTTPHeaderField: "Accept") == nil {
                    req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                                 forHTTPHeaderField: "Accept")
                }

                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else { throw HTTPError.empty }
                await CookieJar.shared.setCookies(from: http, url: http.url ?? u)

                var headerMap: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    headerMap[String(describing: k)] = String(describing: v)
                }

                if (300...399).contains(http.statusCode), !allowRedirect,
                   let loc = headerMap["Location"] ?? headerMap["location"] {
                    let next = StringExt.absolute(loc, base: http.url?.absoluteString ?? url)
                    return try await request(url: next, headers: headers, encoding: encoding,
                                             referer: referer, timeout: timeout,
                                             allowRedirect: false, maxRetry: 0)
                }

                if http.statusCode == 403 || http.statusCode == 503 {
                    if attempt < maxRetry {
                        attempt += 1
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        continue
                    }
                    throw HTTPError.blocked("HTTP \(http.statusCode)")
                }
                if http.statusCode == 429 {
                    if attempt < maxRetry {
                        attempt += 1
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    }
                    throw HTTPError.status(429, url)
                }
                if http.statusCode >= 400 {
                    throw HTTPError.status(http.statusCode, url)
                }

                let text = CharsetDetector.decode(data,
                                                  declared: encoding ?? headerMap["Content-Type"]?.charsetParam)
                return HTTPResponse(data: data, statusCode: http.statusCode,
                                    headers: headerMap, finalURL: http.url ?? u, text: text)
            } catch let e as HTTPError {
                lastError = e
                if case .status = e { throw e }
                attempt += 1
                if attempt > maxRetry { throw e }
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                lastError = error
                attempt += 1
                if attempt > maxRetry { throw error }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError
    }

    // MARK: POST form

    func postForm(url: String, form: [String: String], headers: [String: String] = [:],
                  encoding: String = "UTF-8", referer: String? = nil) async throws -> HTTPResponse {
        let body = form.map { k, v in
            "\(StringExt.urlEncode(k))=\(StringExt.urlEncode(v))"
        }.joined(separator: "&")
        var h = headers
        h["Content-Type"] = "application/x-www-form-urlencoded; charset=\(encoding)"
        return try await request(url: url, method: "POST", headers: h,
                                 body: body.data(using: .utf8), referer: referer)
    }

    // MARK: 图片

    func imageData(url: String, referer: String? = nil) async throws -> Data {
        let r = try await request(url: url, referer: referer, maxRetry: 2)
        guard !r.data.isEmpty else { throw HTTPError.empty }
        return r.data
    }
}

// MARK: - Content-Type charset 解析

extension String {
    var charsetParam: String? {
        guard let range = self.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let rest = self[range.upperBound...]
        let end = rest.firstIndex(where: { $0 == ";" || $0 == " " }) ?? rest.endIndex
        return String(rest[rest.startIndex..<end]).trimmingCharacters(in: .init(charactersIn: "\"' "))
    }
}

// MARK: - 简易令牌桶限速

actor RateLimiter {
    private var tokens: [String: Double] = [:]
    private var last: [String: Date] = [:]
    /// 每 host 每秒最多 5 个请求
    private let rate = 5.0

    func acquire(host: String) async {
        let now = Date()
        let lastTime = last[host] ?? now
        var bucket = tokens[host] ?? rate
        let elapsed = now.timeIntervalSince(lastTime)
        bucket = min(rate, bucket + elapsed * rate)
        tokens[host] = bucket
        last[host] = now
        if bucket >= 1 {
            tokens[host] = bucket - 1
            return
        }
        let wait = (1 - bucket) / rate
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        tokens[host] = 0
        last[host] = Date()
    }
}
