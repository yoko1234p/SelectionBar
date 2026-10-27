# SelectionBar 0.5.5 validation — 2026-10-27

## Root cause

A hidden accessory-app launch (including `open -g -j`) can leave `NSApp.isHidden` true. Selection capture and toolbar construction still succeed, and the toolbar appears in the accessibility tree, but `orderFrontRegardless()` does not unhide the application. The observed toolbar was on the active Space but had `isVisible == false` and was absent from WindowServer's on-screen window list. This reproduced with the user's Dia selection. Accessibility permission and the enabled setting were already correct.

The overlay presenter now unhides SelectionBar without activation before ordering the panel. Titled settings/document windows are ordered out first, so revealing the toolbar does not reopen preferences. Normal source-app keyboard focus is preserved. The user confirmed that the toolbar appeared after the 0.5.5 fix.

## Related selection-path fixes

- Ignore unrelated background application launches/exits; retain PopClip conflict handling.
- Refresh monitoring on wake/session activation, and dismiss stale selection on sleep/session deactivation.
- Handle AppKit's main-thread global input callbacks in order.
- Restart monitoring when the user explicitly refreshes/grants Accessibility permission.
- Let overlays join the source application's Stage Manager group.

Secure Input was observed during diagnosis but was not established as the cause of this incident. An experimental split-monitor/retry implementation was removed from the final change.

## Verification

- 168 SelectionBar unit tests passed: 36 UI-support tests and 132 core tests.
- Native actions fixture passed, including actual WindowServer visibility after hiding the application, preserved source focus, settings remaining closed, and secondary-display large-text placement.
- Native spelling fixture passed in an isolated rerun: replacement and clipboard restoration both succeeded. An earlier run overlapped clipboard-touching unit tests and is not counted as a pass.
- 387 localization entries validated in English, Traditional Chinese and Simplified Chinese, including packaged resources.
- Installed bundle signature verified. Existing signing identity, bundle ID and Work Applications symlink preserved.
- Live library configuration remained byte-for-byte identical.

A brief idle sample showed 0.0% CPU; no controlled memory/performance improvement is claimed. A real overnight sleep/wake cycle was not exercised; lifecycle notification behavior has regression coverage.

## Reproduction and diagnostics

Build/install using the project README, launch with `open -g -j /Applications/SelectionBar.app`, then select text in another application. The toolbar must be present in the on-screen window list, with the source app still frontmost and preferences closed.

Run `swift test -j 4` and `python3 Scripts/test-native.py --output /absolute/private/report-directory` sequentially because both exercise the clipboard.

An explicit `--diagnose-selection` launch logs event receipt, selection lengths and window geometry through the `local.pakwingho.selectionbar` / `selection` unified-log category. It does not log selected text, URLs or key codes. Diagnostics are off during normal launches. All troubleshooting fixture apps were stopped and normal SelectionBar operation restored.
