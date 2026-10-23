# Extension compatibility

SelectionBar independently implements a subset of the public PopClip extension format and APIs. It does not contain recovered PopClip source, and compatibility is not a claim that every extension or service has been validated.

## Packages and migration

- Read plist, JSON and YAML packages, `.popclipext` folders, `.popclipextz` archives and supported source snippets.
- Validate paths, symlinks, sizes and schema before import. Imported scripts require explicit trust before execution.
- Optionally import an existing local layout, ordering, groups, disabled state and supported nonsecret options. Migration reads the original configuration without modifying it; repeat imports preserve local changes.
- Credentials stay in the user's own Keychain. External services may need separate sign-in and client registration.
- Original-author signatures and automatic update feeds are not implemented. This repository does not distribute a personal extension collection.

## Runtime and interface

The compatibility layer supports selected text/context/options, bounded regular-expression matching, clipboard edits, keyboard commands, menus, CommonJS modules, supported TypeScript transforms, HTTP requests and explicitly trusted scripts. See the source and synthetic tests for exact supported fields and limits.

The native toolbar supports inline module actions, nested menus, selection-based positioning, keyboard triggers and dismissal. Browser selection adapters require the relevant macOS Automation/browser approvals. Accessibility support varies between source apps.

Actions reject stale selections and disabled instances. Errors offer selectable details and links to the affected action's settings. Missing required applications produce a clear failure rather than being reported as successful.

## Resource and validation limits

Module population uses at most two concurrent workers. HTTP responses, output, clipboard snapshots, package files and cached icons have explicit size limits. Active SVG content and external SVG references are rejected; supported public icon lookups send icon identifiers only.

Automated tests use synthetic packages, selections, scripts and network fixtures. They do not establish compatibility with every published extension, authenticate external services or execute the user's imported scripts. Include the extension format/version and a minimal nonsecret fixture when reporting incompatibility.
