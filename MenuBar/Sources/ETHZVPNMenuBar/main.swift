import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Install a minimal main menu so Cmd+C/X/V/A/Z work in text fields
// when the setup/profiles window is open. Without this, the menu bar
// app has no Edit menu and AppKit cannot route standard editing actions.
let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo",  action: #selector(UndoManager.undo),                  keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo",  action: Selector(("redo:")),                           keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),                     keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),                    keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)),                   keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),          keyEquivalent: "a")
editMenuItem.submenu = editMenu

app.mainMenu = mainMenu

app.run()
