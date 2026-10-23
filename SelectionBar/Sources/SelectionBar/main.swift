import AppKit
import LocalWorkflowKit
import SelectionBarCore
import SwiftUI

if L10n.catalog.printDiagnosticsIfRequested() { exit(0) }

if CommandLine.arguments.contains("--ui-smoke") {
  let args = CommandLine.arguments
  guard let index = args.firstIndex(of: "--data-directory"), index + 1 < args.count,
    URL(fileURLWithPath: args[index + 1]).resolvingSymlinksInPath().standardizedFileURL
      != PrivateStore.root.resolvingSymlinksInPath().standardizedFileURL
  else {
    fputs(
      "UI diagnostics require a separate --data-directory; the live profile is not a test fixture.\n",
      stderr)
    exit(2)
  }
}

if CommandLine.arguments.contains("--import-original") {
  do {
    let args = CommandLine.arguments
    let root =
      args.firstIndex(of: "--data-directory").flatMap {
        $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil
      } ?? PrivateStore.root
    let home =
      args.firstIndex(of: "--source-home").flatMap {
        $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil
      } ?? FileManager.default.homeDirectoryForCurrentUser
    let existing = try PrivateStore.load(at: root)
    let (library, summary) = try PopClipMigration.migrate(
      home: home, destination: root,
      existing: existing.migrationFingerprint == nil ? nil : existing,
      overwriteCustomization: args.contains("--reset-from-original"))
    // Persist a successfully decoded own-store schema upgrade even when the
    // source fingerprint is unchanged; customizations remain the returned copy.
    try PrivateStore.save(library, at: root)
    let safe: [String: Any] = [
      "schema": library.schema, "layoutItems": summary.layoutItems,
      "extensionPackages": summary.extensionPackages, "optionValues": summary.optionValues,
      "disabledItems": summary.disabledItems, "groups": summary.groups, "changed": summary.changed,
      "mapped": library.layout.map {
        ["id": $0.id, "provider": $0.provider, "enabled": $0.enabled]
      }, "packageIdentities": library.extensions.map { ["id": $0.id, "digest": $0.digest] },
      "preservedUntranslated": summary.unmappedPreferenceKeys,
      "skippedNonfunctional": [
        "license state", "usage counters", "original Keychain credentials", "activity data",
      ], "rejected": summary.notes.filter { $0.hasPrefix("未能匯入") }, "scriptsExecuted": false,
      "originalModified": false,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])
    try FileHandle.standardOutput.write(contentsOf: data)
    exit(0)
  } catch {
    fputs("SelectionBar import failed: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
}

if CommandLine.arguments.contains("--enable-workflows") {
  do {
    let root = argumentURL("--data-directory") ?? PrivateStore.root
    if root.standardizedFileURL == PrivateStore.root.standardizedFileURL,
      NSWorkspace.shared.runningApplications.contains(where: {
        $0.bundleIdentifier == "local.pakwingho.selectionbar"
      })
    {
      throw WorkflowError.invalid(L10n.text("請先結束 SelectionBar，再更新動作清單。"))
    }
    try PrivateStore.appendBuiltIns(["favorites", "vocabulary", "recipes"], at: root)
    print("Workflow actions enabled; existing layout entries preserved.")
    exit(0)
  } catch {
    fputs("Workflow setup failed: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = SelectionModel(root: argumentURL("--data-directory") ?? PrivateStore.root)
  var status: NSStatusItem?
  var window: NSWindow?
  var bar: FloatingBar?
  var monitor: SelectionMonitor?
  var smoke: NativeSmoke?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let item = NSStatusBar.system.statusItem(withLength: 26)
    let glyph = NSImage(
      systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "SelectionBar")?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    glyph?.size = NSSize(width: 16, height: 16)
    glyph?.isTemplate = true
    item.button?.image = glyph
    item.button?.toolTip = L10n.text("SelectionBar · 選字操作")
    item.button?.setAccessibilityIdentifier("selectionbar.status")
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(
      withTitle: L10n.text("開啟 SelectionBar…"), action: #selector(showWindow), keyEquivalent: "")
    menu.addItem(
      withTitle: L10n.text("顯示所選文字操作列"), action: #selector(showSelection), keyEquivalent: "")
    menu.addItem(withTitle: L10n.text("暫停／啟用"), action: #selector(toggleEnabled), keyEquivalent: "")
    let cancel = menu.addItem(
      withTitle: L10n.text("取消執行中動作"), action: #selector(cancelAction), keyEquivalent: "")
    cancel.tag = 1
    menu.addItem(.separator())
    menu.addItem(
      withTitle: L10n.text("結束 SelectionBar"), action: #selector(quit), keyEquivalent: "q")
    for entry in menu.items { entry.target = self }
    item.menu = menu
    status = item
    bar = FloatingBar(model: model)
    if !CommandLine.arguments.contains("--ui-smoke") {
      monitor = SelectionMonitor(
        model: model, onSelection: { [weak self] in self?.model.prepareToolbar($0) })
    }
    model.renderToolbar = { [weak self] snapshot, state in
      self?.bar?.present(snapshot, population: state)
    }
    model.iconsChanged = { [weak self] in self?.bar?.refreshIcons() }
    model.settingsChanged = { [weak self] in
      if CommandLine.arguments.contains("--ui-smoke") {
        self?.model.refreshStatus()
      } else {
        self?.monitor?.refresh()
      }
    }
    model.showSettings = { [weak self] in self?.showWindow() }
    model.dismissBar = { [weak self] in self?.bar?.dismiss() }
    model.showResult = { [weak self] text, preview in self?.bar?.showResult(text, preview: preview)
    }
    model.showFailure = { [weak self] failure, snapshot in
      self?.bar?.showFailure(failure, snapshot: snapshot)
    }
    model.showLargeText = { [weak self] in self?.bar?.showLargeText($0) }
    model.showBusy = { [weak self] in self?.bar?.presentBusy($0) }
    model.hideBusy = { [weak self] in self?.bar?.dismissBusy() }
    model.reappear = { [weak self] in self?.monitor?.capture(force: true) }
    model.showActions = { [weak self] actions, record, snapshot in
      self?.bar?.presentModuleActions(
        actions, record: record, snapshot: snapshot, rememberCurrent: true)
    }
    if CommandLine.arguments.contains("--ui-smoke") || argumentURL("--data-directory") != nil {
      showWindow()
    }
    if CommandLine.arguments.contains("--ui-smoke"), let bar {
      model.refreshStatus()
      smoke = NativeSmoke(model: model, bar: bar)
      let report =
        argumentURL("--smoke-report") ?? model.dataRoot.appendingPathComponent("ui-report.json")
      smoke?.start(report: report)
    } else {
      monitor?.refresh()
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    model.cancelPopulation()
    model.executor.cancel()
    monitor?.stop()
    bar?.dismiss()
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    if CommandLine.arguments.contains("--ui-smoke") {
      model.refreshStatus()
    } else {
      monitor?.refresh()
    }
  }
  func menuWillOpen(_ menu: NSMenu) { menu.item(withTag: 1)?.isEnabled = model.busy }
  @objc func cancelAction() { model.cancelAction() }
  func application(_ sender: NSApplication, open urls: [URL]) {
    for url in urls {
      if url.scheme == "selectionbar" { showWindow() } else { model.importExtension(url) }
    }
  }
  @objc func showWindow() {
    if window == nil {
      let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 610),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      w.title = "SelectionBar"
      if argumentURL("--data-directory") == nil {
        w.setFrameAutosaveName("SelectionBarPreferences")
      }
      w.minSize = NSSize(width: 480, height: 480)
      w.contentView = NSHostingView(rootView: SettingsView(model: model))
      w.center()
      w.isReleasedWhenClosed = false
      window = w
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
  @objc func showSelection() { monitor?.capture(force: true) }
  @objc func toggleEnabled() {
    model.library.settings.enabled.toggle()
    model.save()
    monitor?.refresh()
  }
  @objc func quit() { NSApp.terminate(nil) }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    return true
  }
}

func argumentURL(_ name: String) -> URL? {
  let args = CommandLine.arguments
  guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
  return URL(fileURLWithPath: args[index + 1])
}

MainActor.assumeIsolated {
  let delegate = AppDelegate()
  NSApplication.shared.delegate = delegate
  NSApplication.shared.run()
  withExtendedLifetime(delegate) {}
}
