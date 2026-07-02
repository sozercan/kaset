import AppKit
import SwiftUI

// MARK: - QueueCellActions

struct QueueCellActions {
    let onPlay: () -> Void
    let onRemove: () -> Void
    let onToggleLike: () -> Void
    let allowsLikeAction: Bool
    let isLiked: Bool
}

// MARK: - QueueTableCellView

class QueueTableCellView: NSView {
    private static let horizontalPadding: CGFloat = 12
    private static let columnSpacing: CGFloat = 12
    private static let indicatorWidth: CGFloat = 24
    private static let thumbnailSize: CGFloat = 40
    private static let explicitBadgeSize: CGFloat = 12
    private static let likeButtonSize: CGFloat = 22
    private static let durationWidth: CGFloat = 36

    private var onPlay: (() -> Void)?
    private var onRemove: (() -> Void)?
    private var isCurrentTrack: Bool = false
    private var isPlaying: Bool = false
    private let indicatorContainer = NSView()
    private let indicatorLabel = NSTextField()
    private var waveformView: NSView?
    private let thumbnailImageView = NSImageView()
    private var imageLoadTask: Task<Void, Never>?
    private var currentSongId: String?
    private let infoStackView = NSStackView()
    private let titleLabel = NSTextField()
    private let artistLabel = NSTextField()
    private let durationLabel = NSTextField()
    private let explicitBadge = NSTextField()
    private let likeButton = NSButton()
    private var onToggleLikeAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupView()
    }

    private func setupView() {
        self.wantsLayer = true
        self.clipsToBounds = true
        self.autoresizingMask = [.width, .height]

        self.indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.indicatorContainer)

        self.indicatorLabel.isEditable = false
        self.indicatorLabel.isBordered = false
        self.indicatorLabel.backgroundColor = .clear
        self.indicatorLabel.alignment = .center
        self.indicatorLabel.font = NSFont.systemFont(ofSize: 12)
        self.indicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        self.indicatorContainer.addSubview(self.indicatorLabel)

        self.thumbnailImageView.wantsLayer = true
        self.thumbnailImageView.layer?.cornerRadius = 4
        self.thumbnailImageView.layer?.masksToBounds = true
        self.thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        self.thumbnailImageView.setContentHuggingPriority(.required, for: .horizontal)
        self.thumbnailImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.addSubview(self.thumbnailImageView)

        self.infoStackView.orientation = .vertical
        self.infoStackView.spacing = 2
        self.infoStackView.alignment = .leading
        self.infoStackView.translatesAutoresizingMaskIntoConstraints = false
        self.infoStackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.infoStackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.addSubview(self.infoStackView)

        self.titleLabel.isEditable = false
        self.titleLabel.isBordered = false
        self.titleLabel.backgroundColor = .clear
        self.titleLabel.lineBreakMode = .byTruncatingTail
        self.titleLabel.cell?.truncatesLastVisibleLine = true
        self.titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        self.artistLabel.isEditable = false
        self.artistLabel.isBordered = false
        self.artistLabel.backgroundColor = .clear
        self.artistLabel.lineBreakMode = .byTruncatingTail
        self.artistLabel.cell?.truncatesLastVisibleLine = true
        self.artistLabel.font = NSFont.systemFont(ofSize: 11)
        self.artistLabel.textColor = NSColor.secondaryLabelColor
        self.artistLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        self.infoStackView.addArrangedSubview(self.titleLabel)
        self.infoStackView.addArrangedSubview(self.artistLabel)

        self.configureExplicitBadge()
        self.configureLikeButton()
        self.configureDurationLabel()
        self.addSubview(self.explicitBadge)
        self.addSubview(self.likeButton)
        self.addSubview(self.durationLabel)

        NSLayoutConstraint.activate([
            self.indicatorContainer.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Self.horizontalPadding),
            self.indicatorContainer.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.indicatorContainer.widthAnchor.constraint(equalToConstant: Self.indicatorWidth),
            self.indicatorContainer.heightAnchor.constraint(equalToConstant: 20),

            self.indicatorLabel.centerXAnchor.constraint(equalTo: self.indicatorContainer.centerXAnchor),
            self.indicatorLabel.centerYAnchor.constraint(equalTo: self.indicatorContainer.centerYAnchor),

            self.thumbnailImageView.leadingAnchor.constraint(
                equalTo: self.indicatorContainer.trailingAnchor,
                constant: Self.columnSpacing
            ),
            self.thumbnailImageView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.thumbnailImageView.widthAnchor.constraint(equalToConstant: Self.thumbnailSize),
            self.thumbnailImageView.heightAnchor.constraint(equalToConstant: Self.thumbnailSize),

            self.durationLabel.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Self.horizontalPadding),
            self.durationLabel.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.durationLabel.widthAnchor.constraint(equalToConstant: Self.durationWidth),

            self.likeButton.trailingAnchor.constraint(equalTo: self.durationLabel.leadingAnchor, constant: -8),
            self.likeButton.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.likeButton.widthAnchor.constraint(equalToConstant: Self.likeButtonSize),
            self.likeButton.heightAnchor.constraint(equalToConstant: Self.likeButtonSize),

            self.explicitBadge.trailingAnchor.constraint(equalTo: self.likeButton.leadingAnchor, constant: -8),
            self.explicitBadge.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.explicitBadge.widthAnchor.constraint(equalToConstant: Self.explicitBadgeSize),
            self.explicitBadge.heightAnchor.constraint(equalToConstant: Self.explicitBadgeSize),

            self.infoStackView.leadingAnchor.constraint(
                equalTo: self.thumbnailImageView.trailingAnchor,
                constant: Self.columnSpacing
            ),
            self.infoStackView.trailingAnchor.constraint(equalTo: self.explicitBadge.leadingAnchor, constant: -8),
            self.infoStackView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(self.handleClick(_:)))
        self.addGestureRecognizer(clickGesture)
    }

    /// Explicit "E" badge — placed inline at the trailing edge of the title row.
    /// Hidden by default; toggled in configure(...) based on song.isExplicit.
    private func configureExplicitBadge() {
        self.explicitBadge.isEditable = false
        self.explicitBadge.isBordered = false
        self.explicitBadge.alignment = .center
        self.explicitBadge.stringValue = "E"
        self.explicitBadge.font = NSFont.systemFont(ofSize: 8, weight: .semibold)
        self.explicitBadge.textColor = NSColor.windowBackgroundColor
        self.explicitBadge.backgroundColor = NSColor.secondaryLabelColor
        self.explicitBadge.drawsBackground = true
        self.explicitBadge.wantsLayer = true
        self.explicitBadge.layer?.cornerRadius = 2.5
        self.explicitBadge.layer?.masksToBounds = true
        self.explicitBadge.translatesAutoresizingMaskIntoConstraints = false
        self.explicitBadge.setAccessibilityLabel("Explicit")
        self.explicitBadge.alphaValue = 0
    }

    /// Like (thumbs-up) button — always visible; opacity reflects state.
    private func configureLikeButton() {
        self.likeButton.bezelStyle = .accessoryBar
        self.likeButton.isBordered = false
        self.likeButton.setButtonType(.momentaryChange)
        self.likeButton.imagePosition = .imageOnly
        self.likeButton.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: "Like")
        self.likeButton.target = self
        self.likeButton.action = #selector(self.handleLikeClick)
        self.likeButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureDurationLabel() {
        self.durationLabel.isEditable = false
        self.durationLabel.isBordered = false
        self.durationLabel.backgroundColor = .clear
        self.durationLabel.alignment = .right
        self.durationLabel.font = NSFont.systemFont(ofSize: 11)
        self.durationLabel.textColor = NSColor.tertiaryLabelColor
        self.durationLabel.translatesAutoresizingMaskIntoConstraints = false
        self.durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.durationLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    override func layout() {
        super.layout()
        guard let rowView = self.superview, !rowView.bounds.isEmpty else { return }

        var frame = rowView.bounds
        frame.origin = .zero
        if self.frame != frame {
            self.frame = frame
        }
    }

    func configure(song: Song, index: Int, isCurrentTrack: Bool, isPlaying: Bool, actions: QueueCellActions) {
        self.onPlay = actions.onPlay
        self.onRemove = actions.onRemove
        self.onToggleLikeAction = actions.onToggleLike
        self.likeButton.isEnabled = actions.allowsLikeAction
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying
        self.updateAppearance(isCurrentTrack: isCurrentTrack, isPlaying: isPlaying, index: index)

        let isExplicit = song.isExplicit ?? false
        self.explicitBadge.alphaValue = isExplicit ? 1 : 0

        self.updateLikeState(isLiked: actions.isLiked)

        self.titleLabel.stringValue = song.title
        self.titleLabel.font = NSFont.systemFont(ofSize: 13, weight: isCurrentTrack ? .semibold : .regular)
        self.titleLabel.textColor = isCurrentTrack ? NSColor.systemRed : NSColor.labelColor

        self.artistLabel.stringValue = song.artistsDisplay.isEmpty ? "Unknown Artist" : song.artistsDisplay

        if let duration = song.duration {
            let mins = Int(duration) / 60
            let secs = Int(duration) % 60
            self.durationLabel.stringValue = String(format: "%d:%02d", mins, secs)
        } else {
            self.durationLabel.stringValue = ""
        }

        let songId = song.id
        self.currentSongId = songId
        self.imageLoadTask?.cancel()
        let primaryURL = song.thumbnailURL?.highQualityThumbnailURL
        let fallbackURL = song.fallbackThumbnailURL
        self.imageLoadTask = Task { [weak self] in
            let targetSize = CGSize(width: 40, height: 40)
            var image: NSImage?
            if let primaryURL {
                image = await ImageCache.shared.image(for: primaryURL, targetSize: targetSize)
            }
            if image == nil, let fallbackURL {
                image = await ImageCache.shared.image(for: fallbackURL, targetSize: targetSize)
            }
            guard !Task.isCancelled, self?.currentSongId == songId else { return }
            self?.thumbnailImageView.image = image
        }
    }

    func updateLikeState(isLiked: Bool) {
        let likeIconName = isLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
        let likeDescription = isLiked
            ? String(localized: "Unlike")
            : String(localized: "Like")
        self.likeButton.image = NSImage(systemSymbolName: likeIconName, accessibilityDescription: likeDescription)
        self.likeButton.contentTintColor = isLiked ? NSColor.systemRed : NSColor.tertiaryLabelColor
        self.likeButton.alphaValue = !self.likeButton.isEnabled ? 0 : (isLiked ? 1.0 : 0.55)
        self.likeButton.toolTip = likeDescription
        self.likeButton.setAccessibilityLabel(likeDescription)
    }

    func updateAppearance(isCurrentTrack: Bool, isPlaying: Bool, index: Int) {
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying

        if isCurrentTrack {
            self.indicatorLabel.stringValue = ""
            self.indicatorLabel.isHidden = true

            if self.waveformView == nil {
                let waveView = WaveformView(frame: NSRect(x: 0, y: 0, width: 24, height: 16))
                waveView.translatesAutoresizingMaskIntoConstraints = false
                self.waveformView = waveView
                self.indicatorContainer.addSubview(waveView)
                NSLayoutConstraint.activate([
                    waveView.centerXAnchor.constraint(equalTo: self.indicatorContainer.centerXAnchor),
                    waveView.centerYAnchor.constraint(equalTo: self.indicatorContainer.centerYAnchor),
                    waveView.widthAnchor.constraint(equalToConstant: 24),
                    waveView.heightAnchor.constraint(equalToConstant: 16),
                ])
            }

            if let waveView = self.waveformView as? WaveformView {
                waveView.isHidden = false
                waveView.isAnimating = isPlaying
                waveView.tintColor = isPlaying ? NSColor.systemRed : NSColor.tertiaryLabelColor
            }

            self.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        } else {
            self.indicatorLabel.isHidden = false
            self.indicatorLabel.stringValue = "\(index + 1)"
            self.indicatorLabel.textColor = NSColor.tertiaryLabelColor
            self.waveformView?.isHidden = true
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        let clickLocation = recognizer.location(in: self)
        let likeButtonLocation = self.likeButton.convert(clickLocation, from: self)
        guard !self.likeButton.bounds.contains(likeButtonLocation) else { return }

        self.onPlay?()
    }

    @objc private func handleLikeClick() {
        self.onToggleLikeAction?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil
        self.currentSongId = nil
        self.thumbnailImageView.image = nil
        self.waveformView?.removeFromSuperview()
        self.waveformView = nil
        self.onToggleLikeAction = nil
        self.explicitBadge.alphaValue = 0
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - WaveformView

class WaveformView: NSView {
    var isAnimating: Bool = false {
        didSet {
            self.updateAnimation()
        }
    }

    var tintColor: NSColor = .systemRed {
        didSet {
            self.layer?.sublayers?.forEach { $0.backgroundColor = self.tintColor.cgColor }
        }
    }

    private var timer: Timer?
    private var bars: [CALayer] = []
    private var startTime: CFTimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupBars()
    }

    private func setupBars() {
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor

        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 2
        let totalWidth = CGFloat(3) * barWidth + CGFloat(2) * barSpacing
        let startX = (self.bounds.width - totalWidth) / 2

        for i in 0 ..< 3 {
            let bar = CALayer()
            bar.backgroundColor = self.tintColor.cgColor
            bar.cornerRadius = 1
            bar.frame = NSRect(
                x: startX + CGFloat(i) * (barWidth + barSpacing),
                y: self.bounds.height / 2 - 4,
                width: barWidth,
                height: 8
            )
            self.layer?.addSublayer(bar)
            self.bars.append(bar)
        }
    }

    private func updateAnimation() {
        if self.isAnimating {
            self.startAnimation()
        } else {
            self.stopAnimation()
            for bar in self.bars {
                bar.frame.size.height = 8
                bar.frame.origin.y = (self.bounds.height - 8) / 2
            }
        }
    }

    private func startAnimation() {
        guard self.timer == nil else { return }

        self.startTime = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateBars()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimation() {
        self.timer?.invalidate()
        self.timer = nil
    }

    private func updateBars() {
        guard self.isAnimating else { return }

        let elapsed = CACurrentMediaTime() - self.startTime
        let barHeights: [CGFloat] = [
            4 + 8 * CGFloat(abs(sin(elapsed * 4))),
            4 + 10 * CGFloat(abs(sin(elapsed * 3 + 1))),
            4 + 6 * CGFloat(abs(sin(elapsed * 5 + 2))),
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in self.bars.enumerated() {
            let height = min(barHeights[i], self.bounds.height)
            bar.frame.size.height = height
            bar.frame.origin.y = (self.bounds.height - height) / 2
        }
        CATransaction.commit()
    }

    isolated deinit {
        self.stopAnimation()
    }
}
