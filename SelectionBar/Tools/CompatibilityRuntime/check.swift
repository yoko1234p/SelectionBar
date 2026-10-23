import Foundation
import JavaScriptCore

// Run before the Swift test suite when upgrading a dependency. Pure JSC, no app or network.
let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../../Sources/SelectionBarCore/Resources/vendor-api.js").standardizedFileURL
let context = JSContext()!
var failure: String?
context.exceptionHandler = { _, error in
  failure = (error?.toString() ?? "Unknown JavaScript error") + "\n" + (error?.forProperty("stack")?.toString() ?? "")
}
context.evaluateScript(try String(contentsOf: runtime, encoding: .utf8))
if let failure { fputs(failure + "\n", stderr); exit(1) }
let result = context.evaluateScript("JSON.stringify({modules:Object.keys(__bundledModules).length,url:new URL('../x','https://example.test/a/b').href,typescript:typeof __transpile,process:typeof process,fetch:typeof fetch})")?.toString()
if let failure { fputs(failure + "\n", stderr); exit(1) }
print(result ?? "null")
