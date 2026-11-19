import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum PanelMode {
        case grid
        case manager
    }

    private var statusBar: StatusBarController!
    private let service = MenuBarService()
    private var panel: FolderPanel!
    private var panelMode: PanelMode = .grid
    private var cachedItems: [MenuBarItem] = []
    private var managerStatusMessage: String?
    private var isMovingItem = false
    private var captureTask: Task<Void, Never>?
    private var discoveryGeneration = 0
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        statusBar = StatusBarController()
        panel = FolderPanel()

        statusBar.onLeftClick = { [weak self] in
            self?.toggleGridPanel()
        }
        statusBar.onOpenManager = { [weak self] in
            self?.openManagerPanel()
        }
        statusBar.onToggleReveal = { [weak self] in
            guard let self, self.panel.isVisible, !self.isMovingItem else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.panel.isVisible, !self.isMovingItem else { return }
                self.refreshPanelContents()
            }
        }
        statusBar.onQuit = {
            NSApp.terminate(nil)
        }

        panel.onSelectItem = { [weak self] item in
            self?.activateFromGrid(item)
        }
        panel.onChangePlacement = { [weak self] item, target in
            self?.handleChangePlacement(item, to: target)
        }
        panel.onOpenManager = { [weak self] in
            self?.openManagerPanel()
        }
        panel.onBackToGrid = { [weak self] in
            self?.panelMode = .grid
            self?.managerStatusMessage = nil
            self?.refreshPanelContents()
        }
        panel.onToggleReveal = { [weak self] in
            self?.statusBar.toggleRevealed()
        }
        panel.onRequestAccessibility = { [weak self] in
            self?.service.requestAccessibilityAccess()
        }
        panel.onRequestScreenRecording = { [weak self] in
            self?.service.requestScreenRecordingAccess()
        }
        panel.onDidClose = { [weak self] in
            self?.stopCaptures()
            self?.managerStatusMessage = nil
        }

        installSignalHandlers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaptures()
        panel?.closePanel()
        statusBar?.cleanupForTermination()
    }

    private func toggleGridPanel() {
        if panel.isVisible {
            panel.closePanel()
            return
        }
        panelMode = .grid
        managerStatusMessage = nil
        refreshPanelContents(showLoadingIfNeeded: true)
    }

    private func openManagerPanel() {
        panelMode = .manager
        managerStatusMessage = nil
        refreshPanelContents(showLoadingIfNeeded: !panel.isVisible)
    }

    private func refreshPanelContents(showLoadingIfNeeded: Bool = false) {
        stopCaptures()
        discoveryGeneration += 1
        let generation = discoveryGeneration

        guard let buttonRect = statusBar.buttonWindowFrame else { return }
        let screen = statusBar.buttonScreen

        guard service.isAccessibilityTrusted else {
            panel.showAccessibilityRequired(
                isRevealed: statusBar.isRevealed,
                anchoredBelow: buttonRect,
                on: screen
            )
            return
        }

        if showLoadingIfNeeded && !panel.isVisible {
            panel.showLoading(anchoredBelow: buttonRect, on: screen)
        }

        let sepMinX = statusBar.separatorMinX
        let topY = statusBar.menuBarQuartzTopY
        let hasScreenRec = service.hasScreenRecordingAccess
        let scale = screen.backingScaleFactor
        let targetMode = panelMode

        service.discoverMenuBarItems(separatorMinX: sepMinX, menuBarTopY: topY) { [weak self] allItems in
            guard let self, self.discoveryGeneration == generation else { return }
            if showLoadingIfNeeded && !self.panel.isVisible { return }

            self.cachedItems = allItems
            let liveRect = self.statusBar.buttonWindowFrame ?? buttonRect
            let liveScreen = self.statusBar.buttonScreen

            switch targetMode {
            case .grid:
                let folderItems = allItems.filter { $0.placement == .folder }
                let hiddenCount = allItems.filter { $0.placement == .hidden }.count
                self.panel.showItems(
                    folderItems,
                    hiddenCount: hiddenCount,
                    isRevealed: self.statusBar.isRevealed,
                    hasScreenRecording: hasScreenRec,
                    anchoredBelow: liveRect,
                    on: liveScreen
                )
                self.captureTask = self.service.captureIconsOnDemand(for: folderItems, backingScale: scale) { [weak self] id, image in
                    guard let self, self.panel.isVisible, self.panelMode == .grid, self.discoveryGeneration == generation else { return }
                    self.panel.updateCapturedIcon(itemID: id, image: image)
                }

            case .manager:
                self.panel.showManager(
                    items: allItems,
                    isRevealed: self.statusBar.isRevealed,
                    isBusy: self.isMovingItem,
                    statusMessage: self.managerStatusMessage,
                    anchoredBelow: liveRect,
                    on: liveScreen
                )
            }
        }
    }

    private func handleChangePlacement(_ item: MenuBarItem, to target: IconPlacement) {
        guard !isMovingItem else { return }
        isMovingItem = true
        managerStatusMessage = nil

        let needsDrag = (item.placement == .bar) != (target == .bar)
        if needsDrag {
            panel.suppressAutoDismiss = true
        }

        if panelMode == .manager, let rect = statusBar.buttonWindowFrame {
            panel.showManager(
                items: cachedItems,
                isRevealed: statusBar.isRevealed,
                isBusy: true,
                statusMessage: nil,
                anchoredBelow: rect,
                on: statusBar.buttonScreen
            )
        }

        service.moveItem(item, to: target, statusBar: statusBar) { [weak self] result in
            guard let self else { return }
            self.isMovingItem = false
            self.panel.suppressAutoDismiss = false

            switch result {
            case .moved:
                self.managerStatusMessage = nil
            case .blockedByNotch:
                self.managerStatusMessage = "Masquée par l’encoche : libérez de la place ou révélez pour déplacer."
            case .failed:
                self.managerStatusMessage = "Déplacement impossible pour \(item.displayName)."
            }

            if self.panel.isVisible {
                self.refreshPanelContents()
            }
        }
    }

    private func activateFromGrid(_ item: MenuBarItem) {
        panel.closePanel()
        service.activateItem(item, statusBar: statusBar) { [weak self] in
            self?.statusBar.setRevealed(true)
        }
    }

    private func stopCaptures() {
        captureTask?.cancel()
        captureTask = nil
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
