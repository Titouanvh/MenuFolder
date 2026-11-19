import Cocoa

@MainActor
final class FolderPanel: NSPanel, NSWindowDelegate {
    private let effectView = NSVisualEffectView()
    private let contentStack = NSStackView()
    private var tileViewsByID: [String: FolderTileView] = [:]

    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var anchorButtonRect: NSRect = .zero

    /// Temporarily prevents outside-click dismissal during programmatic Cmd-drag or tile context menus.
    var suppressAutoDismiss = false

    var onSelectItem: ((MenuBarItem) -> Void)?
    var onChangePlacement: ((MenuBarItem, IconPlacement) -> Void)?
    var onOpenManager: (() -> Void)?
    var onBackToGrid: (() -> Void)?
    var onToggleReveal: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRequestScreenRecording: (() -> Void)?
    var onDidClose: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 256, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        delegate = self

        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 16
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: effectView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])

        contentView = effectView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        closePanel()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            closePanel()
        } else {
            super.keyDown(with: event)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if !suppressAutoDismiss {
            closePanel()
        }
    }

    // MARK: - Rendering States

    func showLoading(anchoredBelow buttonRect: NSRect, on screen: NSScreen) {
        clearContent()
        let label = NSTextField(labelWithString: "Chargement…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 248),
            box.heightAnchor.constraint(equalToConstant: 72),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        contentStack.addArrangedSubview(box)
        present(anchoredBelow: buttonRect, on: screen)
    }

    func showAccessibilityRequired(isRevealed: Bool, anchoredBelow buttonRect: NSRect, on screen: NSScreen) {
        clearContent()
        let container = makeCenteredCard(
            symbol: "hand.raised",
            title: "Autorisation Accessibilité requise",
            subtitle: "macOS exige Accessibilité pour lister les icônes rangées et ouvrir leurs menus. Vous pouvez tout de même révéler vos icônes.",
            primaryTitle: "Ouvrir Réglages…",
            primaryAction: #selector(handleRequestAccessibility),
            secondaryTitle: isRevealed ? "Masquer les icônes" : "Afficher les icônes",
            secondaryAction: #selector(handleToggleReveal)
        )
        contentStack.addArrangedSubview(container)
        present(anchoredBelow: buttonRect, on: screen)
    }

    func showItems(
        _ items: [MenuBarItem],
        hiddenCount: Int,
        isRevealed: Bool,
        hasScreenRecording: Bool,
        anchoredBelow buttonRect: NSRect,
        on screen: NSScreen
    ) {
        clearContent()
        tileViewsByID.removeAll()

        if items.isEmpty {
            let subtitle = hiddenCount > 0
                ? "\(hiddenCount) icône\(hiddenCount > 1 ? "s sont cachées" : " est cachée"). Ouvrez Gérer pour choisir quoi afficher dans le dossier ou dans la barre."
                : "Cliquez sur Gérer pour choisir les icônes à ranger, ou maintenez ⌘ pour les glisser à gauche du séparateur."
            let container = makeCenteredCard(
                symbol: "square.grid.2x2",
                title: "Aucune icône dans le dossier",
                subtitle: subtitle,
                primaryTitle: "Gérer les icônes…",
                primaryAction: #selector(handleOpenManager),
                secondaryTitle: isRevealed ? "Masquer" : "Afficher",
                secondaryAction: #selector(handleToggleReveal)
            )
            contentStack.addArrangedSubview(container)
            present(anchoredBelow: buttonRect, on: screen)
            return
        }

        let maxColumns = items.count <= 9 ? 3 : 4
        let columns = min(items.count, maxColumns)
        let rows = Int(ceil(Double(items.count) / Double(columns)))
        let tileWidth: CGFloat = 76
        let tileHeight: CGFloat = 72
        let spacing: CGFloat = 6
        let pad: CGFloat = 12

        let gridWidth = CGFloat(columns) * tileWidth + CGFloat(max(0, columns - 1)) * spacing
        let panelWidth = max(260, gridWidth + pad * 2)

        let gridView = NSView()
        gridView.translatesAutoresizingMaskIntoConstraints = false
        let totalGridHeight = CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * spacing
        let horizontalInset = (panelWidth - gridWidth) / 2.0

        for (idx, item) in items.enumerated() {
            let row = idx / columns
            let col = idx % columns
            let tile = FolderTileView(
                item: item,
                onOpen: { [weak self] selected in
                    self?.onSelectItem?(selected)
                },
                onChangePlacement: { [weak self] selected, target in
                    self?.onChangePlacement?(selected, target)
                },
                onContextMenuActive: { [weak self] active in
                    self?.suppressAutoDismiss = active
                }
            )
            tile.translatesAutoresizingMaskIntoConstraints = false
            gridView.addSubview(tile)
            tileViewsByID[item.id] = tile

            let x = horizontalInset + CGFloat(col) * (tileWidth + spacing)
            let yFromTop = pad + CGFloat(row) * (tileHeight + spacing)
            NSLayoutConstraint.activate([
                tile.leadingAnchor.constraint(equalTo: gridView.leadingAnchor, constant: x),
                tile.topAnchor.constraint(equalTo: gridView.topAnchor, constant: yFromTop),
                tile.widthAnchor.constraint(equalToConstant: tileWidth),
                tile.heightAnchor.constraint(equalToConstant: tileHeight)
            ])
        }

        let contentHeight = totalGridHeight + pad * 2
        let maxVisibleGridHeight: CGFloat = 4 * tileHeight + 3 * spacing + pad * 2

        if contentHeight <= maxVisibleGridHeight {
            NSLayoutConstraint.activate([
                gridView.widthAnchor.constraint(equalToConstant: panelWidth),
                gridView.heightAnchor.constraint(equalToConstant: contentHeight)
            ])
            contentStack.addArrangedSubview(gridView)
        } else {
            let flippedDoc = FlippedContainerView()
            flippedDoc.frame = NSRect(x: 0, y: 0, width: panelWidth, height: contentHeight)
            gridView.translatesAutoresizingMaskIntoConstraints = true
            gridView.frame = flippedDoc.bounds
            flippedDoc.addSubview(gridView)

            let scroll = NSScrollView()
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = flippedDoc
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalToConstant: panelWidth),
                scroll.heightAnchor.constraint(equalToConstant: maxVisibleGridHeight)
            ])
            contentStack.addArrangedSubview(scroll)
        }

        contentStack.addArrangedSubview(makeDivider(width: panelWidth))
        contentStack.addArrangedSubview(makeGridFooter(
            width: panelWidth,
            itemCount: items.count,
            isRevealed: isRevealed,
            hasScreenRecording: hasScreenRecording
        ))

        present(anchoredBelow: buttonRect, on: screen)
    }

    func showManager(
        items: [MenuBarItem],
        isRevealed: Bool,
        isBusy: Bool,
        statusMessage: String?,
        anchoredBelow buttonRect: NSRect,
        on screen: NSScreen
    ) {
        clearContent()
        tileViewsByID.removeAll()

        let panelWidth: CGFloat = 348
        let sortedItems = items.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let backBtn = NSButton(title: "‹ Dossier", target: self, action: #selector(handleBackToGrid))
        backBtn.isBordered = false
        backBtn.font = .systemFont(ofSize: 12, weight: .medium)
        backBtn.contentTintColor = .controlAccentColor
        backBtn.isEnabled = !isBusy
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(backBtn)

        let titleLabel = NSTextField(labelWithString: "Gérer les icônes")
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalToConstant: panelWidth),
            header.heightAnchor.constraint(equalToConstant: 36),
            backBtn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            backBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        contentStack.addArrangedSubview(header)
        contentStack.addArrangedSubview(makeDivider(width: panelWidth))

        // Rows
        let rowHeight: CGFloat = 34
        let listPad: CGFloat = 6
        if sortedItems.isEmpty {
            let emptyLabel = NSTextField(labelWithString: "Aucune icône détectée dans la barre de menus.")
            emptyLabel.font = .systemFont(ofSize: 12)
            emptyLabel.textColor = .secondaryLabelColor
            emptyLabel.alignment = .center
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false

            let box = NSView()
            box.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(emptyLabel)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: panelWidth),
                box.heightAnchor.constraint(equalToConstant: 64),
                emptyLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                emptyLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor)
            ])
            contentStack.addArrangedSubview(box)
        } else {
            let totalHeight = CGFloat(sortedItems.count) * rowHeight + listPad * 2
            let maxListHeight: CGFloat = 8 * rowHeight + listPad * 2

            let rowsContainer = FlippedContainerView()
            rowsContainer.frame = NSRect(x: 0, y: 0, width: panelWidth, height: totalHeight)

            for (idx, item) in sortedItems.enumerated() {
                let rowView = ManagerRowView(
                    item: item,
                    isEnabled: !isBusy
                ) { [weak self] target in
                    self?.onChangePlacement?(item, target)
                }
                rowView.frame = NSRect(
                    x: 0,
                    y: listPad + CGFloat(idx) * rowHeight,
                    width: panelWidth,
                    height: rowHeight
                )
                rowsContainer.addSubview(rowView)
            }

            if totalHeight <= maxListHeight {
                rowsContainer.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    rowsContainer.widthAnchor.constraint(equalToConstant: panelWidth),
                    rowsContainer.heightAnchor.constraint(equalToConstant: totalHeight)
                ])
                contentStack.addArrangedSubview(rowsContainer)
            } else {
                let scroll = NSScrollView()
                scroll.translatesAutoresizingMaskIntoConstraints = false
                scroll.drawsBackground = false
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.documentView = rowsContainer
                NSLayoutConstraint.activate([
                    scroll.widthAnchor.constraint(equalToConstant: panelWidth),
                    scroll.heightAnchor.constraint(equalToConstant: maxListHeight)
                ])
                contentStack.addArrangedSubview(scroll)
            }
        }

        contentStack.addArrangedSubview(makeDivider(width: panelWidth))

        // Manager footer
        let barCount = sortedItems.filter { $0.placement == .bar }.count
        let folderCount = sortedItems.filter { $0.placement == .folder }.count
        let hiddenCount = sortedItems.filter { $0.placement == .hidden }.count
        let defaultSummary = "\(barCount) barre · \(folderCount) dossier · \(hiddenCount) cachée\(hiddenCount > 1 ? "s" : "")"
        let footerText = isBusy ? "Déplacement en cours…" : (statusMessage ?? defaultSummary)

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: footerText)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = statusMessage != nil && !isBusy ? .systemOrange : .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.toolTip = footerText
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)

        let toggleButton = NSButton(
            title: isRevealed ? "Masquer" : "Afficher",
            target: self,
            action: #selector(handleToggleReveal)
        )
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .mini
        toggleButton.font = .systemFont(ofSize: 11, weight: .medium)
        toggleButton.isEnabled = !isBusy
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(toggleButton)

        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: panelWidth),
            footer.heightAnchor.constraint(equalToConstant: 32),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggleButton.leadingAnchor, constant: -8),
            toggleButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            toggleButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        contentStack.addArrangedSubview(footer)

        present(anchoredBelow: buttonRect, on: screen)
    }

    func updateCapturedIcon(itemID: String, image: NSImage) {
        tileViewsByID[itemID]?.applyCapturedIcon(image)
    }

    func closePanel() {
        let wasVisible = isVisible
        suppressAutoDismiss = false
        removeDismissMonitors()
        if wasVisible {
            orderOut(nil)
            onDidClose?()
        }
    }

    // MARK: - Presentation & Dismissal

    private func present(anchoredBelow buttonRect: NSRect, on screen: NSScreen) {
        anchorButtonRect = buttonRect
        effectView.layoutSubtreeIfNeeded()
        let size = effectView.fittingSize
        let visible = screen.visibleFrame

        var x = round(buttonRect.midX - size.width / 2.0)
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let y = round(buttonRect.minY - size.height - 6)

        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        installDismissMonitors()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible, !self.suppressAutoDismiss else { return }
            let clickLocation = NSEvent.mouseLocation
            if self.frame.contains(clickLocation) || self.anchorButtonRect.contains(clickLocation) {
                return
            }
            self.closePanel()
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.isVisible, !self.suppressAutoDismiss {
                self.closePanel()
                return nil
            }
            return event
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
    }

    private func removeDismissMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
    }

    private func clearContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    // MARK: - Subviews

    private func makeDivider(width: CGFloat) -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: width),
            divider.heightAnchor.constraint(equalToConstant: 0.5)
        ])
        return divider
    }

    private func makeGridFooter(width: CGFloat, itemCount: Int, isRevealed: Bool, hasScreenRecording: Bool) -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false

        let countText = itemCount == 1 ? "1 icône" : "\(itemCount) icônes"
        let countLabel = NSTextField(labelWithString: countText)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(countLabel)

        let manageButton = NSButton(title: "", target: self, action: #selector(handleOpenManager))
        manageButton.bezelStyle = .rounded
        manageButton.controlSize = .mini
        if let img = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Gérer les icônes") {
            manageButton.image = img
            manageButton.imagePosition = .imageOnly
        } else {
            manageButton.title = "Gérer"
        }
        manageButton.toolTip = "Gérer les icônes (Barre / Dossier / Cachée)"
        manageButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(manageButton)

        let toggleButton = NSButton(
            title: isRevealed ? "Masquer" : "Afficher",
            target: self,
            action: #selector(handleToggleReveal)
        )
        toggleButton.bezelStyle = .rounded
        toggleButton.controlSize = .mini
        toggleButton.font = .systemFont(ofSize: 11, weight: .medium)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(toggleButton)

        var constraints: [NSLayoutConstraint] = [
            footer.widthAnchor.constraint(equalToConstant: width),
            footer.heightAnchor.constraint(equalToConstant: 32),
            countLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            toggleButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            toggleButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            manageButton.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -6),
            manageButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ]

        if !hasScreenRecording {
            let dot = NSTextField(labelWithString: "·")
            dot.font = .systemFont(ofSize: 11)
            dot.textColor = .tertiaryLabelColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(dot)

            let captureBtn = NSButton(
                title: "Aperçu réel…",
                target: self,
                action: #selector(handleRequestScreenRecording)
            )
            captureBtn.isBordered = false
            captureBtn.font = .systemFont(ofSize: 11)
            captureBtn.contentTintColor = .secondaryLabelColor
            captureBtn.toolTip = "Optionnel : autoriser Enregistrement de l’écran pour capturer les icônes exactes de la barre de menus."
            captureBtn.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(captureBtn)

            constraints.append(contentsOf: [
                dot.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 5),
                dot.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
                captureBtn.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
                captureBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
                captureBtn.trailingAnchor.constraint(lessThanOrEqualTo: manageButton.leadingAnchor, constant: -6)
            ])
        }

        NSLayoutConstraint.activate(constraints)
        return footer
    }

    private func makeCenteredCard(
        symbol: String,
        title: String,
        subtitle: String,
        primaryTitle: String,
        primaryAction: Selector,
        secondaryTitle: String?,
        secondaryAction: Selector?
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let iconView = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) ?? NSImage())
        iconView.contentTintColor = .secondaryLabelColor
        stack.addArrangedSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        let subLabel = NSTextField(wrappingLabelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 11.5)
        subLabel.textColor = .secondaryLabelColor
        subLabel.alignment = .center
        subLabel.preferredMaxLayoutWidth = 250
        stack.addArrangedSubview(subLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let primary = NSButton(title: primaryTitle, target: self, action: primaryAction)
        primary.bezelStyle = .rounded
        primary.controlSize = .small
        primary.keyEquivalent = "\r"
        buttons.addArrangedSubview(primary)

        if let secondaryTitle, let secondaryAction {
            let secondary = NSButton(title: secondaryTitle, target: self, action: secondaryAction)
            secondary.bezelStyle = .rounded
            secondary.controlSize = .small
            buttons.addArrangedSubview(secondary)
        }
        stack.addArrangedSubview(buttons)
        stack.widthAnchor.constraint(equalToConstant: 282).isActive = true
        return stack
    }

    @objc private func handleToggleReveal() {
        onToggleReveal?()
    }

    @objc private func handleOpenManager() {
        onOpenManager?()
    }

    @objc private func handleBackToGrid() {
        onBackToGrid?()
    }

    @objc private func handleRequestAccessibility() {
        closePanel()
        onRequestAccessibility?()
    }

    @objc private func handleRequestScreenRecording() {
        closePanel()
        onRequestScreenRecording?()
    }
}

// MARK: - Grid Tile View

@MainActor
private final class FolderTileView: NSView {
    private let item: MenuBarItem
    private let onOpen: (MenuBarItem) -> Void
    private let onChangePlacement: (MenuBarItem, IconPlacement) -> Void
    private let onContextMenuActive: (Bool) -> Void

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    init(
        item: MenuBarItem,
        onOpen: @escaping (MenuBarItem) -> Void,
        onChangePlacement: @escaping (MenuBarItem, IconPlacement) -> Void,
        onContextMenuActive: @escaping (Bool) -> Void
    ) {
        self.item = item
        self.onOpen = onOpen
        self.onChangePlacement = onChangePlacement
        self.onContextMenuActive = onContextMenuActive
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        toolTip = "\(item.tooltip)\nClic : ouvrir · Clic droit : options"

        imageView.image = item.capturedIcon ?? item.fallbackIcon
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        titleLabel.stringValue = item.displayName
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 56),
            imageView.heightAnchor.constraint(equalToConstant: 34),

            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 5),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyCapturedIcon(_ image: NSImage) {
        imageView.image = image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateHighlight()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateHighlight()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showTileMenu(with: event)
            return
        }
        isPressed = true
        updateHighlight()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateHighlight()
        if inside && !event.modifierFlags.contains(.control) {
            onOpen(item)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showTileMenu(with: event)
    }

    private func showTileMenu(with event: NSEvent) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Ouvrir", action: #selector(menuOpen), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let barItem = NSMenuItem(title: "Sortir dans la barre", action: #selector(menuMoveToBar), keyEquivalent: "")
        barItem.target = self
        menu.addItem(barItem)

        let hideItem = NSMenuItem(title: "Cacher du dossier", action: #selector(menuHideFromFolder), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        onContextMenuActive(true)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        onContextMenuActive(false)
    }

    @objc private func menuOpen() {
        onOpen(item)
    }

    @objc private func menuMoveToBar() {
        onChangePlacement(item, .bar)
    }

    @objc private func menuHideFromFolder() {
        onChangePlacement(item, .hidden)
    }

    private func updateHighlight() {
        if isPressed {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
        } else if isHovered {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - Manager Row View

@MainActor
private final class ManagerRowView: NSView {
    private let onSelectPlacement: (IconPlacement) -> Void
    private let segment: NSSegmentedControl

    init(item: MenuBarItem, isEnabled: Bool, onSelectPlacement: @escaping (IconPlacement) -> Void) {
        self.onSelectPlacement = onSelectPlacement
        self.segment = NSSegmentedControl(
            labels: ["Barre", "Dossier", "Cachée"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init(frame: .zero)

        let iconView = NSImageView(image: item.fallbackIcon)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: item.displayName)
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.toolTip = item.tooltip
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        segment.controlSize = .small
        segment.segmentStyle = .rounded
        segment.selectedSegment = item.placement.rawValue
        segment.isEnabled = isEnabled
        segment.target = self
        segment.action = #selector(segmentChanged(_:))
        segment.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segment)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: segment.leadingAnchor, constant: -8),

            segment.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            segment.centerYAnchor.constraint(equalTo: centerYAnchor),
            segment.widthAnchor.constraint(equalToConstant: 170)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        guard let placement = IconPlacement(rawValue: sender.selectedSegment) else { return }
        onSelectPlacement(placement)
    }
}

private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}
