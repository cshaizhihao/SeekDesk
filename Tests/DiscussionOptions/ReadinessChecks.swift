import AppKit
import Foundation
import WebKit

// Only URL helpers used by the unrelated publish-response DTO are supplied.
// The production read script and diagnostic types compile unmodified.
enum Forum {
    static let home = URL(string: "https://www.nodeseek.com/")!
    static func topicID(_ url: URL) -> String? { nil }
    static func pageURL(_ url: URL) -> URL { url }
}

@MainActor
private final class ReadPage: NSObject, WKNavigationDelegate {
    let view: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }
    func options(_ html: String, base: URL = DiscussionScript.page,
                 timeout: Duration = .seconds(2)) async throws -> DiscussionOptions {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            loaded = waiter
            // No external resources or requests. The synthetic document is
            // same-origin only so the production URL guard is exercised too.
            view.loadHTMLString("<!doctype html><meta charset=utf-8><script>window.fetch = () => { throw Error('Network forbidden'); };</script>" + html,
                                baseURL: base)
        }
        return try await DiscussionScript.readOptions(timeout: timeout) {
            let raw = try await view.callAsyncJavaScript(DiscussionScript.options, arguments: [:], in: nil, contentWorld: .page)
            guard let raw = raw as? String else { preconditionFailure("Missing read result") }
            return try JSONDecoder().decode(DiscussionOptions.self, from: Data(raw.utf8))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume(); loaded = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }
}

@main
struct DiscussionReadinessChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let user = "<script>window.__config__={user:{rank:4}};</script>"
        let editor = "<div id=editor></div>"
        let category = "<select id=category><option value=''>Choose</option><option value=tech> Tech </option><option value=inside disabled>Inside</option><option value='../bad'>Unsafe</option></select>"

        let ready = try await ReadPage().options(user + editor + category)
        precondition(ready.kind == "ready" && ready.categories?.map(\.id) == ["tech"] && ready.maxRank == 4 && ready.reason == nil)
        print("PASS immediately usable form, disabled/invalid category filtering and rank")

        let namedSelect = try await ReadPage().options(user + editor + #"""
        <select name=category>
          <optgroup label=Unavailable disabled><option value=inside>Inside</option></optgroup>
          <option value=tech>Tech</option>
        </select>
        """#)
        precondition(namedSelect.kind == "ready" && namedSelect.categories?.map(\.id) == ["tech"])
        print("PASS category select identified by form field name; disabled groups excluded")

        let delayed = try await ReadPage().options(#"""
        <div id=nsk-head></div>
        <script>
        window.__config__ = {};
        setTimeout(() => { window.__config__.user = {rank:3}; }, 100);
        setTimeout(() => { const e=document.createElement('div'); e.id='editor'; document.body.append(e); }, 200);
        setTimeout(() => { const e=document.createElement('select'); e.id='category'; document.body.append(e); }, 300);
        setTimeout(() => { document.querySelector('#category').innerHTML='<option value="tech">Tech</option>'; }, 500);
        </script>
        """#)
        precondition(delayed.kind == "ready" && delayed.maxRank == 3 && delayed.categories?.map(\.id) == ["tech"])
        print("PASS header-first page waits for staged config, editor, select and options mounts")

        let delayedEditor = try await ReadPage().options(user + category + #"""
        <script>setTimeout(() => { const e=document.createElement('div'); e.id='editor'; document.body.append(e); }, 200);</script>
        """#)
        precondition(delayedEditor.kind == "ready")
        print("PASS editor mounted after config/category no longer fails early")

        for (html, reason) in [
            ("<script>window.__config__={};</script>" + editor + category, "configurationMissing"),
            (user + category, "editorMissing"),
            (user + editor, "categoryMissing"),
            (user + editor + "<select id=category><option value=tech disabled>Denied</option><option value='../private'>Invalid</option></select>", "categoriesUnavailable"),
        ] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await ReadPage().options(html)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            precondition(result.kind == "unavailable" && result.reason == reason && result.categories == nil)
            precondition(elapsed >= 1.9 && elapsed < 8, "Missing form data must finish after a finite readiness wait: \(reason), \(elapsed)s")
            precondition(!result.failureMessage.isEmpty && !result.failureMessage.contains("private"))
            print("PASS bounded missing-state diagnostic \(reason)")
        }

        let signedOut = try await ReadPage().options("<script>window.__config__={user:null};</script>")
        precondition(signedOut.kind == "signedOut")
        let login = try await ReadPage().options("", base: Forum.home.appendingPathComponent("signIn.html"))
        precondition(login.kind == "signedOut")
        let wrongPage = try await ReadPage().options(user + editor + category, base: Forum.home)
        precondition(wrongPage.kind == "unavailable" && wrongPage.reason == "unexpectedPage")
        let guestRedirect = try await ReadPage().options("<script>window.__config__={user:null};</script>", base: Forum.home)
        precondition(guestRedirect.kind == "signedOut")
        let wrongOrigin = try await ReadPage().options(user + editor + category, base: URL(string: "https://example.invalid/new-discussion")!)
        precondition(wrongOrigin.kind == "unavailable" && wrongOrigin.reason == "unexpectedOrigin")
        let unknown = try JSONDecoder().decode(DiscussionOptions.self, from: Data(#"{"kind":"unavailable","reason":"private-content-token"}"#.utf8))
        precondition(unknown.failureMessage == DiscussionReadIssue.unavailable.message)
        print("PASS signed-out and wrong-page/origin remain rejected; unknown diagnostics cannot echo page content")
        print("All discussion readiness checks passed with generated local HTML, no site requests or user data.")
    }
}
