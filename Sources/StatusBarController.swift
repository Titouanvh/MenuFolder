import Cocoa

@MainActor
final class StatusBarController: NSObject {
    static let buttonAutosaveName = "MenuFolder.MainButton"
    static let separatorAutosaveName = "MenuFolder.Separator"
    private static let initialPlacementKey = "MenuFolder.DidInitialPlacement"

    static let buttonLength: CGFloat = 28
    static let collapsedSeparatorLength: CGFloat = 10_000
    static let revealedSeparatorLength: CGFloat = 18
    static let temporaryRevealLength: CGFloat = 1

    private(set) var buttonItem: NSStatusItem
    private(set) var separatorItem: NSStatusItem
    private(set) var isRevealed = false
    private var isTemporarilyRevealed = false

    var onLeftClick: (() -> Void)?
    var onOpenManager: (() -> Void)?
    var onToggleReveal: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        Self.seedInitialPositionIfNeeded()

        buttonItem = NSStatusBar.system.statusItem(withLength: Self.buttonLength)
        separatorItem = NSStatusBar.system.statusItem(withLength: Self.revealedSeparatorLength)
        super.init()

        configureButtonItem(buttonItem)
        configureSeparatorItem(separatorItem)

        // Collapse once Control Center assigns initial window frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.applySeparatorAppearance()
        }
    }

    var buttonWindowFrame: NSRect? {
        buttonItem.button?.window?.frame
    }

    var buttonScreen: NSScreen {
        buttonItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Left edge of the separator in global screen X coordinates (identical in AppKit & Quartz).
    var separatorMinX: CGFloat {
        if let frame = separatorItem.button?.window?.frame, frame.width > 0 {
            return frame.minX
        }
        return buttonWindowFrame?.minX ?? 0
    }

    /// Top edge of the menu bar screen in Quartz coordinates (origin at primary screen top-left).
    var menuBarQuartzTopY: CGFloat {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? buttonScreen.frame.maxY
        return primaryMaxY - buttonScreen.frame.maxY
    }

    func setRevealed(_ revealed: Bool) {
        isRevealed = revealed
        isTemporarilyRevealed = false
        applySeparatorAppearance()
        onToggleReveal?()
    }

    func toggleRevealed() {
        setRevealed(!isRevealed)
    }

    /// Briefly shrinks the spacer without showing the divider glyph so an app can anchor its menu on-screen.
    func beginTemporaryReveal() {
        guard !isRevealed else { return }
        isTemporarilyRevealed = true
        separatorItem.length = Self.temporaryRevealLength
    }

    /// Restores the collapsed spacer after menu activation unless the user switched to permanent reveal mode.
    func endTemporaryReveal() {
        guard isTemporarilyRevealed else { return }
        isTemporarilyRevealed = false
        if !isRevealed {
            ensureSeparatorLeftOfButton()
            separatorItem.length = Self.collapsedSeparatorLength
        }
    }

    /// Temporarily prepares status item widths for programmatic Cmd-drag across the separator.
    /// Shrinking both button and separator to 0.01pt reclaims ~60-78pt from the notch when dragging icons out.
    func beginDragLayout(shrinkButton: Bool) {
        isTemporarilyRevealed = true
        if shrinkButton {
            buttonItem.length = 0.01
            separatorItem.length = 0.01
        } else {
            separatorItem.length = Self.revealedSeparatorLength
        }
    }

    func endDragLayout() {
        buttonItem.length = Self.buttonLength
        isTemporarilyRevealed = false
        applySeparatorAppearance()
    }

    var separatorWindowFrame: NSRect? {
        separatorItem.button?.window?.frame
    }

    func cleanupForTermination() {
        isRevealed = true
        isTemporarilyRevealed = false
        separatorItem.length = Self.revealedSeparatorLength
        NSStatusBar.system.removeStatusItem(separatorItem)
        NSStatusBar.system.removeStatusItem(buttonItem)
    }

    // MARK: - Setup & Guards

    /// On notched MacBooks, brand-new status items with no saved position can start clipped under the notch.
    /// Seeds adjacent default positions once before creating the status items so the button is immediately visible.
    private static func seedInitialPositionIfNeeded() {
        let defaults = UserDefaults.standard
        let btnKey = "NSStatusItem Preferred Position \(buttonAutosaveName)"
        let sepKey = "NSStatusItem Preferred Position \(separatorAutosaveName)"
        guard !defaults.bool(forKey: initialPlacementKey),
              defaults.object(forKey: btnKey) == nil else { return }
        defaults.set(true, forKey: initialPlacementKey)

        guard let screen = NSScreen.screens.first,
              let auxRight = screen.auxiliaryTopRightArea else { return }

        // Place inside the visible right-of-notch region, adjacent to each other.
        let safeOffset = Double(min(285.0, max(160.0, auxRight.width * 0.44)))
        defaults.set(safeOffset, forKey: btnKey)
        defaults.set(safeOffset + 0.5, forKey: sepKey)
    }

    private func configureButtonItem(_ item: NSStatusItem) {
        item.autosaveName = Self.buttonAutosaveName
        guard let button = item.button else { return }
        button.image = Self.makeFolderSymbolImage()
        button.imagePosition = .imageOnly
        button.toolTip = "MenuFolder (clic : ouvrir · clic droit : options)"
        button.target = self
        button.action = #selector(handleMainButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureSeparatorItem(_ item: NSStatusItem) {
        item.autosaveName = Self.separatorAutosaveName
        guard let button = item.button else { return }
        button.title = ""
        button.target = self
        button.action = #selector(handleSeparatorClick(_:))
        button.sendAction(on: [.leftMouseUp])
    }

    private func applySeparatorAppearance() {
        guard let button = separatorItem.button else { return }
        if isRevealed {
            separatorItem.length = Self.revealedSeparatorLength
            button.image = Self.makeSeparatorImage()
            button.imagePosition = .imageOnly
            button.isEnabled = true
            button.toolTip = "Glissez avec ⌘ à gauche pour ranger · Clic pour masquer"
        } else {
            ensureSeparatorLeftOfButton()
            button.image = nil
            button.title = ""
            button.isEnabled = false
            button.toolTip = nil
            separatorItem.length = Self.collapsedSeparatorLength
        }
    }

    /// Prevents the main folder button from hiding itself if the separator was dragged to its right.
    private func ensureSeparatorLeftOfButton() {
        guard let btnFrame = buttonItem.button?.window?.frame,
              let sepFrame = separatorItem.button?.window?.frame,
              btnFrame.width > 0, sepFrame.width > 0 else { return }
        // Only check when separator is compact (collapsed separator spans far left already).
        guard sepFrame.width < 1000, sepFrame.minX >= btnFrame.minX - 1 else { return }

        let defaults = UserDefaults.standard
        let btnKey = "NSStatusItem Preferred Position \(Self.buttonAutosaveName)"
        let sepKey = "NSStatusItem Preferred Position \(Self.separatorAutosaveName)"
        let screenMaxX = buttonScreen.frame.maxX
        let currentBtnOffset = defaults.object(forKey: btnKey) != nil
            ? defaults.double(forKey: btnKey)
            : Double(max(40, screenMaxX - btnFrame.minX))

        // Remove first because removeStatusItem clears the autosaved position key in UserDefaults.
        NSStatusBar.system.removeStatusItem(separatorItem)
        defaults.set(currentBtnOffset + 1.0, forKey: sepKey)
        let recreated = NSStatusBar.system.statusItem(withLength: Self.revealedSeparatorLength)
        configureSeparatorItem(recreated)
        separatorItem = recreated
    }

    // MARK: - Actions

    @objc private func handleMainButtonClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            onLeftClick?()
            return
        }
        if event.modifierFlags.contains(.command) { return }

        let isRightClick = event.type == .rightMouseUp
            || event.type == .rightMouseDown
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            showContextMenu(from: sender)
        } else {
            onLeftClick?()
        }
    }

    @objc private func handleSeparatorClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return }
        if isRevealed {
            setRevealed(false)
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let manageItem = NSMenuItem(
            title: "Gérer les icônes…",
            action: #selector(menuOpenManager),
            keyEquivalent: ""
        )
        manageItem.target = self
        menu.addItem(manageItem)

        let revealItem = NSMenuItem(
            title: "Afficher les icônes rangées",
            action: #selector(menuToggleReveal),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.state = isRevealed ? .on : .off
        menu.addItem(revealItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quitter",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func menuOpenManager() {
        onOpenManager?()
    }

    @objc private func menuToggleReveal() {
        toggleRevealed()
    }

    @objc private func menuQuit() {
        onQuit?()
    }

    // MARK: - Icons

    private static func makeFolderSymbolImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "MenuFolder")?
            .withSymbolConfiguration(config) {
            symbol.isTemplate = true
            return symbol
        }
        let img = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor.labelColor.setFill()
            for row in 0..<2 {
                for col in 0..<2 {
                    let rect = NSRect(x: 1 + col * 7, y: 1 + row * 7, width: 5, height: 5)
                    NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func makeSeparatorImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 16), flipped: false) { _ in
            NSColor.labelColor.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: NSRect(x: 4, y: 2, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
