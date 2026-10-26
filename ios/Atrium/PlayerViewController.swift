import UIKit
import AVFoundation
import MobileVLCKit

/// Plays one video with VLC's engine: every format, every sound track. It starts on the English sound track (or the
/// language it is told), keeps the screen awake, and tells the page where you are every 20 seconds so Stremio's
/// "Continue watching" follows you to every device.
final class PlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    var onProgress: ((Double, Double, Bool) -> Void)?   // position and length in seconds, and whether it ended
    var onClose: (() -> Void)?

    private let url: URL
    private let titleText: String
    private let startAt: Double
    private let language: String

    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let controls = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let fitButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()

    private var ticker: Timer?
    private var hideWork: DispatchWorkItem?
    private var scrubbing = false
    private var started = false
    private var pickedAudio = false
    private var closing = false
    private var lastSent = Date.distantPast
    private var fill = false

    init(url: URL, title: String, start: Double, audioLanguage: String) {
        self.url = url
        self.titleText = title
        self.startAt = start
        self.language = audioLanguage.lowercased()
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    // MARK: setup

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor), videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor), videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor), controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor), controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        buildControls()

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(double)

        player.delegate = self
        player.drawable = videoView
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        player.media = media
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        showControls()
    }

    private func symbol(_ name: String, _ size: CGFloat = 22) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    private func buildControls() {
        let shade = UIView()
        shade.translatesAutoresizingMaskIntoConstraints = false
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        shade.isUserInteractionEnabled = false
        controls.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.topAnchor.constraint(equalTo: controls.topAnchor), shade.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
            shade.leadingAnchor.constraint(equalTo: controls.leadingAnchor), shade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
        ])

        for b in [closeButton, audioButton, subtitleButton, fitButton, playButton, backButton, forwardButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.tintColor = .white
            controls.addSubview(b)
        }
        closeButton.setImage(symbol("xmark"), for: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        audioButton.setImage(symbol("waveform"), for: .normal)
        audioButton.showsMenuAsPrimaryAction = true
        subtitleButton.setImage(symbol("captions.bubble"), for: .normal)
        subtitleButton.showsMenuAsPrimaryAction = true
        fitButton.setImage(symbol("arrow.up.left.and.arrow.down.right"), for: .normal)
        fitButton.addTarget(self, action: #selector(fitTapped), for: .touchUpInside)
        playButton.setImage(symbol("pause.fill", 40), for: .normal)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        backButton.setImage(symbol("gobackward.10", 30), for: .normal)
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        forwardButton.setImage(symbol("goforward.10", 30), for: .normal)
        forwardButton.addTarget(self, action: #selector(forwardTapped), for: .touchUpInside)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = titleText
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        controls.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.text = "Loading…"
        view.addSubview(messageLabel)

        for l in [elapsedLabel, remainingLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.textColor = .white
            l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            l.text = "0:00"
            controls.addSubview(l)
        }
        remainingLabel.textAlignment = .right
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumTrackTintColor = UIColor(red: 0.9, green: 0.04, blue: 0.08, alpha: 1)
        slider.addTarget(self, action: #selector(scrubStarted), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        controls.addSubview(slider)

        let g = controls.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: g.topAnchor, constant: 12), closeButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44), closeButton.heightAnchor.constraint(equalToConstant: 44),
            fitButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor), fitButton.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            fitButton.widthAnchor.constraint(equalToConstant: 44), fitButton.heightAnchor.constraint(equalToConstant: 44),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor), subtitleButton.trailingAnchor.constraint(equalTo: fitButton.leadingAnchor, constant: -4),
            subtitleButton.widthAnchor.constraint(equalToConstant: 44), subtitleButton.heightAnchor.constraint(equalToConstant: 44),
            audioButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor), audioButton.trailingAnchor.constraint(equalTo: subtitleButton.leadingAnchor, constant: -4),
            audioButton.widthAnchor.constraint(equalToConstant: 44), audioButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor), titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -8),

            playButton.centerXAnchor.constraint(equalTo: controls.centerXAnchor), playButton.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 72), playButton.heightAnchor.constraint(equalToConstant: 72),
            backButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor), backButton.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -28),
            backButton.widthAnchor.constraint(equalToConstant: 56), backButton.heightAnchor.constraint(equalToConstant: 56),
            forwardButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor), forwardButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 28),
            forwardButton.widthAnchor.constraint(equalToConstant: 56), forwardButton.heightAnchor.constraint(equalToConstant: 56),

            slider.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 64), slider.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -64),
            slider.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -22),
            elapsedLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor), elapsedLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            elapsedLabel.widthAnchor.constraint(equalToConstant: 44),
            remainingLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor), remainingLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            remainingLabel.widthAnchor.constraint(equalToConstant: 48),

            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor), messageLabel.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 24),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32), messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        view.bringSubviewToFront(messageLabel)
    }

    // MARK: showing and hiding the controls

    @objc private func toggleControls() {
        if controls.alpha > 0.5 { hideControls() } else { showControls() }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.player.isPlaying, !self.scrubbing else { return }
            self.hideControls()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideControls() {
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x
        if x < view.bounds.width / 2 { player.jumpBackward(10) } else { player.jumpForward(10) }
        showControls()
    }

    // MARK: buttons

    @objc private func closeTapped() { finish(ended: false) }
    @objc private func playTapped() {
        if player.isPlaying { player.pause() } else { player.play() }
        updatePlayIcon(); showControls()
    }
    @objc private func backTapped() { player.jumpBackward(10); showControls() }
    @objc private func forwardTapped() { player.jumpForward(10); showControls() }
    @objc private func fitTapped() {
        fill.toggle()
        // fill the screen (the edges are cropped) or fit the whole picture
        if fill {
            let size = view.bounds.size
            player.videoCropGeometry = nil
            player.scaleFactor = 0
            player.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (String(format: "%d:%d", Int(size.width), Int(size.height)) as NSString).utf8String)
        } else {
            player.videoAspectRatio = nil
            player.scaleFactor = 0
        }
        showControls()
    }
    @objc private func scrubStarted() { scrubbing = true; hideWork?.cancel() }
    @objc private func scrubMoved() {
        let len = lengthSeconds()
        elapsedLabel.text = clock(Double(slider.value) * len)
        remainingLabel.text = "-" + clock(max(0, len - Double(slider.value) * len))
    }
    @objc private func scrubEnded() {
        player.position = slider.value
        scrubbing = false
        showControls()
    }

    private func updatePlayIcon() {
        playButton.setImage(symbol(player.isPlaying ? "pause.fill" : "play.fill", 40), for: .normal)
    }

    // MARK: time

    private func positionSeconds() -> Double { Double(player.time.intValue) / 1000 }
    private func lengthSeconds() -> Double {
        if let m = player.media { let v = Double(m.length.intValue) / 1000; if v > 0 { return v } }
        return 0
    }

    private func clock(_ s: Double) -> String {
        let t = Int(max(0, s)), h = t / 3600, m = (t % 3600) / 60, x = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }

    private func tick() {
        guard !closing else { return }
        let len = lengthSeconds(), pos = positionSeconds()
        if !scrubbing {
            slider.value = len > 0 ? Float(min(1, pos / len)) : 0
            elapsedLabel.text = clock(pos)
            remainingLabel.text = len > 0 ? "-" + clock(max(0, len - pos)) : "--:--"
        }
        updatePlayIcon()
        if started && player.isPlaying && Date().timeIntervalSince(lastSent) > 20 { send(ended: false) }
    }

    private func send(ended: Bool) {
        lastSent = Date()
        guard started else { return }
        onProgress?(positionSeconds(), lengthSeconds(), ended)
    }

    // MARK: sound tracks and subtitles

    private func pickLanguage() {
        guard !pickedAudio, let names = player.audioTrackNames as? [String], let ids = player.audioTrackIndexes as? [NSNumber], names.count == ids.count, names.count > 1 else { return }
        pickedAudio = true
        let wanted: [String]
        switch language {
        case "fre", "fra", "fr": wanted = ["french", "français", "[fr", " fre", "fra"]
        case "spa", "es": wanted = ["spanish", "español", "[es", " spa"]
        case "jpn", "ja": wanted = ["japanese", "日本語", "[ja", " jpn"]
        default: wanted = ["english", "[en", " eng"]
        }
        for (i, n) in names.enumerated() {
            let low = n.lowercased()
            if wanted.contains(where: { low.contains($0) }) {
                player.currentAudioTrackIndex = ids[i].int32Value
                break
            }
        }
    }

    private func rebuildMenus() {
        var audio: [UIAction] = []
        if let names = player.audioTrackNames as? [String], let ids = player.audioTrackIndexes as? [NSNumber], names.count == ids.count {
            for (i, n) in names.enumerated() {
                let id = ids[i].int32Value
                audio.append(UIAction(title: n, state: id == player.currentAudioTrackIndex ? .on : .off) { [weak self] _ in
                    self?.player.currentAudioTrackIndex = id
                    self?.rebuildMenus()
                })
            }
        }
        audioButton.menu = UIMenu(title: "Sound", children: audio)
        audioButton.isHidden = audio.count < 2

        var subs: [UIAction] = []
        if let names = player.videoSubTitlesNames as? [String], let ids = player.videoSubTitlesIndexes as? [NSNumber], names.count == ids.count {
            for (i, n) in names.enumerated() {
                let id = ids[i].int32Value
                subs.append(UIAction(title: n, state: id == player.currentVideoSubTitleIndex ? .on : .off) { [weak self] _ in
                    self?.player.currentVideoSubTitleIndex = id
                    self?.rebuildMenus()
                })
            }
        }
        subtitleButton.menu = UIMenu(title: "Subtitles", children: subs)
        subtitleButton.isHidden = subs.count < 2
    }

    // MARK: VLC

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.closing else { return }
            switch self.player.state {
            case .playing:
                self.messageLabel.text = ""
                if !self.started {
                    self.started = true
                    if self.startAt > 5 { self.player.time = VLCTime(int: Int32(self.startAt * 1000)) }
                    self.player.currentVideoSubTitleIndex = -1
                }
                // the tracks are known a moment after playing starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.pickLanguage()
                    self?.rebuildMenus()
                }
            case .buffering:
                if !self.started { self.messageLabel.text = "Loading…" }
            case .paused:
                self.send(ended: false)
            case .ended, .stopped:
                if self.started { self.finish(ended: true) }
            case .error:
                self.messageLabel.text = "This version could not be played.\nClose and pick another version."
                self.showControls()
            default:
                break
            }
            self.updatePlayIcon()
        }
    }

    // MARK: leaving

    private func finish(ended: Bool) {
        guard !closing else { return }
        closing = true
        ticker?.invalidate()
        hideWork?.cancel()
        if started { onProgress?(positionSeconds(), lengthSeconds(), ended) }
        player.delegate = nil
        player.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
}
