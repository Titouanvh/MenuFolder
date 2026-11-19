import Cocoa
@preconcurrency import ApplicationServices
import ScreenCaptureKit

enum IconPlacement: Int, Sendable {
    case bar = 0      // Affichée dans la barre de menus (à droite du séparateur)
    case folder = 1   // Rangée dans le dossier (à gauche du séparateur, visible dans la grille)
    case hidden = 2   // Cachée (à gauche du séparateur, exclue de la grille)
}

enum IconMoveResult: Sendable {
    case moved
    case blockedByNotch
    case failed
}

struct MenuBarItem: @unchecked Sendable {
    let id: String
    let persistentKey: String
    let pid: pid_t
    let index: Int
    let bundleIdentifier: String?
    let displayName: String
    let tooltip: String
    let axFrame: CGRect
    let axElement: AXUIElement
    let windowID: CGWindowID?
    let fallbackIcon: NSImage
    var capturedIcon: NSImage?
    var placement: IconPlacement
}

private struct StatusWindowSnapshot: Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let rect: CGRect
    let isControlCenter: Bool
}

final class MenuBarService: @unchecked Sendable {
    private static let axTimeout: Float = 0.5
    private static let controlCenterBundleID = "com.apple.controlcenter"
    private static let hiddenKeysDefaultsKey = "MenuFolder.HiddenFromFolderKeys"

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    var hasScreenRecordingAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    var hiddenFromFolderKeys: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKeysDefaultsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.hiddenKeysDefaultsKey)
        }
    }

    func setHiddenFromFolder(_ hidden: Bool, forKey key: String) {
        var keys = hiddenFromFolderKeys
        if hidden {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        hiddenFromFolderKeys = keys
    }

    func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestScreenRecordingAccess() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Discovery (Public AXUIElement + CGWindowListCopyWindowInfo)

    func discoverMenuBarItems(
        separatorMinX: CGFloat,
        menuBarTopY: CGFloat,
        completion: @escaping @MainActor ([MenuBarItem]) -> Void
    ) {
        guard isAccessibilityTrusted else {
            Task { @MainActor in completion([]) }
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let hiddenKeys = hiddenFromFolderKeys
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated,
                  app.processIdentifier != ownPID,
                  app.activationPolicy != .prohibited else { return false }
            if let url = app.bundleURL {
                let ext = url.pathExtension.lowercased()
                if ext == "xpc" || ext == "appex" { return false }
                let path = url.path
                if path.contains("/XPCServices/") || path.contains("/Frameworks/") { return false }
            }
            if let bid = app.bundleIdentifier, bid.hasPrefix("com.apple.WebKit.") { return false }
            return true
        }

        struct CandidateInfo: Sendable {
            let pid: pid_t
            let bundleID: String?
            let name: String
            let bundlePath: String?
        }

        let candidateInfos = candidates.map {
            CandidateInfo(
                pid: $0.processIdentifier,
                bundleID: $0.bundleIdentifier,
                name: $0.localizedName ?? "App",
                bundlePath: $0.bundleURL?.path
            )
        }

        let controlCenterPID = candidates
            .first(where: { $0.bundleIdentifier == Self.controlCenterBundleID })?
            .processIdentifier

        DispatchQueue.global(qos: .userInitiated).async {
            let statusWindows = Self.snapshotStatusWindows(controlCenterPID: controlCenterPID)
            let lock = NSLock()
            var discovered: [MenuBarItem] = []

            // Bounded concurrency avoids Mach IPC contention on the Accessibility subsystem.
            DispatchQueue.concurrentPerform(iterations: candidateInfos.count) { idx in
                let info = candidateInfos[idx]
                let items = Self.scanAppExtras(
                    pid: info.pid,
                    bundleID: info.bundleID,
                    appName: info.name,
                    bundlePath: info.bundlePath,
                    separatorMinX: separatorMinX,
                    menuBarTopY: menuBarTopY,
                    hiddenKeys: hiddenKeys,
                    statusWindows: statusWindows
                )
                if !items.isEmpty {
                    lock.lock()
                    discovered.append(contentsOf: items)
                    lock.unlock()
                }
            }

            discovered.sort { lhs, rhs in
                if lhs.axFrame.minX != rhs.axFrame.minX {
                    return lhs.axFrame.minX < rhs.axFrame.minX
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

            Task { @MainActor in
                completion(discovered)
            }
        }
    }

    private static func snapshotStatusWindows(controlCenterPID: pid_t?) -> [StatusWindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [StatusWindowSnapshot] = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 25,
                  let wid = entry[kCGWindowNumber as String] as? UInt32,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }

            let rect = CGRect(
                x: bounds["X"] as? Double ?? 0,
                y: bounds["Y"] as? Double ?? 0,
                width: bounds["Width"] as? Double ?? 0,
                height: bounds["Height"] as? Double ?? 0
            )
            let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            guard rect.width > 0, rect.width < 2000, rect.height > 0, rect.height <= 44 else { continue }
            if !onScreen && rect.minX == 0 { continue }

            result.append(StatusWindowSnapshot(
                windowID: wid,
                ownerPID: pid_t(ownerPID),
                rect: rect,
                isControlCenter: controlCenterPID.map { pid_t(ownerPID) == $0 } ?? false
            ))
        }
        return result
    }

    private static func scanAppExtras(
        pid: pid_t,
        bundleID: String?,
        appName: String,
        bundlePath: String?,
        separatorMinX: CGFloat,
        menuBarTopY: CGFloat,
        hiddenKeys: Set<String>,
        statusWindows: [StatusWindowSnapshot]
    ) -> [MenuBarItem] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)

        var extrasObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &extrasObj) == .success,
              let extrasObj else { return [] }
        let extrasBar = extrasObj as! AXUIElement
        AXUIElementSetMessagingTimeout(extrasBar, axTimeout)

        var childrenObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extrasBar, kAXChildrenAttribute as CFString, &childrenObj) == .success,
              let children = childrenObj as? [AXUIElement], !children.isEmpty else { return [] }

        var items: [MenuBarItem] = []
        for (index, element) in children.enumerated() {
            AXUIElementSetMessagingTimeout(element, axTimeout)
            let attrs = axReadAttributes(element)
            guard let frame = attrs.frame,
                  frame.width > 1, frame.height > 1,
                  frame.minY >= menuBarTopY - 12, frame.minY <= menuBarTopY + 52 else { continue }

            let title = attrs.title
            let desc = attrs.desc
            let value = attrs.value

            let label = resolveDisplayName(
                appName: appName,
                bundleID: bundleID,
                title: title,
                desc: desc,
                siblingCount: children.count
            )

            // Skip macOS-locked anchors (Clock & Control Center) that macOS never lets users drag.
            if isSystemPinnedAnchor(bundleID: bundleID, label: label, desc: desc) {
                continue
            }

            let baseKey = bundleID ?? appName
            let persistentKey = (bundleID == controlCenterBundleID || children.count > 1)
                ? "\(baseKey)#\(label)"
                : baseKey

            let isLeftOfSeparator = frame.midX < separatorMinX + 2
            let placement: IconPlacement
            if !isLeftOfSeparator {
                placement = .bar
            } else if hiddenKeys.contains(persistentKey) {
                placement = .hidden
            } else {
                placement = .folder
            }

            let tooltipParts = [label, value.isEmpty ? (desc != label ? desc : "") : value]
                .filter { !$0.isEmpty }
            let tooltip = tooltipParts.joined(separator: " · ")

            let matchedWID = matchWindowID(for: pid, axFrame: frame, statusWindows: statusWindows)
            let fallbackIcon = resolveFallbackIcon(
                bundleID: bundleID,
                bundlePath: bundlePath,
                label: label,
                desc: desc
            )

            items.append(MenuBarItem(
                id: "\(pid):\(index)",
                persistentKey: persistentKey,
                pid: pid,
                index: index,
                bundleIdentifier: bundleID,
                displayName: label,
                tooltip: tooltip,
                axFrame: frame,
                axElement: element,
                windowID: matchedWID,
                fallbackIcon: fallbackIcon,
                capturedIcon: nil,
                placement: placement
            ))
        }
        return items
    }

    private static func isSystemPinnedAnchor(bundleID: String?, label: String, desc: String) -> Bool {
        guard bundleID == controlCenterBundleID else { return false }
        let hay = "\(label) \(desc)".lowercased()
        return hay.contains("horloge")
            || hay.contains("clock")
            || hay.contains("centre de contrôle")
            || hay.contains("control center")
    }

    private static func matchWindowID(
        for pid: pid_t,
        axFrame: CGRect,
        statusWindows: [StatusWindowSnapshot]
    ) -> CGWindowID? {
        let candidates = statusWindows.filter { $0.ownerPID == pid || $0.isControlCenter }
        var best: (wid: CGWindowID, delta: CGFloat)?
        for win in candidates {
            let delta = abs(win.rect.midX - axFrame.midX)
            if delta <= 14, best == nil || delta < best!.delta {
                best = (win.windowID, delta)
            }
        }
        return best?.wid
    }

    private static func resolveDisplayName(
        appName: String,
        bundleID: String?,
        title: String,
        desc: String,
        siblingCount: Int
    ) -> String {
        if bundleID == controlCenterBundleID {
            let raw = !desc.isEmpty ? desc : title
            if let primary = raw.split(separator: ",").first, !primary.isEmpty {
                return String(primary).trimmingCharacters(in: .whitespaces)
            }
            return appName
        }
        if siblingCount > 1 {
            let extra = !title.isEmpty ? title : desc
            if !extra.isEmpty && extra.caseInsensitiveCompare(appName) != .orderedSame {
                return extra
            }
        }
        return appName
    }

    private static func resolveFallbackIcon(
        bundleID: String?,
        bundlePath: String?,
        label: String,
        desc: String
    ) -> NSImage {
        let haystack = "\(label) \(desc)".lowercased()
        if bundleID == controlCenterBundleID || bundleID == "com.apple.Spotlight" || bundleID == "com.apple.TextInputMenuAgent" {
            let symbolName: String
            if haystack.contains("wi-fi") || haystack.contains("wi\u{2011}fi") || haystack.contains("wifi") {
                symbolName = "wifi"
            } else if haystack.contains("bluetooth") {
                symbolName = "dot.radiowaves.left.and.right"
            } else if haystack.contains("batter") {
                symbolName = "battery.100"
            } else if haystack.contains("son") || haystack.contains("sound") || haystack.contains("volume") {
                symbolName = "speaker.wave.2.fill"
            } else if haystack.contains("horloge") || haystack.contains("clock") {
                symbolName = "clock"
            } else if haystack.contains("spotlight") || haystack.contains("recherch") || haystack.contains("search") {
                symbolName = "magnifyingglass"
            } else if haystack.contains("concentration") || haystack.contains("focus") {
                symbolName = "moon.fill"
            } else if haystack.contains("recopie") || haystack.contains("display") || haystack.contains("airplay") {
                symbolName = "airplayvideo"
            } else if haystack.contains("clavier") || haystack.contains("saisie") || haystack.contains("input") {
                symbolName = "keyboard"
            } else if haystack.contains("écoute") || haystack.contains("ecoute") || haystack.contains("playing") {
                symbolName = "play.circle"
            } else {
                symbolName = "switch.2"
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?.withSymbolConfiguration(cfg) {
                sym.isTemplate = true
                return sym
            }
        }

        if let path = bundlePath {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 32, height: 32)
            return icon
        }
        let generic = NSImage(systemSymbolName: "app", accessibilityDescription: label) ?? NSImage()
        generic.isTemplate = true
        return generic
    }

    // MARK: - On-Demand Icon Capture (ScreenCaptureKit, cancelled immediately on grid close)

    func captureIconsOnDemand(
        for items: [MenuBarItem],
        backingScale: CGFloat,
        onImage: @escaping @MainActor (String, NSImage) -> Void
    ) -> Task<Void, Never>? {
        guard hasScreenRecordingAccess else { return nil }
        let targets = items.compactMap { item -> (id: String, wid: CGWindowID)? in
            guard let wid = item.windowID else { return nil }
            return (item.id, wid)
        }
        guard !targets.isEmpty else { return nil }

        return Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                return
            }
            guard !Task.isCancelled else { return }

            let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
            for target in targets {
                guard !Task.isCancelled else { return }
                guard let scWindow = windowsByID[target.wid],
                      scWindow.frame.width > 0, scWindow.frame.height > 0 else { continue }

                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                config.width = max(1, Int((scWindow.frame.width * backingScale).rounded()))
                config.height = max(1, Int((scWindow.frame.height * backingScale).rounded()))
                config.scalesToFit = true
                config.showsCursor = false
                config.backgroundColor = .clear
                config.ignoreShadowsSingleWindow = true

                guard let cgImage = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                ) else { continue }
                guard !Task.isCancelled, Self.hasVisiblePixels(cgImage) else { continue }

                let image = NSImage(cgImage: cgImage, size: scWindow.frame.size)
                await MainActor.run {
                    onImage(target.id, image)
                }
            }
        }
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let w = min(image.width, 64)
        let h = min(image.height, 64)
        guard w > 0, h > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var nonEmpty = 0
        for i in stride(from: 3, to: buffer.count, by: 4) where buffer[i] > 16 {
            nonEmpty += 1
            if nonEmpty >= 8 { return true }
        }
        return false
    }

    // MARK: - Programmatic Icon Placement (Barre / Dossier / Cachée)

    @MainActor
    func moveItem(
        _ item: MenuBarItem,
        to target: IconPlacement,
        statusBar: StatusBarController,
        completion: @escaping @MainActor (IconMoveResult) -> Void
    ) {
        guard isAccessibilityTrusted else {
            completion(.failed)
            return
        }
        if item.placement == target {
            completion(.moved)
            return
        }

        // Folder <-> Hidden only toggles visibility inside the grid; no menu bar drag needed.
        let currentlyLeft = item.placement != .bar
        let targetLeft = target != .bar
        if currentlyLeft == targetLeft {
            setHiddenFromFolder(target == .hidden, forKey: item.persistentKey)
            completion(.moved)
            return
        }

        // Moving across the separator via public CGEvent Cmd-drag.
        let movingOutToBar = !targetLeft
        let screen = statusBar.buttonScreen
        let notchRightEdge = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        let notchDropX: CGFloat = {
            if let auxL = screen.auxiliaryTopLeftArea {
                return auxL.maxX + 40
            }
            return max(40, screen.frame.minX + 40)
        }()
        let menuBarTopY = statusBar.menuBarQuartzTopY
        let ownPID = ProcessInfo.processInfo.processIdentifier

        statusBar.beginDragLayout(shrinkButton: true)

        waitForUnspaced(ownPID: ownPID, pid: item.pid, index: item.index, attempt: 0) { [weak statusBar] initialFrame in
            guard let statusBar else {
                completion(.failed)
                return
            }
            guard let initialFrame, initialFrame.width > 1 else {
                statusBar.endDragLayout()
                completion(.failed)
                return
            }

            let btnFrame = statusBar.buttonWindowFrame ?? .zero
            let sepFrame = statusBar.separatorWindowFrame ?? btnFrame
            let screenMaxX = screen.frame.maxX

            DispatchQueue.global(qos: .userInitiated).async {
                let savedCursor = CGEvent(source: nil)?.location
                defer {
                    if let savedCursor {
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: savedCursor, mouseButton: .left)?
                            .post(tap: .cghidEventTap)
                    }
                }

                var liveFrame = initialFrame
                var currentSepMinX = sepFrame.minX

                // If pulling an icon out to the bar and it is clipped behind the notch by other folder icons,
                // rotate the widest visible folder-side icons to the far left (behind the notch) so the target slides out.
                if movingOutToBar && !Self.isDraggableOnScreen(liveFrame, notchRightEdge: notchRightEdge) {
                    for _ in 0..<8 {
                        if Self.isDraggableOnScreen(liveFrame, notchRightEdge: notchRightEdge) { break }
                        guard let blocker = Self.findWidestVisibleFolderBlocker(
                            excludingPID: item.pid,
                            excludingIndex: item.index,
                            ownPID: ownPID,
                            minXGreaterThan: liveFrame.minX,
                            sepMinX: currentSepMinX,
                            notchRightEdge: notchRightEdge,
                            menuBarTopY: menuBarTopY
                        ) else {
                            break
                        }

                        Self.performCommandDrag(
                            from: CGPoint(x: blocker.midX, y: blocker.midY),
                            to: CGPoint(x: notchDropX, y: blocker.midY),
                            restoreCursor: false
                        )
                        usleep(180_000)

                        if let refreshed = Self.fetchAXMenuExtra(pid: item.pid, index: item.index).flatMap(Self.axFrame(of:)) {
                            liveFrame = refreshed
                        }
                        if let sepNow = Self.fetchOwnSeparatorMinX(ownPID: ownPID) {
                            currentSepMinX = sepNow
                        }
                    }
                }

                guard Self.isDraggableOnScreen(liveFrame, notchRightEdge: notchRightEdge) else {
                    Task { @MainActor in
                        statusBar.endDragLayout()
                        completion(.blockedByNotch)
                    }
                    return
                }

                let liveBtnMaxX = Self.fetchOwnMainButtonMaxX(ownPID: ownPID) ?? btnFrame.maxX
                let targetX: CGFloat
                if movingOutToBar {
                    // Drop strictly to the right of the separator / main button, left of Clock & Control Center.
                    targetX = min(screenMaxX - 180, max(currentSepMinX + 26, liveBtnMaxX + 14))
                } else {
                    // Drop strictly to the left of the separator (dropping inside the notch works on macOS 26).
                    targetX = max(notchDropX, currentSepMinX - 24)
                }

                Self.performCommandDrag(
                    from: CGPoint(x: liveFrame.midX, y: liveFrame.midY),
                    to: CGPoint(x: targetX, y: liveFrame.midY),
                    restoreCursor: false
                )

                Task { @MainActor in
                    statusBar.endDragLayout()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        let sepMinXAfter = statusBar.separatorMinX
                        guard let afterEl = Self.fetchAXMenuExtra(pid: item.pid, index: item.index),
                              let afterFrame = Self.axFrame(of: afterEl) else {
                            completion(.failed)
                            return
                        }
                        let isNowLeft = afterFrame.midX < sepMinXAfter + 2
                        if isNowLeft == targetLeft {
                            self.setHiddenFromFolder(target == .hidden, forKey: item.persistentKey)
                            completion(.moved)
                        } else {
                            completion(.failed)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func waitForUnspaced(
        ownPID: pid_t,
        pid: pid_t,
        index: Int,
        attempt: Int,
        completion: @escaping @MainActor (CGRect?) -> Void
    ) {
        let sepReady = (Self.fetchOwnSeparatorMinX(ownPID: ownPID) ?? -1) >= 0
        if sepReady,
           let el = Self.fetchAXMenuExtra(pid: pid, index: index),
           let frame = Self.axFrame(of: el),
           frame.minX > -1500 {
            // Brief settle beat for Control Center window onScreen flags.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                let settled = Self.fetchAXMenuExtra(pid: pid, index: index).flatMap(Self.axFrame(of:)) ?? frame
                completion(settled)
            }
            return
        }
        if attempt >= 24 {
            completion(Self.fetchAXMenuExtra(pid: pid, index: index).flatMap(Self.axFrame(of:)))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            self.waitForUnspaced(ownPID: ownPID, pid: pid, index: index, attempt: attempt + 1, completion: completion)
        }
    }

    private static func isDraggableOnScreen(_ frame: CGRect, notchRightEdge: CGFloat) -> Bool {
        frame.minX >= notchRightEdge - 1 && isStatusWindowOnScreen(atMidX: frame.midX)
    }

    private static func findWidestVisibleFolderBlocker(
        excludingPID: pid_t,
        excludingIndex: Int,
        ownPID: pid_t,
        minXGreaterThan targetMinX: CGFloat,
        sepMinX: CGFloat,
        notchRightEdge: CGFloat,
        menuBarTopY: CGFloat
    ) -> CGRect? {
        var best: CGRect?
        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated,
                  app.processIdentifier != ownPID,
                  app.activationPolicy != .prohibited else { continue }
            if let url = app.bundleURL {
                let ext = url.pathExtension.lowercased()
                if ext == "xpc" || ext == "appex" { continue }
                if url.path.contains("/XPCServices/") || url.path.contains("/Frameworks/") { continue }
            }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.2)
            var extrasObj: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &extrasObj) == .success,
                  let extrasObj else { continue }
            var childrenObj: CFTypeRef?
            guard AXUIElementCopyAttributeValue(extrasObj as! AXUIElement, kAXChildrenAttribute as CFString, &childrenObj) == .success,
                  let children = childrenObj as? [AXUIElement] else { continue }
            for (idx, el) in children.enumerated() {
                if app.processIdentifier == excludingPID && idx == excludingIndex { continue }
                guard let f = axFrame(of: el),
                      f.width > 1, f.height > 1,
                      f.minY >= menuBarTopY - 12, f.minY <= menuBarTopY + 52,
                      f.midX < sepMinX - 2,
                      f.minX > targetMinX + 1,
                      isDraggableOnScreen(f, notchRightEdge: notchRightEdge) else { continue }
                if best == nil || f.width > best!.width {
                    best = f
                }
            }
        }
        return best
    }

    private static func fetchOwnSeparatorMinX(ownPID: pid_t) -> CGFloat? {
        let axApp = AXUIElementCreateApplication(ownPID)
        var ex: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &ex) == .success,
              let ex else { return nil }
        var ch: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ex as! AXUIElement, kAXChildrenAttribute as CFString, &ch) == .success,
              let arr = ch as? [AXUIElement] else { return nil }
        for el in arr {
            if axString(el, kAXDescriptionAttribute) != "MenuFolder", let f = axFrame(of: el) {
                return f.minX
            }
        }
        return nil
    }

    private static func fetchOwnMainButtonMaxX(ownPID: pid_t) -> CGFloat? {
        let axApp = AXUIElementCreateApplication(ownPID)
        var ex: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &ex) == .success,
              let ex else { return nil }
        var ch: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ex as! AXUIElement, kAXChildrenAttribute as CFString, &ch) == .success,
              let arr = ch as? [AXUIElement] else { return nil }
        for el in arr {
            if axString(el, kAXDescriptionAttribute) == "MenuFolder", let f = axFrame(of: el) {
                return f.maxX
            }
        }
        return nil
    }

    private static func isStatusWindowOnScreen(atMidX midX: CGFloat) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 25,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = bounds["X"] as? Double ?? 0
            let w = bounds["Width"] as? Double ?? 0
            let h = bounds["Height"] as? Double ?? 0
            guard w > 0, w < 2000, h > 0, h <= 44 else { continue }
            if midX >= x - 2 && midX <= x + w + 2 {
                return true
            }
        }
        return false
    }

    private static func performCommandDrag(from: CGPoint, to: CGPoint, restoreCursor: Bool = true) {
        let savedCursor = restoreCursor ? CGEvent(source: nil)?.location : nil
        let src = CGEventSource(stateID: .hidSystemState)

        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true)
        cmdDown?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        usleep(50_000)

        let moveStart = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left)
        moveStart?.flags = .maskCommand
        moveStart?.post(tap: .cghidEventTap)
        usleep(50_000)

        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(85_000)

        let steps = 18
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            let drag = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left)
            drag?.flags = .maskCommand
            drag?.post(tap: .cghidEventTap)
            usleep(12_000)
        }

        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
        usleep(65_000)

        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)
        cmdUp?.flags = []
        cmdUp?.post(tap: .cghidEventTap)
        usleep(40_000)

        if let savedCursor {
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: savedCursor, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        usleep(100_000)
    }

    // MARK: - Activation (Temporarily reveals spacer -> AXPress -> immediately re-hides)

    @MainActor
    func activateItem(
        _ item: MenuBarItem,
        secondaryAction: Bool = false,
        statusBar: StatusBarController,
        onFailure: @escaping @MainActor () -> Void
    ) {
        guard isAccessibilityTrusted else {
            onFailure()
            return
        }

        let wasCollapsed = !statusBar.isRevealed
        let beforeWinIDs = Self.onScreenWindowIDs(for: item.pid)

        if wasCollapsed {
            statusBar.beginTemporaryReveal()
        }

        waitUntilOnScreen(pid: item.pid, index: item.index, fallback: item.axElement, attempt: 0) { [weak statusBar] liveElement in
            guard let statusBar else { return }
            guard let targetElement = liveElement else {
                onFailure()
                return
            }

            let action = Self.chooseAction(for: targetElement, secondary: secondaryAction)
            let startTime = Date()
            var didFail = false
            var axFinished = false

            DispatchQueue.global(qos: .userInitiated).async {
                let err = AXUIElementPerformAction(targetElement, action as CFString)
                let elapsed = Date().timeIntervalSince(startTime)
                Task { @MainActor in
                    axFinished = true
                    if err != .success && elapsed < 1.0 {
                        didFail = true
                        onFailure()
                    }
                }
            }

            guard wasCollapsed else { return }

            @MainActor
            func checkReCollapse(step: Int) {
                if didFail { return }
                let openedPopup = !Self.onScreenWindowIDs(for: item.pid).subtracting(beforeWinIDs).isEmpty
                let shouldRestore = (openedPopup && step >= 2) || (axFinished && step >= 2) || step >= 7
                if shouldRestore {
                    statusBar.endTemporaryReveal()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            checkReCollapse(step: step + 1)
                        }
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Task { @MainActor in
                    checkReCollapse(step: 1)
                }
            }
        }
    }

    @MainActor
    private func waitUntilOnScreen(
        pid: pid_t,
        index: Int,
        fallback: AXUIElement,
        attempt: Int,
        completion: @escaping @MainActor (AXUIElement?) -> Void
    ) {
        let element = Self.fetchAXMenuExtra(pid: pid, index: index) ?? fallback
        if let frame = Self.axFrame(of: element), frame.minX >= 0 {
            completion(element)
            return
        }
        if attempt >= 16 {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            self.waitUntilOnScreen(pid: pid, index: index, fallback: fallback, attempt: attempt + 1, completion: completion)
        }
    }

    private static func fetchAXMenuExtra(pid: pid_t, index: Int) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, axTimeout)
        var extrasObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &extrasObj) == .success,
              let extrasObj else { return nil }
        var childrenObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extrasObj as! AXUIElement, kAXChildrenAttribute as CFString, &childrenObj) == .success,
              let children = childrenObj as? [AXUIElement],
              index >= 0, index < children.count else { return nil }
        return children[index]
    }

    private static func chooseAction(for element: AXUIElement, secondary: Bool) -> String {
        if secondary {
            var actionsRef: CFArray?
            if AXUIElementCopyActionNames(element, &actionsRef) == .success,
               let actions = actionsRef as? [String],
               actions.contains(kAXShowMenuAction as String) {
                return kAXShowMenuAction as String
            }
        }
        return kAXPressAction as String
    }

    private static func onScreenWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for w in list {
            if pid_t(w[kCGWindowOwnerPID as String] as? Int ?? -1) == pid,
               let wid = w[kCGWindowNumber as String] as? UInt32 {
                ids.insert(wid)
            }
        }
        return ids
    }

    // MARK: - AX Helpers

    private static func axReadAttributes(_ element: AXUIElement) -> (frame: CGRect?, title: String, desc: String, value: String) {
        let keys: [CFString] = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXValueAttribute as CFString
        ]
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &valuesRef)
        if err == .success, let arr = valuesRef as? [Any], arr.count == 5 {
            var pt = CGPoint.zero
            var sz = CGSize.zero
            var hasPos = false
            var hasSize = false
            if CFGetTypeID(arr[0] as CFTypeRef) == AXValueGetTypeID() {
                hasPos = AXValueGetValue(arr[0] as! AXValue, .cgPoint, &pt)
            }
            if CFGetTypeID(arr[1] as CFTypeRef) == AXValueGetTypeID() {
                hasSize = AXValueGetValue(arr[1] as! AXValue, .cgSize, &sz)
            }
            let frame = (hasPos && hasSize) ? CGRect(origin: pt, size: sz) : nil
            let title = (arr[2] as? String) ?? ""
            let desc = (arr[3] as? String) ?? ""
            let value = (arr[4] as? String) ?? ""
            return (frame, title, desc, value)
        }
        return (
            axFrame(of: element),
            axString(element, kAXTitleAttribute) ?? "",
            axString(element, kAXDescriptionAttribute) ?? "",
            axString(element, kAXValueAttribute) ?? ""
        )
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posObj: CFTypeRef?
        var sizeObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posObj) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeObj) == .success,
              let posVal = posObj, let sizeVal = sizeObj else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
