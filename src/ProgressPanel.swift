import AppKit
import QuickLookThumbnailing

/// Top-left origin, so the layout reads top to bottom.
private class FlippedView: NSView {
    var onAppearanceChange: (() -> Void)?
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The round X button: quiet at rest, darker under the pointer.
private final class CloseButton: NSButton {
    private var hovering = false { didSet { refresh() } }

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(config)
        setAccessibilityLabel("Close")
        wantsLayer = true
        layer?.cornerRadius = 10
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovering ? 0.18 : 0.09).cgColor
        }
        contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }
}

/// A slim rounded track with an animated fill.
private final class ProgressBar: NSView {
    private let fill = CALayer()
    private(set) var fraction: CGFloat = 0
    var color: NSColor = .controlAccentColor { didSet { refresh() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.masksToBounds = true
        fill.cornerRadius = frame.height / 2
        fill.anchorPoint = .zero
        layer?.addSublayer(fill)
        set(0, animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: CGFloat, animated: Bool) {
        fraction = max(0, min(1, value))
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            fill.backgroundColor = color.cgColor
        }
    }
}

/// Floating frosted-glass panel in the bottom-right corner showing conversion progress.
final class ProgressPanel: NSObject {
    private let width: CGFloat = 340
    private let height: CGFloat = 72
    private let margin: CGFloat = 20
    private let showDelay: TimeInterval = 1.5
    private let doneLinger: TimeInterval = 3

    private let panel: NSPanel
    private let root = FlippedView()
    private let effect = NSVisualEffectView()
    private let rim = NSView()
    private let thumb = NSImageView()
    private let badge = NSView()
    private let badgeIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let queueLabel = NSTextField(labelWithString: "")
    private let bar = ProgressBar(frame: NSRect(x: 70, y: 55, width: 256, height: 4))
    private var closeButton: CloseButton!

    private enum Phase { case converting, done, failed }
    private var phase = Phase.converting
    private var percent: Double?
    private var timeLeft = "Starting…"
    private var doneSizes = ""
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var generation = 0
    private var job = 0
    private var jobStart = Date()
    private var dismissed = false
    private(set) var active = false

    init(shareable: Bool) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // Keep the panel out of screenshots and screen recordings.
        panel.sharingType = shareable ? .readOnly : .none

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        root.frame = bounds
        panel.contentView = root

        // Frosted glass, rounded by a mask so the window shadow follows the corners.
        effect.frame = bounds
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 18)
        root.addSubview(effect)

        rim.frame = bounds
        rim.wantsLayer = true
        rim.layer?.cornerRadius = 18
        rim.layer?.borderWidth = 0.5
        root.addSubview(rim)

        thumb.frame = NSRect(x: 12, y: 13, width: 46, height: 46)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 11
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 0.5
        root.addSubview(thumb)

        badge.frame = NSRect(x: 44, y: 45, width: 18, height: 18)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.borderWidth = 2
        badgeIcon.frame = badge.bounds
        badgeIcon.imageAlignment = .alignCenter
        badgeIcon.contentTintColor = .white
        badge.addSubview(badgeIcon)
        root.addSubview(badge)

        titleLabel.frame = NSRect(x: 70, y: 12, width: 230, height: 17)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        root.addSubview(titleLabel)

        for label in [statusLabel, queueLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            root.addSubview(label)
        }
        queueLabel.textColor = .tertiaryLabelColor
        queueLabel.alignment = .right

        root.addSubview(bar)

        closeButton = CloseButton(target: self, action: #selector(closeClicked))
        closeButton.frame = NSRect(x: width - 30, y: 10, width: 20, height: 20)
        root.addSubview(closeButton)

        root.onAppearanceChange = { [weak self] in self?.refreshColors() }
        refreshColors()
    }

    // MARK: Events from the worker

    func start(file: String, source: URL, waiting: Int, hasDuration: Bool) {
        active = true
        dismissed = false
        job += 1
        jobStart = Date()
        hideWork?.cancel()
        phase = .converting
        percent = hasDuration ? 0 : nil
        timeLeft = hasDuration ? "Starting…" : "Converting…"
        titleLabel.stringValue = file
        titleLabel.toolTip = file
        setQueue(waiting > 0 ? "\(waiting) more waiting" : "")
        bar.color = .controlAccentColor
        bar.set(hasDuration ? 0 : 1, animated: false)
        bar.alphaValue = hasDuration ? 1 : 0.35
        setBadge(symbol: "play.fill", size: 8, color: .controlAccentColor)
        loadThumbnail(for: source, job: job)
        renderStatus()

        if panel.isVisible {
            panel.alphaValue = 1
            return
        }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, !self.dismissed else { return }
            self.present()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
    }

    func update(percent value: Double) {
        guard active, phase == .converting else { return }
        let clamped = max(0, min(100, value))
        percent = clamped
        bar.alphaValue = 1
        bar.set(CGFloat(clamped / 100), animated: true)
        let elapsed = Date().timeIntervalSince(jobStart)
        if clamped >= 5 { timeLeft = Self.timeLeft(elapsed * (100 - clamped) / clamped) }
        renderStatus()
    }

    func finish(success: Bool, waiting: Int, output: String? = nil, inSize: Int64 = 0, outSize: Int64 = 0) {
        active = false
        showWork?.cancel()
        guard panel.isVisible else { return }
        if success {
            phase = .done
            if let output { titleLabel.stringValue = (output as NSString).lastPathComponent }
            let sizes = ByteCountFormatter()
            sizes.countStyle = .file
            doneSizes = "\(sizes.string(fromByteCount: inSize)) → \(sizes.string(fromByteCount: outSize))"
            bar.color = .systemGreen
            bar.alphaValue = 1
            bar.set(1, animated: true)
            setBadge(symbol: "checkmark", size: 9, color: .systemGreen)
        } else {
            phase = .failed
            bar.color = .systemRed
            bar.alphaValue = 1
            setBadge(symbol: "exclamationmark", size: 9, color: .systemRed)
        }
        setQueue(waiting > 0 ? "Next: \(waiting) more" : "")
        renderStatus()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doneLinger, execute: work)
    }

    /// The worker stopped without finishing (killed, crashed): hide right away.
    func abort() {
        active = false
        showWork?.cancel()
        hideWork?.cancel()
        hide(animated: false)
    }

    // MARK: Drawing

    @objc private func closeClicked() {
        dismissed = true
        showWork?.cancel()
        hideWork?.cancel()
        hide()
    }

    private func renderStatus() {
        let regular = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let text = NSMutableAttributedString()
        func add(_ string: String, _ font: NSFont, _ color: NSColor) {
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        let dot = { add("  ·  ", regular, .tertiaryLabelColor) }
        switch phase {
        case .converting:
            if let percent {
                add("\(Int(percent.rounded(.down)))%", bold, .labelColor)
                dot()
            }
            add(timeLeft, regular, .secondaryLabelColor)
        case .done:
            add("Done", bold, .systemGreen)
            dot()
            add(doneSizes, regular, .secondaryLabelColor)
        case .failed:
            add("Couldn't convert", bold, .systemRed)
            dot()
            add("will retry", regular, .secondaryLabelColor)
        }
        statusLabel.attributedStringValue = text
    }

    private func setQueue(_ text: String) {
        queueLabel.stringValue = text
        queueLabel.sizeToFit()
        let main: CGFloat = 256
        let queueWidth = text.isEmpty ? 0 : ceil(queueLabel.frame.width)
        queueLabel.frame = NSRect(x: 70 + main - queueWidth, y: 31, width: queueWidth, height: 16)
        statusLabel.frame = NSRect(x: 70, y: 31, width: main - queueWidth - (text.isEmpty ? 0 : 10), height: 16)
    }

    private func setBadge(symbol: String, size: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .heavy)
        badgeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        badgeColor = color
        refreshColors()
    }

    private var badgeColor: NSColor = .controlAccentColor

    private func refreshColors() {
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            rim.layer?.borderColor = NSColor.separatorColor.cgColor
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
            thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            badge.layer?.backgroundColor = badgeColor.cgColor
            badge.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        }
        bar.refresh()
        closeButton?.refresh()
    }

    private func loadThumbnail(for url: URL, job current: Int) {
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        thumb.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        thumb.imageScaling = .scaleNone
        thumb.contentTintColor = .secondaryLabelColor
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 46, height: 46),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.job == current else { return }
                self.thumb.image = Self.squareCrop(image)
                self.thumb.imageScaling = .scaleAxesIndependently
            }
        }
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let final = NSRect(x: frame.maxX - width - margin, y: frame.minY + margin, width: width, height: height)
        generation += 1
        panel.setFrame(final.offsetBy(dx: 0, dy: -12), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    private func hide(animated: Bool = true) {
        guard panel.isVisible else { return }
        generation += 1
        let current = generation
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        })
    }

    // MARK: Helpers


    private static func timeLeft(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "~\(max(1, Int(seconds.rounded()))) s left" }
        return "~\(Int((seconds / 60).rounded())) min left"
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Center-crop a thumbnail to a square so the tile is filled edge to edge.
    private static func squareCrop(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let side = min(cg.width, cg.height)
        let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: side, height: side))
    }
}
