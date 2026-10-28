# SelectionBar 0.5.8: dismiss the toolbar while typing

Typing dismisses a visible toolbar and cancels a pending or in-flight click capture, so it does not appear over text after typing begins. The input observer returns events unchanged; Shift-arrow selection and the configured manual shortcut retain their existing key-up behavior. The monitor ignores its own app’s key events and does not log typed keys.

On the installed signed app, a synthetic cross-process mouse and keyboard fixture confirmed that clicking an editable field displays Paste, typing dismisses it while the text reaches the field, and typing within the click delay prevents the toolbar from reappearing. Clicking again reopened Paste. The fixture restored the clipboard using a change-count guard. The automated regression checks include delayed-capture cancellation and Shift-arrow scheduling. This is simulated interaction in a native field, not a human-operated test or coverage of every input method, browser, or display.
