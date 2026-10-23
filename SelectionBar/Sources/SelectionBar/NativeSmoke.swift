import AppKit
import SelectionBarCore

/// Explicit command-line diagnostics use only an owned editor and synthetic
/// text. They do not install global hooks, grant TCC, or run imported actions.
@MainActor
final class NativeSmoke: NSObject {
  private let model: SelectionModel
  private let bar: FloatingBar
  private var window: NSWindow?
  private var editor: NSTextView?
  init(model: SelectionModel, bar: FloatingBar) {
    self.model = model
    self.bar = bar
  }
  func start(report: URL) {
    // Even a reused diagnostic directory must never supply action code to the
    // initial toolbar or Copy test. All catalogs below are owned fixtures.
    model.library = .initial
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 330),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "SelectionBar · Synthetic Editor"
    window.isReleasedWhenClosed = false
    let editor = NSTextView(frame: NSRect(x: 18, y: 18, width: 584, height: 290))
    editor.font = .systemFont(ofSize: 18)
    editor.string =
      L10n.text(
        "SelectionBar synthetic editor\n中文 日本語 한국어 English\nSelect text to preview the floating toolbar."
      )
    editor.isRichText = false
    editor.autoresizingMask = [.width, .height]
    editor.setAccessibilityIdentifier("selectionbar.synthetic-editor")
    window.contentView?.addSubview(editor)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
    self.window = window
    self.editor = editor
    if CommandLine.arguments.contains("--spelling-smoke") {
      startSpelling(editor: editor, report: report)
      return
    }
    Task {
      var previous: PasteboardSnapshot?
      var clipboardReceipt: Int?
      defer {
        if let clipboardReceipt, NSPasteboard.general.changeCount == clipboardReceipt {
          try? previous?.restoreChecked()
        }
      }
      var checks: [String: Value] = [:]
      do {
        previous = try PasteboardSnapshot()
        try await Task.sleep(for: .milliseconds(200))
        editor.setSelectedRange(NSRange(location: 0, length: 12))
        let initial = snapshot(editor)
        model.selection = initial
        bar.present(initial)
        checks["panel"] = .object(bar.diagnosticGeometry)
        checks["copyButtonClicked"] = .bool(bar.diagnosticClickCopy())
        try await Task.sleep(for: .milliseconds(100))
        checks["copyConfirmed"] = .bool(
          NSPasteboard.general.string(forType: .string) == "SelectionBar")
        if checks["copyConfirmed"]?.bool == true {
          clipboardReceipt = NSPasteboard.general.changeCount
        }
        try await model.executor.paste("Replaced", snapshot: initial, restore: false)
        if NSPasteboard.general.string(forType: .string) == "Replaced" {
          clipboardReceipt = NSPasteboard.general.changeCount
        }
        checks["nativePasteConfirmed"] = .bool(editor.string.hasPrefix("Replaced synthetic"))
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        let stale = snapshot(editor)
        editor.insertText("User edited", replacementRange: NSRange(location: 0, length: 8))
        let userText = editor.string
        do {
          try await model.executor.paste("Protected result", snapshot: stale, restore: false)
          checks["staleRejected"] = .bool(false)
        } catch {
          checks["staleRejected"] = .bool(editor.string == userText)
          checks["staleResultRetained"] = .bool(
            NSPasteboard.general.string(forType: .string) == "Protected result")
          if checks["staleResultRetained"]?.bool == true {
            clipboardReceipt = NSPasteboard.general.changeCount
          }
        }
        editor.setSelectedRange(NSRange(location: 0, length: 11))
        let final = snapshot(editor)
        model.selection = final
        let original = model.library
        model.library.layout = (0..<120).map { index in
          LayoutEntry(
            id: "overflow-\(index)", provider: "app.popclip.builtin.copy", order: Double(index))
        }
        bar.present(final)
        let overflow = bar.diagnosticGeometry
        checks["overflowScroll"] = .bool(overflow["horizontalScroll"]?.bool == true)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(final.anchor) }) {
          checks["overflowFitsDisplay"] = .bool(
            (Double(overflow["width"]?.string ?? "0") ?? 0) <= screen.visibleFrame.width)
        }
        model.library = original
        bar.showLargeText(L10n.text("SelectionBar — synthetic large type 日本語 한국어 中文"))
        checks["largeTypeVisible"] = bar.diagnosticGeometry["visible"]
        try await Task.sleep(for: .milliseconds(80))
        bar.dismiss()
        let config: [String: Value] = ["javascript": .string("await sleep(4000);")]
        let long = ExtensionAction(id: "0", title: "Synthetic cancellation", config: config)
        let fixture = ExtensionRecord(
          id: "dev.selectionbar.smoke", name: "Synthetic", packagePath: model.dataRoot.path,
          digest: "synthetic", config: config, actions: [long])
        model.execute(long, record: fixture, snapshot: final)
        try await Task.sleep(for: .milliseconds(80))
        model.cancelAction()
        var following = long
        following.config["javascript"] = .string(
          "await popclip.copyText('Synthetic followup', {notify:false});")
        model.execute(following, record: fixture, snapshot: final)
        for _ in 0..<60 {
          if !model.busy { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        checks["cancelFollowupCompleted"] = .bool(
          !model.busy && NSPasteboard.general.string(forType: .string) == "Synthetic followup")
        if checks["cancelFollowupCompleted"]?.bool == true {
          clipboardReceipt = NSPasteboard.general.changeCount
        }

        let package = model.dataRoot.appendingPathComponent("synthetic-inline", isDirectory: true)
        try PrivateStore.prepare(package)
        let source = """
          defineExtension({actions:async input=>{
            await sleep(100);
            return [
              {title:'Inline A '+input.text,icon:'text:A',code:async()=>{await popclip.copyText('Synthetic inline A',{notify:false});}},
              {title:'Inline B '+input.text,icon:'text:B',code:async()=>{await popclip.copyText('Synthetic inline B',{notify:false});}}
            ];
          }});
          """
        try Data(source.utf8).write(to: package.appendingPathComponent("Config.js"))
        let moduleConfig: [String: Value] = [
          "module": .string("Config.js"), "entitlements": .array([.string("dynamic")]),
        ]
        let module = ExtensionRecord(
          id: "dev.selectionbar.inline-smoke", name: "Synthetic Inline", packagePath: package.path,
          digest: "synthetic", config: moduleConfig,
          actions: [ExtensionAction(id: "0", title: "Synthetic Inline", config: moduleConfig)])
        model.library.extensions = [module]
        model.library.layout = [LayoutEntry(id: "inline", provider: module.id, order: 0)]
        model.prepareToolbar(final)
        let secondTitle = "Inline B " + final.context.text
        for _ in 0..<150 {
          if bar.diagnosticActionTitles.contains(secondTitle) { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        checks["inlineActionsVisible"] = .bool(
          bar.diagnosticActionTitles.contains("Inline A " + final.context.text)
            && bar.diagnosticActionTitles.contains(secondTitle))
        checks["inlineSecondClickedOnce"] = .bool(bar.diagnosticClickAction(title: secondTitle))
        for _ in 0..<150 {
          if !model.busy { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        checks["inlineSecondActionCompleted"] = .bool(
          !model.busy && NSPasteboard.general.string(forType: .string) == "Synthetic inline B")
        if checks["inlineSecondActionCompleted"]?.bool == true {
          clipboardReceipt = NSPasteboard.general.changeCount
        }

        var nestedEntry = model.library.layout[0]
        nestedEntry.parent = "synthetic-group"
        model.library.layout = [
          LayoutEntry(
            id: "synthetic-group", provider: "", name: "Synthetic Group", order: 0, kind: 0),
          nestedEntry,
        ]
        model.prepareToolbar(final)
        checks["groupOpened"] = .bool(bar.diagnosticClickAction(title: "Synthetic Group"))
        for _ in 0..<150 {
          if bar.diagnosticActionTitles.contains(secondTitle) { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        checks["groupPopulationStayedOpen"] = .bool(
          bar.diagnosticActionTitles.contains(secondTitle))
        checks["groupBack"] = .bool(
          bar.diagnosticClickAction(title: L10n.text("返回"))
            && bar.diagnosticActionTitles.contains("Synthetic Group"))
        nestedEntry.parent = nil
        model.library.layout = [nestedEntry]
        var oldSelection = final
        oldSelection.context.text = "Old selection"
        oldSelection.capturedAt = Date()
        model.prepareToolbar(oldSelection)
        try await Task.sleep(for: .milliseconds(15))
        var latestSelection = final
        latestSelection.context.text = "Latest selection"
        latestSelection.capturedAt = Date()
        model.prepareToolbar(latestSelection)
        for _ in 0..<150 {
          if bar.diagnosticActionTitles.contains("Inline B Latest selection") { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        checks["inlineLatestSelectionOnly"] = .bool(
          bar.diagnosticActionTitles.contains("Inline B Latest selection")
            && !bar.diagnosticActionTitles.contains("Inline B Old selection"))
        model.prepareToolbar(oldSelection)
        bar.dismiss()
        try await Task.sleep(for: .milliseconds(250))
        checks["dismissedPopulationDidNotReopen"] = .bool(
          bar.diagnosticGeometry["visible"]?.bool != true)
        checks["dismissedSelectionReleased"] = .bool(
          bar.diagnosticGeometry["retainsSelection"]?.bool == false
            && bar.diagnosticGeometry["retainsMenu"]?.bool == false
            && bar.diagnosticGeometry["retainedCatalogCount"] == .number(0))

        let initialSource = """
          defineExtension({actions:[{title:'Root action',code:()=>0},
            {title:'Initial folder',wantsInitialDisplay:true,submenu:[
              {title:'Initial first',code:()=>0},
              {title:'Initial primary',wantsPrimaryDisplay:true,code:()=>0},
              {title:'Initial last',code:()=>0}]}]});
          """
        try Data(initialSource.utf8).write(to: package.appendingPathComponent("Config.js"))
        var pointed = final
        pointed.capturedAt = Date()
        pointed.pointer = CGPoint(x: pointed.anchor.midX, y: pointed.anchor.midY)
        model.prepareToolbar(pointed)
        for _ in 0..<150 {
          if bar.diagnosticActionTitles.contains("Initial primary") { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        checks["initialSubmenuAutomatic"] = .bool(
          bar.diagnosticActionTitles.contains("Initial first")
            && bar.diagnosticActionTitles.contains("Initial primary")
            && !bar.diagnosticActionTitles.contains("Root action"))
        checks["primaryActionUnderPointer"] = .bool(
          Double(bar.diagnosticGeometry["primaryX"]?.string ?? "nan").map {
            abs($0 - Double(pointed.pointer!.x)) < 2
          } ?? false)
        NotificationCenter.default.post(
          name: Notification.Name("SelectionBar.ExtensionIconAssetsDidChange"), object: nil)
        try await Task.sleep(for: .milliseconds(40))
        checks["iconRefreshKeepsInitialSubmenu"] = .bool(
          bar.diagnosticActionTitles.contains("Initial primary"))
        checks["initialBackToRoot"] = .bool(
          bar.diagnosticClickAction(title: L10n.text("返回"))
            && bar.diagnosticActionTitles.contains("Root action"))
        bar.dismiss()
        NotificationCenter.default.post(
          name: Notification.Name("SelectionBar.ExtensionIconAssetsDidChange"), object: nil)
        try await Task.sleep(for: .milliseconds(40))
        checks["iconRefreshDoesNotReopenDismissedPanel"] = .bool(
          bar.diagnosticGeometry["visible"]?.bool != true)

        let staticConfig: [String: Value] = [
          "submenu": .array([
            .object([
              "title": .string("Static nested"),
              "submenu": .array([
                .object([
                  "title": .string("Static leaf"), "javascript": .string("return 1;"),
                  "icon": .string("symbol:star"), "wantsprimarydisplay": .bool(true),
                ])
              ]),
            ]),
            .object(["title": .string("Static sibling"), "javascript": .string("return 0;")]),
          ])
        ]
        let staticAction = ExtensionAction(
          id: "folder", title: "Static folder", config: staticConfig)
        let staticRecord = ExtensionRecord(
          id: "synthetic.static", name: "Static", packagePath: package.path,
          digest: "synthetic", config: staticConfig, actions: [staticAction])
        model.execute(staticAction, record: staticRecord, snapshot: pointed)
        let openedNested = bar.diagnosticClickAction(title: "Static nested")
        checks["staticNestedSubmenu"] = .bool(
          openedNested && bar.diagnosticActionTitles.contains("Static leaf"))
        checks["staticBackKeepsParentMenu"] = .bool(
          bar.diagnosticClickAction(title: L10n.text("返回"))
            && bar.diagnosticActionTitles.contains("Static nested")
            && bar.diagnosticActionTitles.contains("Static sibling"))
        bar.dismiss()

        if let screen = NSScreen.screens.first(where: { !$0.frame.contains(final.anchor.origin) }) {
          let previousLibrary = model.library
          model.library = .initial
          var other = final
          other.anchor = CGRect(
            x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 80, height: 22)
          other.capturedAt = Date()
          bar.present(other)
          bar.showLargeText("Synthetic secondary display")
          checks["secondaryMonitorTarget"] = .object([
            "x": .number(screen.frame.minX), "y": .number(screen.frame.minY),
            "width": .number(screen.frame.width), "height": .number(screen.frame.height),
          ])
          checks["secondaryMonitorObserved"] = .object(bar.diagnosticGeometry)
          checks["secondaryMonitorLargeType"] = .bool(
            Double(bar.diagnosticGeometry["x"]?.string ?? "nan") == Double(screen.frame.minX)
              && Double(bar.diagnosticGeometry["y"]?.string ?? "nan") == Double(screen.frame.minY))
          bar.dismiss()
          model.library = previousLibrary
        } else {
          checks["secondaryMonitorLargeType"] = .string("Only one display attached")
        }
        // Leave a synthetic, persisted settings fixture for guarded AX tests.
        // All files and options belong to this isolated diagnostic profile.
        var configured = module
        configured.config["options"] = .array([
          .object([
            "identifier": .string("language"), "type": .string("string"),
            "label": .string("Language"),
          ])
        ])
        model.library = original
        model.library.extensions = [configured]
        model.library.layout = []
        _ = try model.library.createGroup(
          name: "Synthetic Work", icon: .string("symbol:tray"), color: "purple",
          id: "fixture-folder")
        _ = try model.library.createGroup(
          name: "Synthetic Nested", parent: "fixture-folder", id: "fixture-nested")
        model.library.layout.append(
          LayoutEntry(
            id: "fixture-a", provider: configured.id, name: "Synthetic A", order: 0,
            parent: "fixture-nested", options: ["language": .string("en")]))
        model.library.layout.append(
          LayoutEntry(
            id: "fixture-b", provider: configured.id, name: "Synthetic B", order: 1000,
            options: ["language": .string("ja")]))
        model.library.materializeInstanceOptions()
        model.save()
        if let settings = NSApp.windows.first(where: { $0.title == "SelectionBar" }) {
          @MainActor func recorders(_ view: NSView) -> [RecorderButton] {
            if let recorder = view as? RecorderButton { return [recorder] }
            return view.subviews.flatMap(recorders)
          }
          settings.makeKeyAndOrderFront(nil)
          NSRunningApplication.current.activate(options: [])
          try await Task.sleep(for: .milliseconds(80))
          if let recorder = settings.contentView.flatMap({ recorders($0).first }) {
            recorder.performClick(nil)
            if let key = NSEvent.keyEvent(
              with: .keyDown, location: .zero, modifierFlags: [.control, .option],
              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
              characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17)
            {
              NSApp.sendEvent(key)
            }
            checks["settingsRecorderWindowlessEvent"] = .bool(
              model.library.settings.hotkey == "control option 0x11")
          } else {
            checks["settingsRecorderWindowlessEvent"] = .bool(false)
          }
        }
        let originalRunning = NSWorkspace.shared.runningApplications.contains {
          ["com.pilotmoon.popclip", "com.pilotmoon.popclip-setapp"].contains(
            $0.bundleIdentifier ?? "")
        }
        checks["conflictStateMatchesRunningApps"] = .bool(model.conflict == originalRunning)
        checks["originalRunningPausesHooks"] =
          originalRunning
          ? .bool(model.conflict) : .string("Not exercised: original PopClip is not running.")
        checks["privateExtensionsExecuted"] = .bool(false)
        checks["allChecksPassed"] = .bool(
          checks.allSatisfy { key, value in
            if key == "privateExtensionsExecuted" { return value == .bool(false) }
            if case .bool(let passed) = value { return passed }
            return true
          })
        checks["complete"] = .bool(true)
        installInteractiveControls()
      } catch {
        checks["error"] = .string(error.localizedDescription)
        checks["complete"] = .bool(false)
      }
      do {
        try PrivateStore.prepare(report.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checks).write(to: report, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
      } catch { model.notice = error.localizedDescription }
    }
  }
  private func installInteractiveControls() {
    guard let window, let editor else { return }
    editor.frame = NSRect(x: 18, y: 60, width: 584, height: 245)
    let controls = NSStackView()
    controls.spacing = 8
    controls.frame = NSRect(x: 18, y: 12, width: 584, height: 34)
    for (title, selector, identifier) in [
      ("Hover folder", #selector(showHoverFixture), "selectionbar.smoke.hover"),
      ("Supplemental menu", #selector(showSupplementFixture), "selectionbar.smoke.supplement"),
      ("Failure details", #selector(showFailureFixture), "selectionbar.smoke.failure"),
      ("Spelling", #selector(showSpellingFixture), "selectionbar.smoke.spelling"),
    ] {
      let button = NSButton(title: title, target: self, action: selector)
      button.setAccessibilityIdentifier(identifier)
      controls.addArrangedSubview(button)
    }
    window.contentView?.addSubview(controls)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(editor)
  }
  private func startSpelling(editor: NSTextView, report: URL) {
    Task {
      var checks: [String: Value] = [:]
      var previous: PasteboardSnapshot?
      var clipboardReceipt: Int?
      defer {
        if let clipboardReceipt, NSPasteboard.general.changeCount == clipboardReceipt {
          try? previous?.restoreChecked()
        }
      }
      @MainActor func waitForAction(_ title: String) async throws -> Bool {
        for _ in 0..<200 {
          if bar.diagnosticActionTitles.contains(title) { return true }
          try await Task.sleep(for: .milliseconds(15))
        }
        return false
      }
      @MainActor func waitForOperation() async throws {
        for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        if model.busy { throw LibraryError.invalid("Owned spelling operation timed out") }
      }
      @MainActor func selectMisspelling() -> SelectionSnapshot {
        editor.string = "A beuatified word."
        editor.setSelectedRange(NSRange(location: 2, length: 10))
        window?.makeFirstResponder(editor)
        return snapshot(editor)
      }
      do {
        previous = try PasteboardSnapshot()
        guard NSSpellChecker.shared.availableLanguages.contains("en") else {
          throw LibraryError.invalid(
            "Native fixture requires the installed English spelling dictionary")
        }
        model.library = .initial
        model.library.settings.spellingLanguages = ["en"]
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        let selected = selectMisspelling()
        let baseline = Double(bar.diagnosticGeometry["spellingRequests"]?.string ?? "0") ?? 0
        let started = Date()
        bar.present(selected, population: PopulationState())
        checks["nativeCandidatesShown"] = .bool(try await waitForAction("beautified"))
        checks["nativeCandidateSeconds"] = .number(Date().timeIntervalSince(started))
        checks["secondCandidateShown"] = .bool(bar.diagnosticActionTitles.contains("beatified"))
        checks["nonactivating"] = .bool(bar.diagnosticGeometry["canBecomeKey"] == .bool(false))
        let redrawStarted = Date()
        for _ in 0..<100 { bar.present(selected) }
        checks["hundredRedrawSeconds"] = .number(Date().timeIntervalSince(redrawStarted))
        checks["hundredRendersOneRequest"] = .bool(
          (Double(bar.diagnosticGeometry["spellingRequests"]?.string ?? "0") ?? 0) - baseline == 1)
        checks["backReturnsActions"] = .bool(
          bar.diagnosticClickAction(title: L10n.text("返回"))
            && bar.diagnosticActionTitles.contains("複製"))
        checks["manualSpellingReopens"] = .bool(
          bar.diagnosticClickAction(title: L10n.text("拼字"))
            && bar.diagnosticActionTitles.contains("beautified"))

        model.replaceSpelling("beautified", snapshot: selected, copyOnly: true)
        try await waitForOperation()
        checks["copyDoesNotEdit"] = .bool(editor.string == "A beuatified word.")
        checks["copyCandidateConfirmed"] = .bool(
          NSPasteboard.general.string(forType: .string) == "beautified")
        clipboardReceipt = NSPasteboard.general.changeCount
        try model.executor.copy("Owned clipboard marker")
        clipboardReceipt = NSPasteboard.general.changeCount
        editor.undoManager?.removeAllActions()
        bar.present(selected)
        _ = try await waitForAction("beautified")
        checks["candidateButtonClicked"] = .bool(bar.diagnosticClickAction(title: "beautified"))
        try await waitForOperation()
        checks["candidateActuallyReplaces"] = .bool(editor.string == "A beautified word.")
        checks["clipboardRestored"] = .bool(
          NSPasteboard.general.string(forType: .string) == "Owned clipboard marker")
        clipboardReceipt = NSPasteboard.general.changeCount
        editor.undoManager?.undo()
        checks["undoRestoresMisspelling"] = .bool(editor.string == "A beuatified word.")

        let stale = selectMisspelling()
        editor.insertText("User edit", replacementRange: NSRange(location: 2, length: 10))
        let edited = editor.string
        model.replaceSpelling("beautified", snapshot: stale, copyOnly: false)
        try await waitForOperation()
        checks["staleSelectionNotOverwritten"] = .bool(editor.string == edited)
        checks["staleCandidateRetainedForManualPaste"] = .bool(
          NSPasteboard.general.string(forType: .string) == "beautified")
        clipboardReceipt = NSPasteboard.general.changeCount
        bar.dismiss()
        checks["dismissReleasesSpellingAndSelection"] = .bool(
          bar.diagnosticGeometry["retainedSpellingWords"] == .number(0)
            && bar.diagnosticGeometry["retainsSelection"] == .bool(false))

        model.library.settings.spellingShowFirst = false
        let manual = selectMisspelling()
        bar.present(manual)
        _ = try await waitForAction(L10n.text("拼字"))
        checks["automaticDisplayCanBeDisabled"] = .bool(
          bar.diagnosticActionTitles.contains("複製")
            && !bar.diagnosticActionTitles.contains("beautified"))
        bar.dismiss()
        var readonly = selectMisspelling()
        readonly.context.editable = false
        let beforeReadonly = bar.diagnosticGeometry["spellingRequests"]
        bar.present(readonly)
        checks["readonlySkipsSpelling"] = .bool(
          !bar.diagnosticActionTitles.contains("拼字")
            && bar.diagnosticGeometry["spellingRequests"] == beforeReadonly)
        bar.dismiss()

        checks["privateExtensionsExecuted"] = .bool(false)
        checks["allChecksPassed"] = .bool(
          checks.allSatisfy { key, value in
            if key == "privateExtensionsExecuted" { return value == .bool(false) }
            if case .bool(let passed) = value { return passed }
            return true
          })
        checks["complete"] = .bool(true)
        model.library.settings.spellingShowFirst = true
        installInteractiveControls()
        showSpellingFixture()
      } catch {
        checks["error"] = .string(error.localizedDescription)
        checks["complete"] = .bool(false)
      }
      do {
        try PrivateStore.prepare(report.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checks).write(to: report, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
      } catch { model.notice = error.localizedDescription }
    }
  }
  @objc private func showSpellingFixture() {
    guard let editor else { return }
    model.library = .initial
    model.library.settings.spellingLanguages = ["en"]
    editor.string = "A beuatified word."
    editor.setSelectedRange(NSRange(location: 2, length: 10))
    window?.makeFirstResponder(editor)
    bar.present(snapshot(editor), population: PopulationState())
  }
  private func installLiveAction(_ action: ExtensionAction, name: String) -> (
    ExtensionRecord, SelectionSnapshot
  )? {
    guard let editor else { return nil }
    window?.makeFirstResponder(editor)
    let record = ExtensionRecord(
      id: "synthetic.live", name: name, packagePath: model.dataRoot.path, digest: "synthetic",
      config: [:], actions: [action])
    model.library.extensions = [record]
    model.library.layout = [
      LayoutEntry(id: "synthetic-live-instance", provider: record.id, order: 0)
    ]
    return (model.library.record(for: model.library.layout[0])!, snapshot(editor))
  }
  @objc private func showHoverFixture() {
    let action = ExtensionAction(
      id: "folder", title: "Synthetic Hover Folder",
      config: [
        "submenu": .array([
          .object(["title": .string("Hover Child"), "javascript": .string("return 1;")])
        ])
      ])
    guard let (_, snapshot) = installLiveAction(action, name: action.title) else { return }
    bar.present(snapshot)
  }
  @objc private func showSupplementFixture() {
    let action = ExtensionAction(
      id: "supplement", title: "Synthetic Main Action",
      config: [
        "javascript": .string("await popclip.showText('Owned main action');"),
        "submenu": .array([
          .object(["title": .string("Supplement Child"), "javascript": .string("return 1;")])
        ]),
      ])
    guard let (_, snapshot) = installLiveAction(action, name: action.title) else { return }
    bar.present(snapshot)
  }
  @objc private func showFailureFixture() {
    let action = ExtensionAction(
      id: "failure", title: "Synthetic failure",
      config: ["javascript": .string("throw Error('owned synthetic failure');")])
    guard let (record, snapshot) = installLiveAction(action, name: action.title) else { return }
    bar.showFailure(
      ActionFailure(
        title: action.title,
        message: (0..<40).map {
          "Owned synthetic failure line \($0) — select or scroll these details."
        }.joined(separator: "\n"), instanceID: record.instanceID), snapshot: snapshot)
  }
  private func snapshot(_ editor: NSTextView) -> SelectionSnapshot {
    let range = editor.selectedRange()
    let selected = (editor.string as NSString).substring(with: range)
    let rect = editor.convert(NSRect(x: 20, y: 30, width: 180, height: 22), to: nil)
    let anchor = editor.window?.convertToScreen(rect) ?? rect
    return SelectionSnapshot(
      context: ActionContext(
        text: selected, bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
        appName: "Synthetic Editor", editable: true),
      application: NSRunningApplication.current, element: AXUIElementCreateApplication(getpid()),
      range: CFRange(location: range.location, length: range.length), anchor: anchor,
      capturedAt: Date(), lease: SelectionLease(editor: editor), localEditor: editor)
  }
}
