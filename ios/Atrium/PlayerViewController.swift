import UIKit
import AVFoundation
import MediaPlayer
import MobileVLCKit

/// Plays one video with VLC's engine: every format, every sound track. It starts on the English sound track (or the
/// language it is told), keeps the screen awake, and tells the page where you are every 20 seconds so Stremio's
/// "Continue watching" follows you to every device.
final class PlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
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
    private let speedButton = UIButton(type: .system)
    private let tableModeButton = UIButton(type: .system)
    private let tablePanel = UIView()
    private let tableAudioButton = UIButton(type: .system)
    private let tableSubtitleButton = UIButton(type: .system)
    private let tableSpeedButton = UIButton(type: .system)
    private let tableFitButton = UIButton(type: .system)
    private let tableBrightness = UISlider()
    private let tableVolume = MPVolumeView()
    private var tableScrollView: UIScrollView?
    private let tablePlay = UIButton(type: .system)
    private let tableProgress = UISlider()
    private let tableElapsed = UILabel()
    private let tableRemaining = UILabel()
    private var videoBottomConstraint: NSLayoutConstraint!
    private var videoTableHeightConstraint: NSLayoutConstraint!
    private var tablePanelTopConstraint: NSLayoutConstraint!
    private var tablePanelBottomConstraint: NSLayoutConstraint!
    private var tabletopMode = false
    private var hingeIsAvailable = false
    private var hingeIsPartiallyOpen = false
    private var hingeRecheck: DispatchWorkItem?
    private let gestureHint = UILabel()
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
    // Fit (the whole picture, subtitles never cut) unless the person chose Fill on this screen shape:
    // the Duo's outer and inner screens, upright or sideways, and tabletop each remember their own choice.
    private var fillChoices: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "atrium.player.fill") as? [String: Bool]) ?? [:]
    private var shownFill: Bool?
    private var screenShape: String {
        if tabletopMode { return "tabletop" }
        let s = videoView.bounds.size
        guard s.width > 0, s.height > 0 else { return "landscape" }
        let r = s.width / s.height
        return r < 1 ? "portrait" : (r >= 1.95 ? "wide" : "landscape")
    }
    private var fill: Bool { fillChoices[screenShape] ?? false }
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var subtitleRel = 16    // VLC's relative subtitle size: 16 is normal, a bigger number is smaller text
    private var nowPlayingAt = Date.distantPast
    private var lastCropGeometry: String?
    private var lastPos = 0.0
    private var startedAt = Date.distantPast
    private let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]
    private var playbackRateIndex = 1
    private var brightnessAtPanStart: CGFloat = 0

    // Subtitles to turn on, in order of preference (a Spanish series: ["eng", "fre"]); empty = off.
    private var subtitleLanguages: [String] = []
    private var pickedSubs = false

    init(url: URL, title: String, start: Double, audioLanguage: String, subtitleLanguages: [String] = []) {
        self.subtitleLanguages = subtitleLanguages.map { $0.lowercased() }.filter { !$0.isEmpty }
        self.url = url
        self.titleText = title
        self.startAt = start
        self.language = audioLanguage.lowercased()
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // iPhone Duo inner displays do not obey a fixed orientation. Adapt to the current
    // window instead of locking it to landscape, and keep portrait available for folding.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestOuterDisplayLandscapeIfNeeded()
        applyFill(force: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Recalculate after any fold, window resize, Split View or rotation.
        titleLabel.isHidden = view.bounds.width < 540
        if tabletopMode { controls.alpha = 0; controls.isUserInteractionEnabled = false }
        applyFill()
        if shownFill != fill { updateFitIcons() }
        if hingeIsAvailable { updateAutomaticTabletop() }
    }

    private func requestOuterDisplayLandscapeIfNeeded() {
        // For the compact outer display, landscape is more comfortable for video.
        // The inner display should resize naturally, without a forced orientation.
        guard traitCollection.horizontalSizeClass == .compact,
              view.bounds.height > view.bounds.width else { return }
        if #available(iOS 16.0, *) {
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                NSLog("Atrium outer display orientation: %@", error.localizedDescription)
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

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
        videoBottomConstraint = videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        videoTableHeightConstraint = videoView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.5)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor), videoBottomConstraint,
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor), videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controls.topAnchor.constraint(equalTo: view.topAnchor), controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor), controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        buildControls()
        buildTabletopControls()
        configureTabletopShortcut()
        installAutomaticTabletopDetection()

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        tap.delegate = self
        double.delegate = self
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(double)
        // A vertical swipe on the left adjusts screen brightness.
        // A horizontal swipe scrubs relative to the current playback position.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(videoPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
        videoView.isUserInteractionEnabled = true

        player.delegate = self
        player.drawable = videoView
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        if startAt > 5 { media.addOption(":start-time=\(Int(startAt))") }   // the player itself starts there: no seek, no jump back to 0
        lastPos = max(0, startAt)
        player.media = media
        player.play()
        applyFill(force: true)
        UIApplication.shared.isIdleTimerDisabled = true

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        setupRemoteCommands()
        updateFitIcons()
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

        for b in [closeButton, audioButton, subtitleButton, fitButton, speedButton, playButton, backButton, forwardButton] {
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
        fitButton.accessibilityLabel = "Toggle full screen video crop"
        fitButton.accessibilityHint = "Switch between filling the screen and showing the whole picture"
        fitButton.addTarget(self, action: #selector(fitTapped), for: .touchUpInside)
        speedButton.setTitle("1×", for: .normal)
        speedButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        speedButton.accessibilityLabel = "Playback speed"
        speedButton.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        tableModeButton.setImage(symbol("rectangle.split.2x1"), for: .normal)
        tableModeButton.accessibilityLabel = "Tabletop mode"
        tableModeButton.addTarget(self, action: #selector(toggleTabletop), for: .touchUpInside)
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
        gestureHint.translatesAutoresizingMaskIntoConstraints = false
        gestureHint.textColor = .white
        gestureHint.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        gestureHint.layer.cornerRadius = 12
        gestureHint.clipsToBounds = true
        gestureHint.textAlignment = .center
        gestureHint.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        gestureHint.isHidden = true
        gestureHint.isUserInteractionEnabled = false
        view.addSubview(gestureHint)

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
            speedButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor), speedButton.trailingAnchor.constraint(equalTo: fitButton.leadingAnchor, constant: -4),
            speedButton.widthAnchor.constraint(equalToConstant: 44), speedButton.heightAnchor.constraint(equalToConstant: 44),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor), subtitleButton.trailingAnchor.constraint(equalTo: speedButton.leadingAnchor, constant: -4),
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
            gestureHint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gestureHint.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            gestureHint.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            gestureHint.heightAnchor.constraint(equalToConstant: 44),
        ])
        view.bringSubviewToFront(messageLabel)
    }

    // MARK: Atrium tabletop player
    private func configureTabletopShortcut() {
        // A persistent entry point, not part of the auto-hiding controls overlay.
        // Without hinge-angle access, the user must be able to reach this button.
        tableModeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableModeButton)
        tableModeButton.backgroundColor = UIColor.black.withAlphaComponent(0.68)
        tableModeButton.layer.cornerRadius = 22
        tableModeButton.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        tableModeButton.layer.borderWidth = 1
        tableModeButton.accessibilityLabel = "Activate Atrium tabletop mode"
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tableModeButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 66),
            tableModeButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            tableModeButton.widthAnchor.constraint(equalToConstant: 48),
            tableModeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    // MARK: iPhone Duo hinge-driven tabletop mode
    // iOS 27.1 exposes the live hinge through UIHingeInteraction. Use hinge
    // status for the posture and the active division region for fold direction.
    // A vertical book fold should NOT enter tabletop: only the horizontal
    // tabletop fold places the video above the lower interactive panel.
    private func installAutomaticTabletopDetection() {
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                guard let hinge = update.hinge else {
                    self.hingeIsAvailable = false
                    self.hingeIsPartiallyOpen = false
                    self.hingeRecheck?.cancel()
                    self.tableModeButton.isHidden = self.tabletopMode
                    return
                }
                self.hingeIsAvailable = true
                self.hingeIsPartiallyOpen = hinge.status == .partiallyOpen
                // On the iPhone Duo we don't display a redundant manual toggle
                // when the automatic hinge listener provides updates.
                self.tableModeButton.isHidden = true
                self.updateAutomaticTabletop()
                // Division geometry can update after the hinge callback.
                self.hingeRecheck?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.updateAutomaticTabletop()
                }
                self.hingeRecheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
            view.addInteraction(interaction)
        }
    }

    private func updateAutomaticTabletop() {
        guard hingeIsAvailable, !closing else { return }
        if #available(iOS 27.1, *) {
            let divisions = view.reservedRegions(kind: .division)
            let horizontalFold = divisions.contains {
                $0.isActive && $0.frame.width > $0.frame.height &&
                $0.frame.width > view.bounds.width * 0.55
            }
            let shouldTabletop = hingeIsPartiallyOpen && horizontalFold
            if shouldTabletop != tabletopMode { setTabletop(shouldTabletop) }
        }
    }

    // Video is in the top half, our own controls in the bottom half.
    // This is a manual mode because public UIKit geometry does not expose a
    // dependable physical hinge angle. It is not VLC's built-in UI.
    private lazy var tabletopHaptic = UIImpactFeedbackGenerator(style: .light)

    @objc private func tabletopTouchDown(_ sender: UIButton) {
        // A subtle physical confirmation, synchronized with the visual press.
        tabletopHaptic.prepare()
        tabletopHaptic.impactOccurred(intensity: 0.85)
        UIView.animate(withDuration: 0.10, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            sender.backgroundColor = UIColor(red: 0.32, green: 0.40, blue: 0.54, alpha: 1)
            sender.layer.borderColor = UIColor.white.withAlphaComponent(0.48).cgColor
            sender.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        }
    }

    @objc private func tabletopTouchUp(_ sender: UIButton) {
        // Let short taps remain visible before the tile gently fades back.
        UIView.animate(withDuration: 0.28, delay: 0.18, options: [.beginFromCurrentState, .allowUserInteraction]) {
            sender.backgroundColor = sender === self.tablePlay
                ? UIColor(red: 0.21, green: 0.24, blue: 0.31, alpha: 1)
                : UIColor(red: 0.15, green: 0.17, blue: 0.22, alpha: 1)
            sender.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
            sender.transform = .identity
        }
    }

    private func buildTabletopControls() {
        // Reference-matched Duo dashboard: video above, dark tiled controls below.
        tablePanel.translatesAutoresizingMaskIntoConstraints = false
        tablePanel.backgroundColor = UIColor(red: 0.105, green: 0.121, blue: 0.158, alpha: 1)
        tablePanel.clipsToBounds = true
        tablePanel.isHidden = true
        view.addSubview(tablePanel)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        tablePanel.addSubview(scroll)
        tableScrollView = scroll
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tablePanel.topAnchor, constant: 3),
            scroll.leadingAnchor.constraint(equalTo: tablePanel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tablePanel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: tablePanel.safeAreaLayoutGuide.bottomAnchor)
        ])

        let tileColor = UIColor(red: 0.15, green: 0.17, blue: 0.22, alpha: 1)
        func tile(_ icon: String, _ label: String, _ action: Selector? = nil) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(symbol(icon, 22), for: .normal)
            b.tintColor = .white
            b.backgroundColor = tileColor
            b.layer.cornerRadius = 4
            b.layer.borderWidth = 0.6
            b.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
            b.accessibilityLabel = label
            if let action { b.addTarget(self, action: action, for: .touchUpInside) }
            return b
        }
        func configureTile(_ b: UIButton, _ label: String) {
            b.tintColor = .white
            b.backgroundColor = tileColor
            b.layer.cornerRadius = 4
            b.layer.borderWidth = 0.6
            b.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
            b.accessibilityLabel = label
        }
        func row(_ views: [UIView], _ height: CGFloat) -> UIStackView {
            let stack = UIStackView(arrangedSubviews: views)
            stack.axis = .horizontal
            stack.spacing = 3
            stack.distribution = .fillEqually
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
            return stack
        }

        let close = tile("xmark", "Close video", #selector(closeTapped))
        let back = tile("gobackward.10", "Back 10 seconds", #selector(backTapped))
        let forward = tile("goforward.10", "Forward 10 seconds", #selector(forwardTapped))
        configureTile(tablePlay, "Play or pause")
        tablePlay.backgroundColor = UIColor(red: 0.21, green: 0.24, blue: 0.31, alpha: 1)
        tablePlay.setImage(symbol("pause.fill", 29), for: .normal)
        tablePlay.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        configureTile(tableAudioButton, "Audio tracks")
        tableAudioButton.setImage(symbol("waveform", 20), for: .normal)
        tableAudioButton.showsMenuAsPrimaryAction = true
        configureTile(tableSubtitleButton, "Subtitles")
        tableSubtitleButton.setImage(symbol("captions.bubble", 20), for: .normal)
        tableSubtitleButton.showsMenuAsPrimaryAction = true
        configureTile(tableSpeedButton, "Playback speed")
        tableSpeedButton.setTitle("1×", for: .normal)
        tableSpeedButton.setTitleColor(.white, for: .normal)
        tableSpeedButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        tableSpeedButton.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        configureTile(tableFitButton, "Fit or fill video")
        tableFitButton.setImage(symbol("arrow.up.left.and.arrow.down.right", 20), for: .normal)
        tableFitButton.addTarget(self, action: #selector(fitTapped), for: .touchUpInside)

        // Highlight every tabletop action, including buttons that open native menus.
        for button in [close, back, forward, tablePlay, tableAudioButton,
                       tableSubtitleButton, tableSpeedButton, tableFitButton] {
            button.addTarget(self, action: #selector(tabletopTouchDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(tabletopTouchUp(_:)),
                             for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        }

        let header = UIView()
        header.backgroundColor = UIColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        let brand = UILabel()
        brand.text = "ATRIUM"
        brand.textColor = UIColor(red: 0.94, green: 0.14, blue: 0.20, alpha: 1)
        brand.font = .systemFont(ofSize: 10, weight: .heavy)
        let name = UILabel()
        name.text = titleText
        name.textColor = UIColor.white.withAlphaComponent(0.88)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let headerRow = UIStackView(arrangedSubviews: [brand, name])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.axis = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .center
        header.addSubview(headerRow)
        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 48),
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            headerRow.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        // Match the reference: large central transport tile, compact adjacent controls.
        let first = row([close, tableAudioButton, tablePlay, tableSubtitleButton, tableSpeedButton], 58)
        let second = row([back, tableFitButton, forward], 48)

        tableProgress.minimumValue = 0
        tableProgress.maximumValue = 1
        tableProgress.minimumTrackTintColor = UIColor(red: 0.94, green: 0.15, blue: 0.20, alpha: 1)
        tableProgress.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
        tableProgress.transform = CGAffineTransform(scaleX: 1, y: 0.72)
        tableProgress.accessibilityLabel = "Playback progress"
        tableProgress.addTarget(self, action: #selector(tableScrubStarted), for: .touchDown)
        tableProgress.addTarget(self, action: #selector(tableScrubMoved), for: .valueChanged)
        tableProgress.addTarget(self, action: #selector(tableScrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        for label in [tableElapsed, tableRemaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = UIColor.white.withAlphaComponent(0.8)
            label.text = "0:00"
        }
        tableRemaining.textAlignment = .right
        tableElapsed.widthAnchor.constraint(equalToConstant: 45).isActive = true
        tableRemaining.widthAnchor.constraint(equalToConstant: 50).isActive = true
        let progressRow = UIStackView(arrangedSubviews: [tableElapsed, tableProgress, tableRemaining])
        progressRow.axis = .horizontal
        progressRow.spacing = 8
        progressRow.alignment = .center
        progressRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 29).isActive = true

        tableBrightness.minimumValue = 0.05
        tableBrightness.maximumValue = 1
        tableBrightness.value = Float(UIScreen.main.brightness)
        tableBrightness.minimumTrackTintColor = .white
        tableBrightness.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        tableBrightness.transform = CGAffineTransform(scaleX: 1, y: 0.80)
        tableBrightness.accessibilityLabel = "Screen brightness"
        tableBrightness.addTarget(self, action: #selector(tableBrightnessChanged), for: .valueChanged)
        tableVolume.showsVolumeSlider = true
        tableVolume.showsRouteButton = false
        tableVolume.tintColor = .white
        tableVolume.accessibilityLabel = "System volume"
        // MPVolumeView uses a private system slider: match its track/thumb appearance
        // only where UIKit exposes the underlying UISlider, without replacing volume APIs.
        for child in tableVolume.subviews {
            if let volumeSlider = child as? UISlider {
                volumeSlider.minimumTrackTintColor = .white
                volumeSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
                volumeSlider.transform = CGAffineTransform(scaleX: 1, y: 0.80)
            }
        }
        func sliderTile(_ icon: String, _ control: UIView) -> UIView {
            let box = UIView()
            box.backgroundColor = tileColor
            box.layer.cornerRadius = 4
            let symbolView = UIImageView(image: symbol(icon, 17))
            symbolView.tintColor = .white
            symbolView.contentMode = .scaleAspectFit
            symbolView.translatesAutoresizingMaskIntoConstraints = false
            control.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(symbolView)
            box.addSubview(control)
            NSLayoutConstraint.activate([
                symbolView.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
                symbolView.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                symbolView.widthAnchor.constraint(equalToConstant: 22),
                control.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 7),
                control.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                // MPVolumeView positions its internal slider above its own center.
                // Compensate so volume and brightness tracks share one baseline.
                control.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: control is MPVolumeView ? 5 : 0),
                control.heightAnchor.constraint(equalToConstant: 36)
            ])
            return box
        }
        let levels = row([sliderTile("sun.max", tableBrightness), sliderTile("speaker.wave.2", tableVolume)], 46)
        let stack = UIStackView(arrangedSubviews: [header, first, second, progressRow, levels])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 3
        stack.distribution = .equalSpacing
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -5),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -10),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor, constant: -16)
        ])
        // Fill the full lower half instead of leaving a large unused area.
        // Proportional heights adapt to the Duo's actual fold/window size;
        // minimum touch heights remain enforced for compact windows.
        for (section, fraction) in [(header, CGFloat(0.09)),
                                    (first, CGFloat(0.25)),
                                    (second, CGFloat(0.20)),
                                    (progressRow, CGFloat(0.10)),
                                    (levels, CGFloat(0.23))] {
            let proportional = section.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, multiplier: fraction)
            proportional.priority = UILayoutPriority(750)
            proportional.isActive = true
        }
        // Smaller thumb for the seek bar; keep the full slider touch area.
        let thumbSize = CGSize(width: 14, height: 14)
        let thumb = UIGraphicsImageRenderer(size: thumbSize).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: thumbSize))
        }
        tableProgress.setThumbImage(thumb, for: .normal)
        tableProgress.setThumbImage(thumb, for: .highlighted)
        tableBrightness.setThumbImage(thumb, for: .normal)
        tableBrightness.setThumbImage(thumb, for: .highlighted)
        for child in tableVolume.subviews {
            if let volumeSlider = child as? UISlider {
                volumeSlider.setThumbImage(thumb, for: .normal)
                volumeSlider.setThumbImage(thumb, for: .highlighted)
            }
        }

        tablePanelTopConstraint = tablePanel.topAnchor.constraint(equalTo: videoView.bottomAnchor)
        tablePanelBottomConstraint = tablePanel.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            tablePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tablePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        updateTabletopMediaMenus()
    }

    @objc private func tableBrightnessChanged() {
        (view.window?.screen ?? UIScreen.main).brightness = CGFloat(tableBrightness.value)
    }

    private func updateTabletopMediaMenus() {
        // Reuse the same checked actions and VLC track indexes as fullscreen.
        tableAudioButton.menu = audioButton.menu
        tableSubtitleButton.menu = subtitleButton.menu
        tableAudioButton.isEnabled = !(audioButton.menu?.children.isEmpty ?? true)
        tableSubtitleButton.isEnabled = !(subtitleButton.menu?.children.isEmpty ?? true)
        tableAudioButton.alpha = tableAudioButton.isEnabled ? 1 : 0.4
        tableSubtitleButton.alpha = tableSubtitleButton.isEnabled ? 1 : 0.4
    }

    @objc private func toggleTabletop() {
        // Backup manual toggle only applies when the hinge API isn't available.
        guard !hingeIsAvailable else { return }
        setTabletop(!tabletopMode)
    }

    private func setTabletop(_ enable: Bool) {
        guard enable != tabletopMode else { return }
        hideWork?.cancel()
        // Resolve the previous geometry before animating to the new fold layout.
        view.layoutIfNeeded()
        // Deactivate all constraints from the old mode before activating the new ones.
        // Otherwise Auto Layout may break the video height constraint when the
        // invisible lower control panel still requires a non-zero height.
        if enable {
            videoBottomConstraint.isActive = false
            videoTableHeightConstraint.isActive = true
            tablePanelTopConstraint.isActive = true
            tablePanelBottomConstraint.isActive = true
        } else {
            tablePanelTopConstraint.isActive = false
            tablePanelBottomConstraint.isActive = false
            videoTableHeightConstraint.isActive = false
            videoBottomConstraint.isActive = true
        }
        tabletopMode = enable
        // Keep the panel in the hierarchy during the fold animation to avoid a
        // one-frame flash or jump when switching between player layouts.
        if enable {
            tablePanel.alpha = 0
            tablePanel.isHidden = false
        }
        tableModeButton.isHidden = hingeIsAvailable || enable
        if enable {
            tableBrightness.value = Float(view.window?.screen.brightness ?? UIScreen.main.brightness)
            updateTabletopMediaMenus()
        }
        controls.alpha = enable ? 0 : 1
        controls.isUserInteractionEnabled = !enable
        // Apply the intended video crop immediately, rather than after the
        // animation, so playback does not visibly snap at the end.
        applyFill(force: true)
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.26, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) {
            self.tablePanel.alpha = enable ? 1 : 0
            self.view.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self else { return }
            self.tablePanel.isHidden = !self.tabletopMode
            self.tablePanel.alpha = self.tabletopMode ? 1 : 0
            self.applyFill(force: true)
        }
        if !enable { showControls() }
    }

    @objc private func tableScrubStarted() { scrubbing = true; hideWork?.cancel() }
    @objc private func tableScrubMoved() {
        let duration = lengthSeconds()
        tableElapsed.text = clock(Double(tableProgress.value) * duration)
        tableRemaining.text = duration > 0 ? "-" + clock(duration * (1 - Double(tableProgress.value))) : "--:--"
    }
    @objc private func tableScrubEnded() {
        if lengthSeconds() > 0 { player.position = tableProgress.value }
        scrubbing = false
    }

    @objc private func showSystemVolume() {
        showGestureHint("Use iPhone volume buttons")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.gestureHint.isHidden = true }
    }

    @objc private func showBrightnessHint() {
        showGestureHint("Swipe up/down on video left side")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.gestureHint.isHidden = true }
    }

    // MARK: showing and hiding the controls

    @objc private func toggleControls() {
        if controls.alpha > 0.5 { hideControls() } else { showControls() }
    }

    private func showControls() {
        if tabletopMode { return }
        controls.isUserInteractionEnabled = true
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
        if tabletopMode { return }
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 } completion: { finished in
            if finished && self.controls.alpha < 0.5 { self.controls.isUserInteractionEnabled = false }
        }
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        let x = g.location(in: view).x
        if x < view.bounds.width / 2 { player.jumpBackward(10) } else { player.jumpForward(10) }
        showControls()
    }

    // Protect all Atrium buttons, sliders and menus from the fullscreen overlay gestures.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current: UIView? = touch.view
        while let v = current {
            if v is UIControl { return false }
            current = v.superview
        }
        return true
    }

    // MARK: adaptive gestures
    // UIKit reports the actual active window size even after folding/rotation.
    // This intentionally does not infer hinge angle or ambient light.
    @objc private func videoPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        let velocity = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            brightnessAtPanStart = view.window?.screen.brightness ?? UIScreen.main.brightness
        case .changed:
            let height = max(1, view.bounds.height)
            let width = max(1, view.bounds.width)
            if abs(velocity.y) > abs(velocity.x), point.x < width * 0.5 {
                let newValue = max(0.05, min(1, brightnessAtPanStart - velocity.y / height))
                (view.window?.screen ?? UIScreen.main).brightness = newValue
                showGestureHint("Brightness \(Int(newValue * 100))%")
            } else if abs(velocity.x) > abs(velocity.y), abs(velocity.x) > 20 {
                let seconds = Int((velocity.x / width * 90).rounded())
                showGestureHint(seconds >= 0 ? "+\(seconds)s" : "\(seconds)s")
            }
        case .ended:
            let width = max(1, view.bounds.width)
            if abs(velocity.x) > abs(velocity.y), abs(velocity.x) > 35 {
                let seconds = Int((velocity.x / width * 90).rounded())
                if seconds > 0 { player.jumpForward(Int32(seconds)) }
                if seconds < 0 { player.jumpBackward(Int32(-seconds)) }
            }
            gestureHint.isHidden = true
            showControls()
        case .cancelled, .failed:
            gestureHint.isHidden = true
        default: break
        }
    }

    private func showGestureHint(_ text: String) {
        gestureHint.text = text
        gestureHint.isHidden = false
    }

    @objc private func speedTapped() {
        playbackRateIndex = (playbackRateIndex + 1) % playbackRates.count
        let rate = playbackRates[playbackRateIndex]
        player.rate = rate
        let speedLabel = rate == 1 ? "1×" : String(format: "%.2g×", rate)
        speedButton.setTitle(speedLabel, for: .normal)
        tableSpeedButton.setTitle(speedLabel, for: .normal)
        speedButton.accessibilityValue = "\(rate) times"
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
        fillChoices[screenShape] = !fill
        UserDefaults.standard.set(fillChoices, forKey: "atrium.player.fill")
        applyFill(force: true)
        updateFitIcons()
        showControls()
    }

    // VLC renders into the whole view. In Fill mode the video is cropped, never stretched.
    // Use the current drawable size, not UIScreen.main (ambiguous on iPhone Duo).
    private func applyFill(force: Bool = false) {
        let size = videoView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        applySubtitleSize()
        if !fill {
            if force || lastCropGeometry != nil {
                player.videoCropGeometry = nil
                player.scaleFactor = 0
                lastCropGeometry = nil
            }
            return
        }
        let scale = traitCollection.displayScale
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return }
        let crop = "\(width):\(height)"
        guard force || crop != lastCropGeometry else { return }
        crop.withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) }
        lastCropGeometry = crop
    }

    // Fill enlarges the picture, and the subtitles drawn on it with it. In Fill the subtitles are made smaller
    // by the same amount, so they keep the size they have in Fit; in Fit they are VLC's normal size.
    private func applySubtitleSize() {
        var rel = 16
        let s = videoView.bounds.size
        if fill, s.width > 0, s.height > 0 {
            var videoAspect: CGFloat = 16.0 / 9.0
            let v = player.videoSize
            if v.width > 0, v.height > 0 { videoAspect = v.width / v.height }
            let screenAspect = s.width / s.height
            let zoom = max(screenAspect / videoAspect, videoAspect / screenAspect)
            rel = min(40, max(16, Int((16 * zoom).rounded())))
        }
        guard rel != subtitleRel else { return }
        subtitleRel = rel
        let set = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: set) { _ = player.perform(set, with: NSNumber(value: rel)) }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.applyFill(force: true) }
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

    private func updateFitIcons() {
        let f = fill
        shownFill = f
        fitButton.setImage(symbol(f ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), for: .normal)
        fitButton.accessibilityValue = f ? "Fill screen" : "Fit full image"
        tableFitButton.setImage(symbol(f ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", 20), for: .normal)
        tableFitButton.accessibilityValue = f ? "Fill screen" : "Fit full image"
    }

    // MARK: Control Center, lock screen, headphones and CarPlay buttons

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ act: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            cmd.isEnabled = true
            remoteTargets.append((cmd, cmd.addTarget(handler: act)))
        }
        on(c.playCommand) { [weak self] _ in self?.player.play(); self?.remoteChanged(); return .success }
        on(c.pauseCommand) { [weak self] _ in self?.player.pause(); self?.remoteChanged(); return .success }
        on(c.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.player.isPlaying { self.player.pause() } else { self.player.play() }
            self.remoteChanged(); return .success
        }
        c.skipForwardCommand.preferredIntervals = [10]
        c.skipBackwardCommand.preferredIntervals = [10]
        on(c.skipForwardCommand) { [weak self] _ in self?.player.jumpForward(10); self?.remoteChanged(); return .success }
        on(c.skipBackwardCommand) { [weak self] _ in self?.player.jumpBackward(10); self?.remoteChanged(); return .success }
        on(c.changePlaybackPositionCommand) { [weak self] e in
            guard let self, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.player.time = VLCTime(int: Int32(max(0, e.positionTime) * 1000))
            self.remoteChanged(); return .success
        }
    }
    private func remoteChanged() {
        DispatchQueue.main.async { [weak self] in self?.updatePlayIcon(); self?.updateNowPlaying() }
    }
    private func updateNowPlaying() {
        guard !closing else { return }
        nowPlayingAt = Date()
        var info: [String: Any] = [MPMediaItemPropertyTitle: titleText, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds(),
                                   MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0.0]
        let len = lengthSeconds()
        if len > 0 { info[MPMediaItemPropertyPlaybackDuration] = len }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func clearRemoteCommands() {
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updatePlayIcon() {
        playButton.setImage(symbol(player.isPlaying ? "pause.fill" : "play.fill", 40), for: .normal)
        tablePlay.setImage(symbol(player.isPlaying ? "pause.fill" : "play.fill", 30), for: .normal)
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
        if Date().timeIntervalSince(nowPlayingAt) > 5 { updateNowPlaying() }
        let len = lengthSeconds(), pos = positionSeconds()
        if !scrubbing {
            slider.value = len > 0 ? Float(min(1, pos / len)) : 0
            elapsedLabel.text = clock(pos)
            remainingLabel.text = len > 0 ? "-" + clock(max(0, len - pos)) : "--:--"
        }
        if tabletopMode && !scrubbing {
            tableProgress.value = len > 0 ? Float(min(1, pos / len)) : 0
            tableElapsed.text = clock(pos)
            tableRemaining.text = len > 0 ? "-" + clock(max(0, len - pos)) : "--:--"
        }
        updatePlayIcon()
        // VLC can report .buffering even after decoded frames start advancing.
        // Clear the startup overlay as soon as playback makes measurable progress.
        if pos > 0.15 && player.isPlaying && !started {
            started = true
            startedAt = Date()
            lastSent = Date()
            applyFill(force: true)
        }
        if started && !(messageLabel.text ?? "").isEmpty && player.state != .error {
            messageLabel.text = ""
        }
        if started && pos > 1 { lastPos = pos }
        if started && (!pickedAudio || (!pickedSubs && !subtitleLanguages.isEmpty)) && Date().timeIntervalSince(startedAt) < 12 && Date().timeIntervalSince(startedAt) > 1 { pickLanguage(); pickSubtitles(); rebuildMenus() }
        if started && player.isPlaying && Date().timeIntervalSince(lastSent) > 20 { send(ended: false) }
    }

    private func send(ended: Bool) {
        lastSent = Date()
        guard started else { return }
        let pos = positionSeconds()
        onProgress?(pos > 1 ? pos : lastPos, lengthSeconds(), ended)
    }

    // MARK: sound tracks and subtitles

    private func pickLanguage() {
        guard !pickedAudio, let names = player.audioTrackNames as? [String], let ids = player.audioTrackIndexes as? [NSNumber], names.count == ids.count, names.count > 1 else { return }
        pickedAudio = true
        let wanted: [String]
        switch language {
        case "fre", "fra", "fr": wanted = ["french", "français", "[fr", " fre", "fra"]
        case "spa", "es": wanted = ["spanish", "español", "espanol", "castellano", "castilian", "[es", " spa"]
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

    private static func words(for code: String) -> [String] {
        switch code {
        case "fre", "fra", "fr": return ["french", "français", "francais", "[fr", " fre", "fra"]
        case "spa", "es": return ["spanish", "español", "espanol", "castellano", "[es", " spa"]
        default: return ["english", "[en", " eng"]
        }
    }
    // The first wanted subtitle language that the file has (forced or signs-only tracks last).
    private func pickSubtitles() {
        guard !pickedSubs, !subtitleLanguages.isEmpty,
              let names = player.videoSubTitlesNames as? [String], let ids = player.videoSubTitlesIndexes as? [NSNumber],
              names.count == ids.count, names.count > 1 else { return }
        pickedSubs = true
        for code in subtitleLanguages {
            let wanted = Self.words(for: code)
            let matches = names.indices.filter { i in ids[i].int32Value >= 0 && wanted.contains(where: { names[i].lowercased().contains($0) }) }
            let dialogue = matches.first { i in let n = names[i].lowercased(); return !n.contains("forced") && !n.contains("sign") }
            if let i = dialogue ?? matches.first {
                player.currentVideoSubTitleIndex = ids[i].int32Value
                return
            }
        }
    }

    private func rebuildMenus() {
        var audio: [UIAction] = []
        if let names = player.audioTrackNames as? [String], let ids = player.audioTrackIndexes as? [NSNumber], names.count == ids.count {
            for (i, n) in names.enumerated() {
                let id = ids[i].int32Value
                if id < 0 { continue }
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
        updateTabletopMediaMenus()
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
                    self.startedAt = Date()
                    self.applyFill(force: true)
                    self.lastSent = Date()   // the first report comes 20 s in, after the resume point has landed
                    self.player.currentVideoSubTitleIndex = -1
                }
                // the tracks are known a moment after playing starts
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.pickLanguage()
                    self?.pickSubtitles()
                    self?.rebuildMenus()
                }
            case .buffering:
                if !self.started { self.messageLabel.text = "Loading…" }
            case .paused:
                self.send(ended: false)
            case .ended, .stopped:
                if self.started {
                    let len = self.lengthSeconds()
                    let real = self.player.state == .ended && len > 0 && self.lastPos > len - 120
                    self.finish(ended: real)
                }
            case .error:
                self.messageLabel.text = "This version could not be played.\nClose and pick another version."
                self.showControls()
            default:
                break
            }
            self.updatePlayIcon()
            self.updateNowPlaying()
        }
    }

    // MARK: leaving

    private func finish(ended: Bool) {
        guard !closing else { return }
        closing = true
        ticker?.invalidate()
        hideWork?.cancel()
        hingeRecheck?.cancel()
        if started {
            let pos = positionSeconds()
            onProgress?(pos > 1 ? pos : lastPos, lengthSeconds(), ended)
        }
        clearRemoteCommands()
        player.delegate = nil
        let p = player
        DispatchQueue.global().async { p.stop() }   // a stalled stream must not freeze the screen
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        (presentingViewController ?? self).dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
}
