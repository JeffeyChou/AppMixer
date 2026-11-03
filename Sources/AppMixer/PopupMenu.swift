import AppKit

/// Builds an NSMenu only when it's clicked and pops it up at the mouse. Cheaper than a SwiftUI `Menu`
/// / `Picker` in every row, which would keep an NSPopUpButton alive per app.
enum PopupMenu {
    struct Item {
        var title: String
        var symbol: String?
        var checked = false
        var isHeader = false
        var isSeparator = false
        var action: (() -> Void)?

        static let separator = Item(title: "", isSeparator: true)
        static func header(_ title: String) -> Item { Item(title: title, isHeader: true) }
    }

    private final class Handler: NSObject {
        let actions: [() -> Void]
        init(_ actions: [() -> Void]) { self.actions = actions }
        @objc func fire(_ sender: NSMenuItem) { actions[sender.tag]() }
    }

    private static var current: (NSMenu, Handler)?   // keep alive while the menu is open

    static func show(_ items: [Item]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var actions: [() -> Void] = []
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            if item.isHeader {
                if #available(macOS 14.0, *) {
                    menu.addItem(.sectionHeader(title: item.title))
                } else {
                    let header = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                continue
            }
            let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            if let symbol = item.symbol {
                mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            mi.state = item.checked ? .on : .off
            if let action = item.action {
                mi.tag = actions.count
                actions.append(action)
                mi.action = #selector(Handler.fire(_:))
            } else {
                mi.isEnabled = false
            }
            menu.addItem(mi)
        }
        let handler = Handler(actions)
        for mi in menu.items where mi.action != nil { mi.target = handler }
        current = (menu, handler)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
