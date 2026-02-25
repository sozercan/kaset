import AppKit
import SwiftUI

// MARK: - QueueCellActions

@available(macOS 26.0, *)
struct QueueCellActions {
    let onPlay: () -> Void
    let onRemove: () -> Void
}

// MARK: - QueueTableCellView

@available(macOS 26.0, *)
class QueueTableCellView: NSView {
    private var onPlay: (() -> Void)?
    private var onRemove: (() -> Void)?
    private var isCurrentTrack: Bool = false
    private var isPlaying: Bool = false
    private var indicatorLabel = NSTextField()
    private var waveformView: NSView?
    private let thumbnailImageView = NSImageView()
    private var imageLoadTask: Task<Void, Never>?
    private var currentSongId: String?
    private let titleLabel = NSTextField()
    private let artistLabel = NSTextField()
    private let durationLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setupView()
    }

    private func setupView() {
        wantsLayer = true
        // Fill the row view so layout is consistent when the table reuses row views (fixes misaligned rows).
        autoresizingMask = [.width, .height]

        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 12
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8) // Reduced right padding
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Indicator container (for number or waveform) — keep fixed so long text doesn't shift row layout
        let indicatorContainer = NSView()
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        let indicatorWidth = indicatorContainer.widthAnchor.constraint(equalToConstant: 24)
        indicatorWidth.priority = .required
        indicatorWidth.isActive = true
        indicatorContainer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        indicatorContainer.setContentHuggingPriority(.required, for: .horizontal)
        indicatorContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        self.indicatorLabel.isEditable = false
        self.indicatorLabel.isBordered = false
        self.indicatorLabel.backgroundColor = .clear
        self.indicatorLabel.alignment = .center
        self.indicatorLabel.font = NSFont.systemFont(ofSize: 12)
        self.indicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.addSubview(self.indicatorLabel)
        NSLayoutConstraint.activate([
            self.indicatorLabel.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            self.indicatorLabel.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
        ])

        self.thumbnailImageView.wantsLayer = true
        self.thumbnailImageView.layer?.cornerRadius = 4
        self.thumbnailImageView.layer?.masksToBounds = true
        self.thumbnailImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        self.thumbnailImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        self.thumbnailImageView.setContentHuggingPriority(.required, for: .horizontal)
        self.thumbnailImageView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let infoStackView = NSStackView()
        infoStackView.orientation = .vertical
        infoStackView.spacing = 2
        infoStackView.alignment = .leading

        self.titleLabel.isEditable = false
        self.titleLabel.isBordered = false
        self.titleLabel.backgroundColor = .clear
        self.titleLabel.lineBreakMode = .byTruncatingTail

        self.artistLabel.isEditable = false
        self.artistLabel.isBordered = false
        self.artistLabel.backgroundColor = .clear
        self.artistLabel.lineBreakMode = .byTruncatingTail
        self.artistLabel.font = NSFont.systemFont(ofSize: 11)
        self.artistLabel.textColor = NSColor.secondaryLabelColor

        infoStackView.addArrangedSubview(self.titleLabel)
        infoStackView.addArrangedSubview(self.artistLabel)

        self.durationLabel.isEditable = false
        self.durationLabel.isBordered = false
        self.durationLabel.backgroundColor = .clear
        self.durationLabel.alignment = .right
        self.durationLabel.font = NSFont.systemFont(ofSize: 11)
        self.durationLabel.textColor = NSColor.tertiaryLabelColor
        self.durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal) // Don't compress duration

        // Spacer takes all flexible space so title/artist and duration stay consistently aligned across rows
        let spacerView = NSView()
        spacerView.translatesAutoresizingMaskIntoConstraints = false
        spacerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        infoStackView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) // Truncate before spacer grows

        stackView.addArrangedSubview(indicatorContainer)
        stackView.addArrangedSubview(self.thumbnailImageView)
        stackView.addArrangedSubview(infoStackView)
        stackView.addArrangedSubview(spacerView)
        stackView.addArrangedSubview(self.durationLabel)

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(clickGesture)
    }

    override func layout() {
        super.layout()
        // Ensure we always fill the row view so reused rows don't keep a stale frame (fixes misaligned rows).
        if let sv = superview, !sv.bounds.isEmpty, frame != sv.bounds {
            frame = sv.bounds
        }
    }

    func configure(song: Song, index: Int, isCurrentTrack: Bool, isPlaying: Bool, actions: QueueCellActions) {
        self.onPlay = actions.onPlay
        self.onRemove = actions.onRemove
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying
        self.updateAppearance(isCurrentTrack: isCurrentTrack, isPlaying: isPlaying, index: index)

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
        if let url = song.thumbnailURL?.highQualityThumbnailURL {
            self.imageLoadTask = Task { [weak self] in
                let image = await ImageCache.shared.image(for: url, targetSize: CGSize(width: 40, height: 40))
                guard !Task.isCancelled, self?.currentSongId == songId else { return }
                self?.thumbnailImageView.image = image
            }
        } else {
            self.thumbnailImageView.image = nil
        }
    }

    func updateAppearance(isCurrentTrack: Bool, isPlaying: Bool, index: Int) {
        self.isCurrentTrack = isCurrentTrack
        self.isPlaying = isPlaying

        if isCurrentTrack {
            // Show animated waveform for current track
            self.indicatorLabel.stringValue = ""
            self.indicatorLabel.isHidden = true

            // Create or update waveform view
            if self.waveformView == nil {
                let waveView = WaveformView(frame: NSRect(x: 0, y: 0, width: 24, height: 16))
                waveView.translatesAutoresizingMaskIntoConstraints = false
                self.waveformView = waveView

                // Find indicator container and add waveform
                if let indicatorContainer = indicatorLabel.superview {
                    indicatorContainer.addSubview(waveView)
                    NSLayoutConstraint.activate([
                        waveView.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
                        waveView.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
                        waveView.widthAnchor.constraint(equalToConstant: 24),
                        waveView.heightAnchor.constraint(equalToConstant: 16),
                    ])
                }
            }

            if let waveView = waveformView as? WaveformView {
                waveView.isHidden = false
                waveView.isAnimating = isPlaying
                waveView.tintColor = isPlaying ? NSColor.systemRed : NSColor.tertiaryLabelColor
            }

            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        } else {
            // Show number for non-current tracks
            self.indicatorLabel.isHidden = false
            self.indicatorLabel.stringValue = "\(index + 1)"
            self.indicatorLabel.textColor = NSColor.tertiaryLabelColor

            // Hide waveform
            self.waveformView?.isHidden = true

            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    @objc private func handleClick() {
        self.onPlay?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.imageLoadTask?.cancel()
        self.imageLoadTask = nil
        self.currentSongId = nil
        self.thumbnailImageView.image = nil
        self.waveformView?.removeFromSuperview()
        self.waveformView = nil
    }
}

// MARK: - WaveformView

@available(macOS 26.0, *)
class WaveformView: NSView {
    var isAnimating: Bool = false {
        didSet {
            self.updateAnimation()
        }
    }

    var tintColor: NSColor = .systemRed {
        didSet {
            layer?.sublayers?.forEach { $0.backgroundColor = self.tintColor.cgColor }
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
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Create 3 bars for the waveform
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 2
        let totalWidth = CGFloat(3) * barWidth + CGFloat(2) * barSpacing
        let startX = (bounds.width - totalWidth) / 2

        for i in 0 ..< 3 {
            let bar = CALayer()
            bar.backgroundColor = self.tintColor.cgColor
            bar.cornerRadius = 1
            bar.frame = NSRect(
                x: startX + CGFloat(i) * (barWidth + barSpacing),
                y: bounds.height / 2 - 4,
                width: barWidth,
                height: 8
            )
            layer?.addSublayer(bar)
            self.bars.append(bar)
        }
    }

    private func updateAnimation() {
        if self.isAnimating {
            self.startAnimation()
        } else {
            self.stopAnimation()
            // Reset to static middle position
            for bar in self.bars {
                bar.frame.size.height = 8
                bar.frame.origin.y = (bounds.height - 8) / 2
            }
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }

        self.startTime = CACurrentMediaTime()

        // Use Timer for 30fps animation - simpler and safer than CVDisplayLink
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateBars()
        }
        // Add to common run loop modes to ensure it runs during tracking/dragging
        if let timer {
            RunLoop.current.add(timer, forMode: .common)
        }
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
        CATransaction.setDisableActions(true) // Disable implicit animations
        for (i, bar) in self.bars.enumerated() {
            let height = min(barHeights[i], bounds.height)
            bar.frame.size.height = height
            bar.frame.origin.y = (bounds.height - height) / 2
        }
        CATransaction.commit()
    }

    deinit {
        stopAnimation()
    }
}
