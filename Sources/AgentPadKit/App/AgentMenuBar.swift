import AppKit
import AgentPadHookKit
import Observation

/// App-level menu-bar view of `AgentMonitor` — the same cross-window agent
/// set that feeds the right sidebar. AppKit owns only the `NSStatusItem` and
/// native menu lifecycle; `AgentMonitor` remains the single source of truth.
@MainActor
final class AgentMenuBarController: NSObject, NSMenuDelegate {
    private let monitor: AgentMonitor
    private let settings: AgentPadSettingsModel
    private let onOpenAgentPad: () -> Void
    private let onOpenSettings: () -> Void
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var observing = false

    init(
        monitor: AgentMonitor = .shared,
        settings: AgentPadSettingsModel = .shared,
        onOpenAgentPad: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.onOpenAgentPad = onOpenAgentPad
        self.onOpenSettings = onOpenSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// Starts a one-shot Observation loop. `AgentMonitor.entries` reads every
    /// session field that decides membership, so an agent starting/ending and
    /// a window being added/removed both refresh the count without a parallel
    /// notification system.
    func start() {
        guard !observing else { return }
        observing = true
        observe()
    }

    func stop() {
        observing = false
        removeStatusItem()
    }

    private func observe() {
        guard observing else { return }
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            // Observation fires at willSet. Read the settled model values on
            // the next main-actor turn, then register the one-shot tracker again.
            Task { @MainActor in self?.observe() }
        }
    }

    /// Last count actually written to the button. Every title / cwd change
    /// used to rewrite all four NSStatusItem fields (relayout + an
    /// accessibility post each) even though the rendered text was identical.
    private var lastRenderedCount: Int?

    private func refresh() {
        guard settings.showInMenuBar else {
            removeStatusItem()
            return
        }
        // `activeAgentCount`, not `entries`: the count-only walk keeps
        // titles/paths OUT of the observation set, so OSC title churn from a
        // busy agent no longer re-runs this at all.
        let count = monitor.activeAgentCount
        // nil lastRenderedCount (fresh item, or just removed) never equals
        // a real count, so the first render always writes.
        if count == lastRenderedCount { return }
        let item = ensureStatusItem()
        guard let button = item.button else { return }
        lastRenderedCount = count
        button.title = Self.countTitle(count)
        button.imagePosition = count == 0 ? .imageOnly : .imageLeading
        button.toolTip = count == 0
            ? String(localized: "No agents running", bundle: .agentPadResources)
            : String.localizedStringWithFormat(
                String(
                    localized: String.LocalizationValue(
                        count == 1 ? "%d agent active" : "%d agents active"
                    ),
                    bundle: .agentPadResources
                ),
                count
            )
        button.setAccessibilityLabel(button.toolTip)
    }

    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem { return statusItem }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = AgentPadMenuBarIcon.make()
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }
        item.menu = menu
        statusItem = item
        return item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        lastRenderedCount = nil
    }

    // Rebuild at open time so titles, paths, states, ordering, and the session
    // set are current even if AppKit kept the native menu object around.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = monitor.entries
        if entries.isEmpty {
            let empty = NSMenuItem(
                title: String(localized: "No agents running", bundle: .agentPadResources),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.sectionHeader(
                title: String(localized: "Recent Agents", bundle: .agentPadResources)
            ))
            for entry in entries {
                menu.addItem(menuItem(for: entry))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "Open \(AppIdentity.appName)",
            action: #selector(openAgentPad)
        ))
        menu.addItem(actionItem(
            title: String(localized: "Settings…", bundle: .agentPadResources),
            action: #selector(showSettingsWindow)
        ))

        let keepAwake = NSMenuItem(
            title: String(localized: "Keep Awake", bundle: .agentPadResources),
            action: nil,
            keyEquivalent: ""
        )
        keepAwake.submenu = keepAwakeMenu()
        keepAwake.isEnabled = true
        menu.addItem(keepAwake)

        menu.addItem(actionItem(
            title: "Quit \(AppIdentity.appName)",
            action: #selector(quitAgentPad)
        ))

        // AppKit injects standard symbols after insertion (notably a gear for
        // Settings…), even when the item was created with `image == nil`.
        // Clear the completed menu so every row stays deliberately text-only.
        for item in menu.items where !item.isSeparatorItem {
            item.image = nil
        }
    }

    private func actionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func keepAwakeMenu() -> NSMenu {
        let submenu = NSMenu(
            title: String(localized: "Keep Awake", bundle: .agentPadResources)
        )
        submenu.autoenablesItems = false
        for mode in AwakeMode.allCases {
            let item = NSMenuItem(
                title: Self.awakeModeTitle(mode),
                action: #selector(setAwakeMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = settings.awakeMode == mode ? .on : .off
            item.isEnabled = true
            submenu.addItem(item)
        }
        return submenu
    }

    private func menuItem(for entry: AgentMonitor.Entry) -> NSMenuItem {
        let item = NSMenuItem(
            title: Self.shortMenuText(entry.tabTitle),
            action: #selector(activateAgent(_:)),
            keyEquivalent: ""
        )
        item.attributedTitle = Self.menuItemAttributedTitle(
            tabTitle: entry.tabTitle,
            path: entry.locationPathLabel
        )
        item.target = self
        item.representedObject = entry.id
        item.toolTip = entry.hoverText(tag: entry.tag)
        item.isEnabled = true
        return item
    }

    @objc private func activateAgent(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        monitor.onActivate(sessionId)
    }

    @objc private func openAgentPad() {
        onOpenAgentPad()
    }

    @objc private func showSettingsWindow() {
        onOpenSettings()
    }

    @objc private func setAwakeMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = AwakeMode(rawValue: rawValue) else { return }
        settings.applyAwakeMode(mode)
    }

    @objc private func quitAgentPad() {
        NSApp.terminate(nil)
    }

    static func awakeModeTitle(
        _ mode: AwakeMode,
        bundle: Bundle = .agentPadResources
    ) -> String {
        let key: String
        switch mode {
        case .off: key = "Off"
        case .auto: key = "Auto"
        case .always: key = "Always"
        }
        return String(
            localized: String.LocalizationValue(key),
            bundle: bundle
        )
    }

    static func countTitle(_ count: Int) -> String {
        count > 0 ? "\(count)" : ""
    }

    /// Native menu labels stay compact even when an OSC title or path is long.
    /// The full value remains available through the menu item's tooltip.
    static func shortMenuText(_ text: String, limit: Int = 30) -> String {
        guard limit > 0 else { return "" }
        let flattened = singleLine(text)
        guard flattened.count > limit else { return flattened }
        guard limit > 1 else { return "…" }
        return String(flattened.prefix(limit - 1)) + "…"
    }

    /// Two-line native menu label matching the task rows in ChatGPT's menu:
    /// the tab title leads, while the project path sits underneath in smaller
    /// secondary text. Long paths retain their deepest components.
    static func menuItemAttributedTitle(tabTitle: String, path: String) -> NSAttributedString {
        let title = shortMenuText(tabTitle, limit: 34)
        let location = tailTruncatedText(path, limit: 44)
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        guard !location.isEmpty else { return result }
        result.append(NSAttributedString(
            string: "\n\(location)",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

    private static func tailTruncatedText(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let flattened = singleLine(text)
        guard flattened.count > limit else { return flattened }
        guard limit > 1 else { return "…" }
        return "…" + String(flattened.suffix(limit - 1))
    }
}
