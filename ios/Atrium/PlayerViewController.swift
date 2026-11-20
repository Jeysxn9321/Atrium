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
    private var fill = true
    private var lastCropGeometry: String?
    private var lastPos = 0.0
    private var startedAt = Date.distantPast
    private let playbackRates: [Float] = [0.75, 1, 1.25, 1.5, 2]
    private var playbackRateIndex = 1
    private var brightnessAtPanStart: CGFloat = 0

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
    private func buildTabletopControls() {
        tablePanel.translatesAutoresizingMaskIntoConstraints = false
        tablePanel.backgroundColor = UIColor(red: 0.115, green: 0.128, blue: 0.171, alpha: 1)
        tablePanel.layer.cornerRadius = 22
        tablePanel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        tablePanel.clipsToBounds = true
        tablePanel.isHidden = true
        view.addSubview(tablePanel)

        // Scrollable content prevents controls disappearing on shorter Duo windows,
        // Split View or when accessibility text sizes increase.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        tablePanel.addSubview(scroll)
        tableScrollView = scroll
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tablePanel.safeAreaLayoutGuide.topAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: tablePanel.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tablePanel.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: tablePanel.safeAreaLayoutGuide.bottomAnchor, constant: -5)
        ])

        func button(_ icon: String, _ label: String, _ action: Selector? = nil) -> UIButton {
            let b = UIButton(type: .system)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setImage(symbol(icon, 22), for: .normal)
            b.tintColor = .white
            b.accessibilityLabel = label
            b.backgroundColor = UIColor.white.withAlphaComponent(0.075)
            b.layer.cornerRadius = 12
            if let action = action { b.addTarget(self, action: action, for: .touchUpInside) }
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            return b
        }

        let exit = button("xmark", "Close video", #selector(closeTapped))
        let expand = button("arrow.up.left.and.arrow.down.right", "Return to fullscreen", #selector(toggleTabletop))
        let headerTitle = UILabel()
        headerTitle.text = titleText
        headerTitle.textColor = .white
        headerTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.numberOfLines = 1
        headerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tableAudioButton.setImage(symbol("waveform", 21), for: .normal)
        tableAudioButton.accessibilityLabel = "Audio tracks"
        tableAudioButton.tintColor = .white
        tableAudioButton.showsMenuAsPrimaryAction = true
        tableAudioButton.backgroundColor = UIColor.white.withAlphaComponent(0.075)
        tableAudioButton.layer.cornerRadius = 12
        tableSubtitleButton.setImage(symbol("captions.bubble", 21), for: .normal)
        tableSubtitleButton.accessibilityLabel = "Subtitles"
        tableSubtitleButton.tintColor = .white
        tableSubtitleButton.showsMenuAsPrimaryAction = true
        tableSubtitleButton.backgroundColor = UIColor.white.withAlphaComponent(0.075)
        tableSubtitleButton.layer.cornerRadius = 12
        for b in [exit, tableAudioButton, tableSubtitleButton, expand] {
            b.widthAnchor.constraint(equalToConstant: 44).isActive = true
            b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let header = UIStackView(arrangedSubviews: [exit, headerTitle, tableAudioButton, tableSubtitleButton, expand])
        header.axis = .horizontal
        header.spacing = 7
        header.alignment = .center
        header.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let brand = UILabel()
        brand.text = "ATRIUM"
        brand.textColor = UIColor(red: 0.94, green: 0.12, blue: 0.17, alpha: 1)
        brand.font = .systemFont(ofSize: 11, weight: .heavy)
        brand.textAlignment = .center
        brand.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let rewind = button("gobackward.10", "Back 10 seconds", #selector(backTapped))
        let advance = button("goforward.10", "Forward 10 seconds", #selector(forwardTapped))
        for b in [rewind, advance] {
            b.widthAnchor.constraint(equalToConstant: 65).isActive = true
            b.heightAnchor.constraint(equalToConstant: 54).isActive = true
        }
        tablePlay.setImage(symbol("pause.fill", 29), for: .normal)
        tablePlay.tintColor = .white
        tablePlay.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        tablePlay.layer.cornerRadius = 15
        tablePlay.accessibilityLabel = "Pause or resume"
        tablePlay.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        tablePlay.widthAnchor.constraint(equalToConstant: 82).isActive = true
        tablePlay.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let transport = UIStackView(arrangedSubviews: [rewind, tablePlay, advance])
        transport.axis = .horizontal
        transport.alignment = .center
        transport.distribution = .equalCentering
        transport.spacing = 20
        transport.heightAnchor.constraint(equalToConstant: 57).isActive = true

        tableProgress.minimumValue = 0
        tableProgress.maximumValue = 1
        tableProgress.minimumTrackTintColor = UIColor(red: 0.95, green: 0.12, blue: 0.20, alpha: 1)
        tableProgress.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
        tableProgress.accessibilityLabel = "Playback progress"
        tableProgress.addTarget(self, action: #selector(tableScrubStarted), for: .touchDown)
        tableProgress.addTarget(self, action: #selector(tableScrubMoved), for: .valueChanged)
        tableProgress.addTarget(self, action: #selector(tableScrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        for label in [tableElapsed, tableRemaining] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white.withAlphaComponent(0.9)
            label.text = "0:00"
        }
        tableRemaining.textAlignment = .right
        tableElapsed.widthAnchor.constraint(equalToConstant: 47).isActive = true
        tableRemaining.widthAnchor.constraint(equalToConstant: 51).isActive = true
        let timeline = UIStackView(arrangedSubviews: [tableElapsed, tableProgress, tableRemaining])
        timeline.axis = .horizontal
        timeline.spacing = 9
        timeline.alignment = .center
        timeline.heightAnchor.constraint(equalToConstant: 30).isActive = true

        // Actual on-screen controls, not buttons that merely show instructions.
        // MPVolumeView sends volume changes through iOS' authorized system UI.
        let volumeIcon = UIImageView(image: symbol("speaker.wave.2", 17))
        volumeIcon.tintColor = .white
        volumeIcon.contentMode = .scaleAspectFit
        volumeIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        tableVolume.showsVolumeSlider = true
        tableVolume.showsRouteButton = false
        tableVolume.tintColor = .white
        tableVolume.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tableVolume.accessibilityLabel = "System volume"
        let volRow = UIStackView(arrangedSubviews: [volumeIcon, tableVolume])
        volRow.axis = .horizontal
        volRow.spacing = 10
        volRow.alignment = .center
        let volBox = UIView()
        volRow.translatesAutoresizingMaskIntoConstraints = false
        volBox.addSubview(volRow)
        NSLayoutConstraint.activate([
            volRow.leadingAnchor.constraint(equalTo: volBox.leadingAnchor, constant: 10),
            volRow.trailingAnchor.constraint(equalTo: volBox.trailingAnchor, constant: -10),
            volRow.topAnchor.constraint(equalTo: volBox.topAnchor),
            volRow.bottomAnchor.constraint(equalTo: volBox.bottomAnchor)
        ])

        let lightIcon = UIImageView(image: symbol("sun.max", 18))
        lightIcon.tintColor = .white
        lightIcon.contentMode = .scaleAspectFit
        lightIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        tableBrightness.minimumValue = 0.05
        tableBrightness.maximumValue = 1
        tableBrightness.value = Float(view.window?.screen.brightness ?? UIScreen.main.brightness)
        tableBrightness.minimumTrackTintColor = .white
        tableBrightness.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        tableBrightness.accessibilityLabel = "Screen brightness"
        tableBrightness.addTarget(self, action: #selector(tableBrightnessChanged), for: .valueChanged)
        let brightRow = UIStackView(arrangedSubviews: [lightIcon, tableBrightness])
        brightRow.axis = .horizontal
        brightRow.spacing = 10
        brightRow.alignment = .center
        let brightBox = UIView()
        brightRow.translatesAutoresizingMaskIntoConstraints = false
        brightBox.addSubview(brightRow)
        NSLayoutConstraint.activate([
            brightRow.leadingAnchor.constraint(equalTo: brightBox.leadingAnchor, constant: 10),
            brightRow.trailingAnchor.constraint(equalTo: brightBox.trailingAnchor, constant: -10),
            brightRow.topAnchor.constraint(equalTo: brightBox.topAnchor),
            brightRow.bottomAnchor.constraint(equalTo: brightBox.bottomAnchor)
        ])

        let levels = UIStackView(arrangedSubviews: [brightBox, volBox])
        levels.axis = .horizontal
        levels.distribution = .fillEqually
        levels.spacing = 10
        levels.heightAnchor.constraint(equalToConstant: 42).isActive = true

        tableSpeedButton.setTitle("1×", for: .normal)
        tableSpeedButton.setTitleColor(.white, for: .normal)
        tableSpeedButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        tableSpeedButton.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        tableSpeedButton.layer.cornerRadius = 12
        tableSpeedButton.accessibilityLabel = "Playback speed"
        tableSpeedButton.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        tableFitButton.setImage(symbol("arrow.up.left.and.arrow.down.right", 20), for: .normal)
        tableFitButton.tintColor = .white
        tableFitButton.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        tableFitButton.layer.cornerRadius = 12
        tableFitButton.accessibilityLabel = "Fit or fill video"
        tableFitButton.addTarget(self, action: #selector(fitTapped), for: .touchUpInside)
        let tools = UIStackView(arrangedSubviews: [tableSpeedButton, tableFitButton])
        tools.axis = .horizontal
        tools.distribution = .fillEqually
        tools.spacing = 12
        tools.heightAnchor.constraint(equalToConstant: 42).isActive = true

        let stack = UIStackView(arrangedSubviews: [header, brand, transport, timeline, levels, tools])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 7
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        // Only activate these anchors after entering tabletop mode. Fullscreen's
        // video-bottom constraint must not compete with the panel's intrinsic height.
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
        tablePanel.isHidden = !enable
        tableModeButton.isHidden = hingeIsAvailable || enable
        if enable {
            tableBrightness.value = Float(view.window?.screen.brightness ?? UIScreen.main.brightness)
            updateTabletopMediaMenus()
        }
        controls.alpha = enable ? 0 : 1
        controls.isUserInteractionEnabled = !enable
        fill = !enable
        view.setNeedsLayout()
        view.layoutIfNeeded()
        applyFill(force: true)
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
        fill.toggle()
        applyFill(force: true)
        fitButton.setImage(symbol(fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), for: .normal)
        fitButton.accessibilityValue = fill ? "Fill screen" : "Fit full image"
        tableFitButton.setImage(symbol(fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", 20), for: .normal)
        tableFitButton.accessibilityValue = fill ? "Fill screen" : "Fit full image"
        showControls()
    }

    // VLC renders into the whole view. In Fill mode the video is cropped, never stretched.
    // Use the current drawable size, not UIScreen.main (ambiguous on iPhone Duo).
    private func applyFill(force: Bool = false) {
        let size = videoView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
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
        if started && !pickedAudio && Date().timeIntervalSince(startedAt) < 12 && Date().timeIntervalSince(startedAt) > 1 { pickLanguage(); rebuildMenus() }
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
        player.delegate = nil
        let p = player
        DispatchQueue.global().async { p.stop() }   // a stalled stream must not freeze the screen
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        (presentingViewController ?? self).dismiss(animated: true) { [weak self] in self?.onClose?() }
    }
}
