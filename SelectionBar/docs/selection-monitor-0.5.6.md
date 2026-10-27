# SelectionBar 0.5.6 validation — 2026-10-27

## Reproduction

On macOS 27, SelectionBar 0.5.5 was running and enabled but stopped displaying the toolbar. With the same synthetic editor continuously frontmost, sending guarded mouse clicks to BarPilot's control to expand and then collapse the menu bar caused the existing AppKit global monitor to stop delivering mouse events. The selected text remained available and invoking the toolbar manually produced an on-screen window. Restarting SelectionBar or activating another app reinstated the monitor, masking this failure.

A separate controlled experiment showed Core Graphics session event taps continuing to receive mouse events through the same BarPilot open/close sequence. This establishes the observed failure and the tested recovery path; it does not establish the undocumented system implementation that disabled the AppKit monitor.

## Change

The selection monitor now uses a session event tap, returns every event unchanged, handles system-disabled taps when Accessibility access remains valid, and falls back to the earlier AppKit monitor if macOS declines to create the tap. Pointer coordinates are captured with each event. Own-toolbar and active settings-window events are ignored, including a drag starting inside the toolbar and ending outside. Idle scroll events do not dispatch unnecessary dismissals. No Input Monitoring prompt was needed in the tested installation. The secure-field check and existing permission policy remain in effect.

## Validation

- 169 SelectionBar tests passed (37 app-support and 132 core).
- End-to-end on the installed signed app, with the same owned editor frontmost throughout: BarPilot opened and closed; the next drag selected synthetic text and produced an on-screen toolbar. Escape dismissed it, Control-Option-Space reopened it, and a simulated system mouse click on Copy worked; all original clipboard formats were restored.
- BarPilot management remained enabled; SelectionBar's status icon remained in its existing always-hidden category. SelectionBar's live settings remained byte-for-byte unchanged.
- App bundle signature and 387 packaged localization entries verified. Native monitoring started without an additional permission prompt.
- A brief idle process sample reported 0.0% CPU and approximately 61 MiB RSS. This is a single sample, not a controlled before/after performance benchmark.
- Real extended sleep/wake and additional multi-display configurations were not exercised in this change. macOS input tap fallback remains subject to the behavior of AppKit when the system declines a Core Graphics tap.

Diagnostics, enabled only with `--diagnose-selection`, record event delivery, counts and geometry, not selected text, URLs or key codes. The diagnostic launch and temporary fixture were closed; normal SelectionBar remains running.
