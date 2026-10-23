# Extension runtime libraries

This build vendors the 19 public libraries listed in the [official PopClip JavaScript environment](https://www.popclip.app/dev/js-environment#bundled-libraries). Extensions run offline in JavaScriptCore; Node.js and npm are build tools only. The app does not load code from a CDN.

Run `npm ci --ignore-scripts && npm run build` here after changing dependencies. Commit `package-lock.json`, the generated `vendor-api.js`, its linked legal comments, and `vendor-licenses.txt`. Package versions are exact. Several use newer compatible releases than the reference app's published versions, including patched Axios, js-yaml, sanitize-html and Valibot. Consequently this is API compatibility work, not a claim that the runtimes are byte-identical.

`entry.cjs` establishes the limited globals and real library modules. Sucrase transforms TypeScript and ES module imports. The independent `web-primitives.cjs` implements the documented Blob/XHR surface; network calls still pass through the native action/auth-phase entitlement check. There is no Node filesystem, `process`, browser `document`, or `fetch` exposed to extension code. HTTP response limits and user cancellation are enforced in the owned native worker.

Native passive utilities use macOS Dictionary Services, spell checking, locale/time-zone data, CommonCrypto and Security's secure random source. Regression tests exercise real parser behavior, known hash vectors, Unicode/binary handling, TypeScript imports, timers, and failed entitlement checks using synthetic extensions. User-installed extension scripts are not executed by migration.
