import Foundation
import JavaScriptCore
import SwiftSoup

// MARK: - JS 沙箱
//
// Legado 书源里的 JS 规则（@js: / <js> / webJs / loginCheckJs）跑在 Rhino on Android。
// iOS 上改用系统自带 JavaScriptCore，并注入一套兼容层：
//   java.ajax / java.put / java.get / java.log / java.base64Encode / java.md5Encode …
//   org.jsoup.Jsoup.parse(html).select(...)
//   result / baseUrl / key / page / cookie / source / book

struct JSEnv: Sendable {
    var baseUrl: String = ""
    var key: String = ""
    var page: Int = 1
    var sourceJSON: String = "{}"
    var bookJSON: String = "{}"
    var variables: [String: String] = [:]
    var userAgent: String = HTTPClient.defaultUA
}

final class JSEngine: @unchecked Sendable {

    /// 单次执行
    static func run(script: String, html: String?, env: JSEnv,
                    sharedVariables: inout [String: String]) -> String {
        // inout 参数不能进逃逸闭包（@convention(block) 会逃逸到 JSContext），
        // 所以挪进引用盒子，函数退出时写回
        let varBox = SharedVarBox(sharedVariables)
        defer { sharedVariables = varBox.snapshot() }

        guard let context = JSContext() else { return "" }
        context.exceptionHandler = { _, exc in
            if let e = exc?.toString() {
                Task { await LogCenter.shared.append(.error, tag: "JS", e) }
            }
        }

        installShim(into: context)

        // 全局变量
        context.setObject(html ?? "", forKeyedSubscript: "result" as NSString)
        context.setObject(env.baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(env.key, forKeyedSubscript: "key" as NSString)
        context.setObject(env.page, forKeyedSubscript: "page" as NSString)
        context.setObject(env.userAgent, forKeyedSubscript: "userAgent" as NSString)
        context.setObject(env.variables, forKeyedSubscript: "vars" as NSString)

        // source / book
        if let d = try? JSONSerialization.jsonObject(with: Data(env.sourceJSON.utf8)) {
            context.setObject(d, forKeyedSubscript: "source" as NSString)
        }
        if let d = try? JSONSerialization.jsonObject(with: Data(env.bookJSON.utf8)) {
            context.setObject(d, forKeyedSubscript: "book" as NSString)
        }

        // result 可能是 HTML，包装成 jsoup 对象
        if let html, !html.isEmpty {
            let json = DOMSerializer.serializeHTML(html)
            context.setObject(json, forKeyedSubscript: "__domJSON" as NSString)
        }

        // java.put / java.get 回写到 Swift
        let putBlock: @convention(block) (String, String) -> Void = { k, v in
            varBox.set(k, v)
        }
        context.setObject(putBlock, forKeyedSubscript: "__put" as NSString)
        let getBlock: @convention(block) (String) -> String = { k in
            varBox.get(k)
        }
        context.setObject(getBlock, forKeyedSubscript: "__get" as NSString)

        // 同步 ajax 桥
        let ajaxBlock: @convention(block) (String, String, String) -> String = { url, method, body in
            JSEngine.blockingRequest(url: url, method: method, body: body)
        }
        context.setObject(ajaxBlock, forKeyedSubscript: "__ajax" as NSString)

        let logBlock: @convention(block) (String) -> Void = { msg in
            Task { await LogCenter.shared.append(.info, tag: "JS", msg) }
        }
        context.setObject(logBlock, forKeyedSubscript: "__log" as NSString)

        // 编解码工具
        let b64enc: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        context.setObject(b64enc, forKeyedSubscript: "__b64enc" as NSString)
        let b64dec: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        context.setObject(b64dec, forKeyedSubscript: "__b64dec" as NSString)
        let md5Block: @convention(block) (String) -> String = { s in
            InsecureDigest.md5Hex(s)
        }
        context.setObject(md5Block, forKeyedSubscript: "__md5" as NSString)
        let hexBlock: @convention(block) (String) -> String = { s in
            s.utf8.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(hexBlock, forKeyedSubscript: "__hex" as NSString)
        let cookieBlock: @convention(block) (String) -> String = { url in
            guard let u = URL(string: url) else { return "" }
            let sem = DispatchSemaphore(value: 0)
            var out = ""
            Task {
                out = await CookieJar.shared.jsCookieString(for: u)
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            return out
        }
        context.setObject(cookieBlock, forKeyedSubscript: "__cookie" as NSString)

        // 供 JS 侧构造 jsoup 对象
        if let html, !html.isEmpty {
            _ = context.evaluateScript("if (typeof __domJSON !== 'undefined') { result = __wrapDoc(__domJSON); }")
        }

        let wrapped: String
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("return ") && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("function") {
            // 允许直接写 "return xxx" 的片段
            wrapped = "(function(){ \(script) })()"
        } else {
            wrapped = "(function(){ \(script) })()"
        }

        let value = context.evaluateScript(wrapped)
        if let exc = context.exception {
            Task { await LogCenter.shared.append(.error, tag: "JS", "\(exc)") }
            return ""
        }
        if let v = value {
            if v.isString { return v.toString() ?? "" }
            if v.isArray, let arr = v.toArray() as? [Any] {
                return arr.map { JSONPathLite.stringify($0) }.joined(separator: "\n")
            }
            if v.isObject {
                if let json = context.objectForKeyedSubscript("JSON")
                    .invokeMethod("stringify", withArguments: [v]), json.isString {
                    return json.toString() ?? ""
                }
            }
            return v.toString() ?? ""
        }
        // 没有 return 时回落 result
        if let r = context.objectForKeyedSubscript("result"), r.isString {
            return r.toString() ?? ""
        }
        return ""
    }

    // MARK: 同步 HTTP（阻塞当前线程，只在后台执行）

    static func blockingRequest(url: String, method: String = "GET", body: String = "") -> String {
        let sem = DispatchSemaphore(value: 0)
        var out = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let inner = DispatchSemaphore(value: 0)
            Task {
                defer { inner.signal() }
                do {
                    let r = try await HTTPClient.shared.request(
                        url: url,
                        method: method.isEmpty ? "GET" : method,
                        headers: ["Content-Type": "application/x-www-form-urlencoded"],
                        body: body.isEmpty ? nil : body.data(using: .utf8))
                    out = r.text
                } catch {
                    out = ""
                }
            }
            _ = inner.wait(timeout: .now() + 25)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 30)
        return out
    }

    // MARK: 兼容层

    private static func installShim(into ctx: JSContext) {
        ctx.evaluateScript(shimScript)
    }

    static let shimScript = """
    // ===== mini-jsoup =====
    function JX(node, parent) {
      this.n = node; this.parentNode = parent || null;
    }
    JX.prototype._attrs = function() { return this.n.attrs || {}; };
    JX.prototype.tagName = function() { return this.n.tag || ''; };
    JX.prototype.attr = function(k) {
      if (k === undefined) { return this._attrs(); }
      var v = this._attrs()[k];
      return v === undefined || v === null ? '' : String(v);
    };
    JX.prototype.hasAttr = function(k) { return this._attrs()[k] !== undefined; };
    JX.prototype.text = function() {
      var out = [];
      (function walk(n) {
        if (!n) return;
        if (n.text !== undefined) { out.push(n.text); return; }
        var kids = n.children || [];
        for (var i = 0; i < kids.length; i++) walk(kids[i]);
      })(this.n);
      return out.join(' ').replace(/\\s+/g, ' ').trim();
    };
    JX.prototype.ownText = function() {
      var out = [];
      var kids = this.n.children || [];
      for (var i = 0; i < kids.length; i++) if (kids[i].text !== undefined) out.push(kids[i].text);
      return out.join(' ').replace(/\\s+/g, ' ').trim();
    };
    JX.prototype.html = function() { return this.n.html !== undefined ? this.n.html : ''; };
    JX.prototype.outerHtml = function() { return this.n.outer !== undefined ? this.n.outer : ''; };
    JX.prototype.getElementById = function(id) {
      var r = this.select('#' + id); return r.size() ? r.get(0) : null;
    };
    JX.prototype.children = function() {
      var kids = (this.n.children || []).filter(function(c){ return c.tag; });
      return new JXS(kids.map(function(c){ return new JX(c); }, this));
    };
    JX.prototype.nextElementSibling = function() {
      if (!this.parentNode) return null;
      var sibs = this.parentNode.children().all();
      var i = sibs.indexOf(this);
      return i >= 0 && i + 1 < sibs.length ? sibs[i+1] : null;
    };
    JX.prototype.previousElementSibling = function() {
      if (!this.parentNode) return null;
      var sibs = this.parentNode.children().all();
      var i = sibs.indexOf(this);
      return i > 0 ? sibs[i-1] : null;
    };
    JX.prototype.select = function(q) {
      var results = [];
      var self = this;
      var groups = String(q).split(',').map(function(s){ return s.trim(); }).filter(Boolean);
      groups.forEach(function(g) {
        var parts = g.split('\\s+');
        var pool = [self];
        for (var i = 0; i < parts.length; i++) {
          var nxt = [];
          for (var j = 0; j < pool.length; j++) {
            nxt = nxt.concat(matchAll(pool[j].n, parts[i], i === 0 && j === 0 && parts.length === 1 ? self : null));
          }
          pool = nxt.map(function(n){ return new JX(n); });
        }
        results = results.concat(pool);
      });
      return new JXS(results);
    };

    function matchAll(root, selector, ctxRoot) {
      var m = parseSimple(selector);
      var out = [];
      var start = ctxRoot ? [root] : [];
      (function walk(n) {
        if (n.tag) out.push(n);
        (n.children || []).forEach(function(c){ if (c.tag) walk(c); });
      })(root);
      var filtered = out.filter(function(n){ return matchSimple(n, m); });
      if (m.index !== null) {
        filtered = filtered[m.index] ? [filtered[m.index]] : [];
      }
      return filtered;
    }

    function parseSimple(sel) {
      var m = { tag: null, cls: [], id: null, attrs: [], index: null, contains: null, first: false };
      sel = String(sel).trim();
      var im = sel.match(/^(.*?):(eq|nth-child|first|last)\\((\\d+)?\\)$/);
      if (im) {
        sel = im[1];
        if (im[2] === 'eq' || im[2] === 'nth-child') m.index = parseInt(im[3]) - (im[2]==='nth-child'?0:0);
        if (im[2] === 'first') m.index = 0;
      }
      if (/:first$/.test(sel)) { m.index = 0; sel = sel.replace(/:first$/, ''); }
      var cm = sel.match(/:contains\\(['"]?(.*?)['"]?\\)$/);
      if (cm) { m.contains = cm[1]; sel = sel.replace(/:contains\\(.*?\\)$/, ''); }
      var attrRe = /\\[([^\\]=~\\^\\$\\*\\|]+)(?:([~^$*|]?=)['"]?([^\\]'"]*)['"]?)?\\]/g;
      var am;
      while ((am = attrRe.exec(sel)) !== null) {
        m.attrs.push({ name: am[1], op: am[2] || null, value: am[3] || '' });
      }
      sel = sel.replace(/\\[[^\\]]*\\]/g, '');
      var idm = sel.match(/#([A-Za-z0-9_\\-]+)/);
      if (idm) { m.id = idm[1]; sel = sel.replace(/#[A-Za-z0-9_\\-]+/g, ''); }
      var cls = sel.match(/\\.[A-Za-z0-9_\\-]+/g) || [];
      m.cls = cls.map(function(c){ return c.slice(1); });
      sel = sel.replace(/\\.[A-Za-z0-9_\\-]+/g, '');
      var tag = sel.trim();
      if (tag && tag !== '*') m.tag = tag.toLowerCase();
      return m;
    }

    function matchSimple(node, m) {
      if (m.tag && String(node.tag || '').toLowerCase() !== m.tag) return false;
      var attrs = node.attrs || {};
      if (m.id && attrs.id !== m.id) return false;
      if (m.cls.length) {
        var have = String(attrs.class || '').split(/\\s+/);
        for (var i = 0; i < m.cls.length; i++) if (have.indexOf(m.cls[i]) < 0) return false;
      }
      for (var j = 0; j < m.attrs.length; j++) {
        var a = m.attrs[j];
        var v = attrs[a.name];
        if (v === undefined) return false;
        if (a.op === '=' && String(v) !== a.value) return false;
        if (a.op === '*=' && String(v).indexOf(a.value) < 0) return false;
        if (a.op === '^=' && String(v).indexOf(a.value) !== 0) return false;
        if (a.op === '$=' && String(v).slice(-a.value.length) !== a.value) return false;
      }
      if (m.contains) {
        var txt = (new JX(node)).text();
        if (txt.indexOf(m.contains) < 0) return false;
      }
      return true;
    }

    function JXS(arr) { this.arr = arr || []; }
    JXS.prototype.size = function(){ return this.arr.length; };
    JXS.prototype.get = function(i){ return this.arr[i] || null; };
    JXS.prototype.first = function(){ return this.arr[0] || null; };
    JXS.prototype.last = function(){ return this.arr[this.arr.length-1] || null; };
    JXS.prototype.all = function(){ return this.arr; };
    JXS.prototype.text = function(){ return this.arr.map(function(e){ return e.text(); }).join(' ').trim(); };
    JXS.prototype.html = function(){ return this.arr.map(function(e){ return e.html(); }).join('\\n'); };
    JXS.prototype.outerHtml = function(){ return this.arr.map(function(e){ return e.outerHtml(); }).join('\\n'); };
    JXS.prototype.attr = function(k){ return this.arr.length ? this.arr[0].attr(k) : ''; };
    JXS.prototype.eachAttr = function(k){ return this.arr.map(function(e){ return attrOf(e, k); }); };
    JXS.prototype.select = function(q) {
      var out = [];
      this.arr.forEach(function(e){ out = out.concat(e.select(q).all()); });
      return new JXS(out);
    };

    function __wrapDoc(json) {
      var root = new JX(json, null);
      var doc = {
        _root: root,
        select: function(q){ return root.select(q); },
        body: function(){ return root.select('body').first() || root; },
        head: function(){ return root.select('head').first() || root; },
        html: function(){ return json.outer || ''; },
        text: function(){ return root.text(); },
        title: function(){ var t = root.select('title').first(); return t ? t.text() : ''; },
        getAllElements: function(){ return root.select('*'); }
      };
      return doc;
    }

    // ===== java 兼容层 =====
    var __vars = {};
    var java = {
      ajax: function(url) { return __ajax(String(url), 'GET', ''); },
      post: function(url, body, headers) { return __ajax(String(url), 'POST', String(body || '')); },
      get: function(k) { return (typeof __get === 'function') ? __get(String(k)) : (__vars[k] || ''); },
      put: function(k, v) { __vars[k] = v; if (typeof __put === 'function') __put(String(k), String(v)); },
      log: function(m) { if (typeof __log === 'function') __log(String(m)); },
      logType: function(){},
      base64Encode: function(s) { return __b64enc(String(s)); },
      base64Decode: function(s) { return __b64dec(String(s)); },
      md5Encode: function(s) { return __md5(String(s)); },
      md5Encode16: function(s) { return __md5(String(s)).substring(8, 24); },
      hexEncodeToString: function(s) { return __hex(String(s)); },
      timeFormat: function(t) { return new Date(Number(t) || 0).toISOString(); },
      strToBytes: function(s) { return String(s); },
      getCookie: function(u) { return (typeof __cookie === 'function') ? __cookie(String(u)) : ''; },
      connect: function(u) { return { body: function(){ return __ajax(String(u), 'GET', ''); }, cookie: function(){ return java.getCookie(u); } }; }
    };

    var org = {
      jsoup: {
        Jsoup: {
          parse: function(html) {
            var doc = __wrapDoc(__parseDOM(String(html || '')));
            return doc;
          }
        }
      }
    };

    // 用正则把 HTML 粗解析成 DOM JSON（JS 侧兜底，Swift 侧已有更快路径）
    function __parseDOM(html) {
      var root = { tag: 'html', attrs: {}, children: [] };
      var stack = [root];
      var re = /<!--[\\s\\S]*?-->|<(\\/?)([a-zA-Z][a-zA-Z0-9\\-:]*)((?:\\s+[a-zA-Z_:][a-zA-Z0-9_.\\-:]*\\s*=\\s*(?:"[^"]*"|'[^']*'|[^\\s>]+))*)\\s*(\\/?)>|([^<]+)/g;
      var m;
      while ((m = re.exec(html)) !== null) {
        if (m[5] !== undefined) {
          var t = m[5];
          if (t.trim()) stack[stack.length-1].children.push({ text: t });
          continue;
        }
        var closing = m[1] === '/';
        var tag = m[2].toLowerCase();
        if (closing) {
          for (var i = stack.length - 1; i > 0; i--) {
            if (stack[i].tag === tag) { stack.length = i; break; }
          }
          continue;
        }
        var attrs = {};
        var ar = /([a-zA-Z_:][a-zA-Z0-9_.\\-:]*)\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))/g;
        var a;
        while ((a = ar.exec(m[3] || '')) !== null) {
          attrs[a[1]] = a[2] !== undefined ? a[2] : (a[3] !== undefined ? a[3] : a[4]);
        }
        var node = { tag: tag, attrs: attrs, children: [] };
        stack[stack.length-1].children.push(node);
        var voidTags = ['br','img','input','meta','link','hr','area','base','col','embed','param','source','track','wbr'];
        if (!voidTags.includes(tag) && m[4] !== '/') stack.push(node);
      }
      return root;
    }
    """
}

// MARK: - HTML → JSON DOM（Swift 侧，比 JS 侧正则更快也更准确）

enum DOMSerializer {
    static func serializeHTML(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "{}" }
        let obj = node(doc)
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func node(_ n: Node) -> [String: Any] {
        if let e = n as? Element {
            var children: [[String: Any]] = []
            for c in e.getChildNodes() {
                if let tn = c as? TextNode {
                    let t = tn.getWholeText()
                    if !t.isEmpty { children.append(["text": t]) }
                } else if c is Element {
                    children.append(node(c))
                }
            }
            var attrs: [String: String] = [:]
            for a in e.getAttributes()?.asList() ?? [] {
                attrs[a.getKey()] = a.getValue()
            }
            return [
                "tag": tagOf(e).lowercased(),
                "attrs": attrs,
                "children": children,
                "html": (try? e.html()) ?? "",
                "outer": (try? e.outerHtml()) ?? ""
            ]
        }
        return ["text": n.description]
    }
}

// MARK: - JS 共享变量盒子
//
// JSEngine.run 的 sharedVariables 是 inout，而 java.put/java.get 的桥接闭包
// 会被 JSContext 持有（逃逸），Swift 不允许逃逸闭包捕获 inout 参数。
// 用一个加锁的引用类型中转，函数结束时统一写回。

final class SharedVarBox: @unchecked Sendable {
    private var map: [String: String]
    private let lock = NSLock()

    init(_ initial: [String: String]) { map = initial }

    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }

    func get(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return map[key] ?? ""
    }

    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return map
    }
}