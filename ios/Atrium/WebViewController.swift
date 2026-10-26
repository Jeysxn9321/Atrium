import UIKit
import WebKit

/// The Atrium page, full screen. The page is the one hosted on GitHub, so every update to it arrives by itself.
/// What the page cannot do, this app does: play a video with VLC's engine (any format, any sound track), and
/// hand links to other apps.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let home = URL(string: "https://jeysxn9321.github.io/Atrium/")!
    static let host = "jeysxn9321.github.io"

    static let okSchemes: Set<String> = ["https", "http", "vlc-x-callback", "infuse", "shareddocuments"]
    private var web: WKWebView!
    private weak var player: PlayerViewController?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1 AtriumApp/1"
        config.userContentController.add(WeakHandler(self), name: "atrium")

        web = WKWebView(frame: .zero, configuration: config)
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = view.backgroundColor
        web.scrollView.backgroundColor = view.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        web.load(URLRequest(url: WebViewController.home))
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // only the Atrium page itself may ask for things, not a frame inside it (a trailer, an ad)
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == WebViewController.host else { return }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "play":
            guard player == nil, let s = body["url"] as? String, let url = URL(string: s), url.scheme == "https" else { return }
            let title = (body["title"] as? String) ?? ""
            let start = (body["start"] as? Double) ?? 0
            let lang = (body["lang"] as? String) ?? "eng"
            let p = PlayerViewController(url: url, title: title, start: start, audioLanguage: lang)
            p.onProgress = { [weak self] pos, dur, ended in
                self?.tell("progress", ["pos": pos, "dur": dur, "ended": ended])
            }
            p.onClose = { [weak self] in self?.tell("closed", [:]) }
            p.modalPresentationStyle = .fullScreen
            player = p
            web.pauseAllMediaPlayback { }
            present(p, animated: true)
        case "open":
            if let s = body["url"] as? String, let url = URL(string: s), Self.okSchemes.contains(url.scheme ?? "") { UIApplication.shared.open(url) }
        default:
            break
        }
    }

    /// Tells the page something happened: window.AtriumNative.<event>(data)
    private func tell(_ event: String, _ data: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: data), let text = String(data: json, encoding: .utf8) else { return }
        let js = "window.AtriumNative && window.AtriumNative.on && window.AtriumNative.on('\(event)', \(text));"
        DispatchQueue.main.async { self.web.evaluateJavaScript(js, completionHandler: nil) }
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme ?? ""
        if scheme == "about" || scheme == "data" || scheme == "blob" { decisionHandler(.allow); return }
        if scheme == "https" || scheme == "http" {
            // Atrium's own address stays here; a link in a frame (a trailer) stays where it is; a link away from Atrium opens in Safari
            if url.host == WebViewController.host || navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // vlc-x-callback:, infuse:, shareddocuments: belong to other apps, and only when a person tapped (main frame)
        if Self.okSchemes.contains(scheme) && navigationAction.targetFrame?.isMainFrame != false { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.host == WebViewController.host { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url == nil { webView.load(URLRequest(url: WebViewController.home)) } else { webView.reload() }
    }
}

/// WKUserContentController keeps its handler alive; this keeps the page's controller from being held by it.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
