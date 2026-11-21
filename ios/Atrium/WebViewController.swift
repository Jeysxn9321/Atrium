import UIKit
import WebKit
import AVFoundation
import WidgetKit

/// The Atrium page, full screen. The page is the one hosted on GitHub, so every update to it arrives by itself.
/// What the page cannot do, this app does: play a video with VLC's engine (any format, any sound track), and
/// hand links to other apps.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let home = URL(string: "https://jeysxn9321.github.io/Atrium/")!
    static let host = "jeysxn9321.github.io"

    static let okSchemes: Set<String> = ["https", "http", "vlc-x-callback", "infuse", "shareddocuments"]
    private var web: WKWebView!
    private weak var player: PlayerViewController?
    private var startupAudioPlayed = false
    private var startupAudioEngine: AVAudioEngine?
    private var startupAudioNode: AVAudioPlayerNode?
    private var preparedStartupBuffer: AVAudioPCMBuffer?
    private let startupAudioQueue = DispatchQueue(label: "atrium.intro.audio", qos: .userInitiated)

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
        prepareStartupAudio()
        web.load(URLRequest(url: WebViewController.home))
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // only the Atrium page itself may ask for things, not a frame inside it (a trailer, an ad)
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == WebViewController.host else { return }
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "widgets":
            if let snapshot = body["snapshot"] as? [String: Any],
               JSONSerialization.isValidJSONObject(snapshot),
               let data = try? JSONSerialization.data(withJSONObject: snapshot),
               data.count < 200_000 {
                UserDefaults(suiteName: "group.app.atrium.widgets")?.set(data, forKey: "snapshot")
                WidgetCenter.shared.reloadAllTimelines()
            }
        case "play":
            guard player == nil, let s = body["url"] as? String, let url = URL(string: s), url.scheme == "https" else { return }
            let title = (body["title"] as? String) ?? ""
            let start = (body["start"] as? Double) ?? 0
            let lang = (body["lang"] as? String) ?? "eng"
            let store = UserDefaults(suiteName: "group.app.atrium.widgets")
            var snapshot = store?.data(forKey: "snapshot").flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            } ?? [:]
            snapshot["nowPlaying"] = ["id": url.absoluteString, "title": title, "subtitle": "Playing in Atrium"]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) {
                store?.set(data, forKey: "snapshot")
                WidgetCenter.shared.reloadAllTimelines()
            }
            let p = PlayerViewController(url: url, title: title, start: start, audioLanguage: lang)
            p.onProgress = { [weak self] pos, dur, ended in
                self?.tell("progress", ["pos": pos, "dur": dur, "ended": ended])
            }
            p.onClose = { [weak self] in
                self?.tell("closed", [:])
                if let store = UserDefaults(suiteName: "group.app.atrium.widgets"),
                   let data = store.data(forKey: "snapshot"),
                   var snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    snapshot.removeValue(forKey: "nowPlaying")
                    if let updated = try? JSONSerialization.data(withJSONObject: snapshot) {
                        store.set(updated, forKey: "snapshot")
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
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

    // MARK: native intro sound
    // This original sonic logo is synthesized locally: there is no audio file
    // in the Web app. Native playback avoids WebKit's autoplay restrictions.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !startupAudioPlayed,
              webView.url?.host == Self.host else { return }
        startupAudioPlayed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.playStartupSound()
        }
    }

    // Generate the 1.5-second sonic logo off the main thread. WebKit is
    // simultaneously decoding and painting its opening frames; synthesis on
    // the main queue previously caused visible startup frame drops.
    private func prepareStartupAudio() {
        startupAudioQueue.async { [weak self] in
            let sampleRate: Double = 44_100
            let duration: Double = 1.5
            let count = AVAudioFrameCount(sampleRate * duration)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
                  let channels = buffer.floatChannelData else { return }
            buffer.frameLength = count
            for frame in 0..<Int(count) {
                let t = Double(frame) / sampleRate
                let attack = min(1.0, t / 0.055)
                let release = min(1.0, max(0.0, (duration - t) / 0.5))
                let envelope = attack * release
                let low = sin(2 * .pi * 220 * t) * exp(-3.5 * t)
                let midTime = max(0, t - 0.27)
                let mid = (t >= 0.27 ? sin(2 * .pi * 329.63 * midTime) * exp(-2.5 * midTime) : 0)
                let highTime = max(0, t - 0.54)
                let high = (t >= 0.54 ? sin(2 * .pi * 440 * highTime) * exp(-2.3 * highTime) : 0)
                let shimmer = sin(2 * .pi * 880 * t) * 0.07 * exp(-3 * t)
                let sample = Float((low * 0.19 + mid * 0.15 + high * 0.13 + shimmer) * envelope)
                for channel in 0..<Int(format.channelCount) { channels[channel][frame] = sample }
            }
            DispatchQueue.main.async { [weak self] in
                self?.preparedStartupBuffer = buffer
            }
        }
    }

    private func playStartupSound() {
        // Never generate thousands of samples during the first WebKit paint.
        // If preparation is not complete, defer playback until it is ready.
        guard let buffer = preparedStartupBuffer else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.playStartupSound()
            }
            return
        }
        preparedStartupBuffer = nil
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            startupAudioEngine = engine
            startupAudioNode = node
            node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async {
                    self?.startupAudioNode?.stop()
                    self?.startupAudioEngine?.stop()
                    self?.startupAudioNode = nil
                    self?.startupAudioEngine = nil
                }
            }
            node.play()
        } catch {
            NSLog("Atrium startup sound unavailable: %@", error.localizedDescription)
            engine.stop()
            startupAudioEngine = nil
            startupAudioNode = nil
        }
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
