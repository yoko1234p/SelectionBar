import AppKit
import Foundation
import XCTest

@testable import SelectionBarCore

final class APIExtrasTests: XCTestCase {
  private func run(_ source: String) throws -> ScriptResponse {
    let config: [String: Value] = ["javascript": .string(source)]
    let record = ExtensionRecord(
      id: "dev.synthetic.api-extras", name: "Synthetic API",
      packagePath: FileManager.default.temporaryDirectory.path, digest: "synthetic", config: config,
      actions: [])
    let response = try JavaScriptEngine().run(
      ScriptRequest(
        record: record, action: ExtensionAction(id: "action", title: "Synthetic", config: config),
        context: ActionContext(text: "hello", editable: true)))
    XCTAssertNil(response.error, response.error ?? "")
    return response
  }

  func testBundledModulesUseRealParserAndTransformImplementations() throws {
    let response = try run(
      """
      const yaml = require('js-yaml'), entities = require('entities');
      const parsed = yaml.load('anchor: &a {value: 42}\\ncopy: *a');
      const camel = require('case-anything').camelCase('hello world');
      const tree = require('htmlparser2').parseDocument('<p>A &amp; B</p>');
      const html = require('dom-serializer').default(tree);
      const schema = require('valibot');
      return [parsed.copy.value, camel, entities.decodeHTML('&copy; &#x65e5;'), html,
        schema.parse(schema.string(), 'validated'), require('fast-json-stable-stringify')({b:2,a:1})];
      """)
    XCTAssertEqual(
      response.result,
      .array([
        .number(42), .string("helloWorld"), .string("© 日"), .string("<p>A &amp; B</p>"),
        .string("validated"), .string("{\"a\":1,\"b\":2}"),
      ]))
  }

  func testDocumentedNineteenModuleNamesLoadOffline() throws {
    let response = try run(
      """
      const names = ['axios','buffer','case-anything','content-type','dom-serializer','emoji-regex','entities',
        'fast-json-stable-stringify','fast-plist','htmlparser2','js-yaml','linkedom','linkifyjs','oauth-1.0a',
        'rot13-cipher','sanitize-html','sucrase','turndown','valibot'];
      return names.every(name => require(name) != null) && typeof require('axios').interceptors.request.use === 'function';
      """)
    XCTAssertEqual(response.result, .bool(true))
  }

  func testBase64HandlesBytesOffsetsUrlAlphabetAndInvalidUTF8() throws {
    let response = try run(
      """
      const bytes = new Uint8Array([0,255,254,7]).subarray(1,3);
      let rejected = false; try { util.base64Decode('//4='); } catch { rejected = true; }
      return [util.base64Encode(bytes,{urlSafe:true,trimmed:true}), [...util.base64Decode('__4',{bytes:true})],
        util.base64Decode(util.base64Encode('日😀')), rejected];
      """)
    XCTAssertEqual(
      response.result,
      .array([.string("__4"), .array([.number(255), .number(254)]), .string("日😀"), .bool(true)]))
  }

  func testCommonCryptoKnownHashAndHMACVectors() throws {
    let response = try run(
      """
      const hex = bytes => Buffer.from(bytes).toString('hex');
      return [hex(util.hash(Buffer.from('abc'),'sha256')), hex(util.hash(Buffer.from('abc'),'sha224')),
        hex(util.hash(Buffer.from('abc'),'md5')),
        hex(util.hmac(Buffer.from('what do ya want for nothing?'),Buffer.from('Jefe'),'sha256'))];
      """)
    XCTAssertEqual(
      response.result,
      .array([
        .string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        .string("23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7"),
        .string("900150983cd24fb0d6963f7d28e17f72"),
        .string("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
      ]))
  }

  func testSanitizationAndMarkdownUseHTMLParsers() throws {
    let response = try run(
      """
      return [util.htmlToMarkdown('<h2>Title</h2><p>Hello <strong>world</strong>.</p>'),
        util.cleanHtml('<p onclick="bad()">Safe<script>bad()</script><a href="javascript:bad()">link</a></p>')];
      """)
    XCTAssertEqual(
      response.result,
      .array([.string("## Title\n\nHello **world**."), .string("<p>Safe<a>link</a></p>")]))
  }

  func testWHATWGURLsAndFormQueryUnicodeRoundTrip() throws {
    let response = try run(
      """
      const url = new URL('../日?q=a+b','https://EXAMPLE.com/a/b');
      const query = util.buildQuery({'a b':'日 + %'});
      return [url.hostname,url.pathname,url.searchParams.get('q'),util.parseQuery(query)['a b']];
      """)
    XCTAssertEqual(
      response.result,
      .array([.string("example.com"), .string("/%E6%97%A5"), .string("a b"), .string("日 + %")]))
  }

  func testDirectTurndownModuleWorksWithoutExposingDocument() throws {
    let response = try run(
      "return [new (require('turndown'))().turndown('<p><strong>Direct</strong></p>'),typeof document];"
    )
    XCTAssertEqual(response.result, .array([.string("**Direct**"), .string("undefined")]))
  }

  func testSecureRandomValidatesTypedArraysAndReturnsUnsignedBounds() throws {
    let response = try run(
      """
      const storage = new Uint8Array(10); storage.fill(9); util.getRandomValues(storage.subarray(2,8));
      let invalid = false; try { util.getRandomValues(new Float32Array(2)); } catch { invalid = true; }
      const numbers = Array.from({length:40},()=>util.randomUniform(3));
      return [storage[0],storage[9],invalid,numbers.every(x => Number.isInteger(x)&&x>=0&&x<=3),util.randomUniform(0)];
      """)
    XCTAssertEqual(
      response.result, .array([.number(9), .number(9), .bool(true), .bool(true), .number(0)]))
  }

  func testNativeLocaleAndInvalidSpellingLanguageAreReported() throws {
    let response = try run(
      """
      let invalid = false; try { util.checkSpelling('word',{language:'synthetic-unavailable'}); } catch { invalid = true; }
      return [typeof util.localeInfo.decimalSeparator,typeof util.timeZoneInfo.secondsOffset,
        util.getSpellingLanguages().every(x=>typeof x.code==='string'&&typeof x.name==='string'),invalid];
      """)
    XCTAssertEqual(
      response.result, .array([.string("string"), .string("number"), .bool(true), .bool(true)]))
  }

  func testTypeScriptModuleSupportsImportsTypesAndESMDefault() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try """
    import {camelCase} from 'case-anything';
    interface Input { text:string }
    export default {action: (input:Input):string => camelCase(input.text)};
    """.write(to: directory.appendingPathComponent("main.ts"), atomically: true, encoding: .utf8)
    let config: [String: Value] = ["module": .string("main.ts")]
    let record = ExtensionRecord(
      id: "dev.synthetic.typescript", name: "Synthetic TS", packagePath: directory.path,
      digest: "synthetic", config: config, actions: [])
    let response = try JavaScriptEngine().run(
      ScriptRequest(
        record: record, action: ExtensionAction(id: "action", title: "Synthetic", config: config),
        context: ActionContext(text: "hello world", editable: true)))
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .string("helloWorld"))
  }

  func testNativeTimersSupportIntervalCancellation() throws {
    let response = try run(
      """
      let count=0; const interval=setInterval(()=>count++,2);
      await sleep(20); clearInterval(interval); const before=count; await sleep(10);
      return before>0 && count===before;
      """)
    XCTAssertEqual(response.result, .bool(true))
  }

  func testRichStringPreservesNativeRTFAndUnicodeHTMLRoundTrip() throws {
    let response = try run(
      """
      const first = new RichString('<p><strong>Bold</strong> 日文</p>',{format:'html'});
      const second = new RichString(first.rtf);
      return [first.rtf.startsWith('{\\\\rtf'),second.html.includes('Bold'),
        second.html.includes('日文'),JSON.parse(JSON.stringify(first)).__richString,typeof document];
      """)
    XCTAssertEqual(
      response.result,
      .array([.bool(true), .bool(true), .bool(true), .bool(true), .string("undefined")]))
  }

  func testRichStringMarkdownAndReadOnlyProperties() throws {
    let response = try run(
      """
      const rich = new RichString('# Heading\\n\\n**Strong** and *emphasis*.',{format:'markdown'});
      const original = rich.rtf;
      let invalid=false;try { new RichString('bad',{format:'synthetic-invalid'}); } catch { invalid=true; }
      try { rich.rtf='must not replace'; } catch {}
      return [rich.html.includes('Heading'),rich.html.includes('Strong'),rich.rtf===original,invalid];
      """)
    XCTAssertEqual(response.result, .array([.bool(true), .bool(true), .bool(true), .bool(true)]))
  }

  func testNativeRichTextBridgeRejectsDTDAndNeverLoadsHTMLResources() throws {
    let attributed = try SafeRichTextHTML.parse(
      "<p>Safe<img src=\"https://example.invalid/image.png\" /></p><style>@import 'https://example.invalid/style.css';</style>"
    )
    XCTAssertTrue(attributed.string.contains("Safe"))
    XCTAssertFalse(attributed.string.contains("@import"))
    attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length))
    { value, _, _ in XCTAssertNil(value) }
    XCTAssertThrowsError(
      try SafeRichTextHTML.parse(
        "<!DOCTYPE p SYSTEM 'https://example.invalid/evil.dtd'><p>Text</p>"))
    XCTAssertThrowsError(try SafeRichTextHTML.parse("<!ENTITY repeated 'x'><p>Text</p>"))
  }

  func testNativeRichTextKeepsEmphasisAndUnderlineAfterRTFRoundTrip() throws {
    let value = try SafeRichTextHTML.parse(
      "<p><strong>Bold</strong> <em>Italic</em> <u>Underline</u></p>")
    let data = try value.data(
      from: NSRange(location: 0, length: value.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let restored = try NSAttributedString(
      data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
      documentAttributes: nil)
    let string = restored.string as NSString
    let bold = try XCTUnwrap(
      restored.attribute(.font, at: string.range(of: "Bold").location, effectiveRange: nil)
        as? NSFont)
    let italic = try XCTUnwrap(
      restored.attribute(.font, at: string.range(of: "Italic").location, effectiveRange: nil)
        as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
    XCTAssertEqual(
      (restored.attribute(
        .underlineStyle, at: string.range(of: "Underline").location, effectiveRange: nil)
        as? NSNumber)?.intValue, NSUnderlineStyle.single.rawValue)
  }

  func testBlobCloseCoercionAndInfiniteSliceBounds() throws {
    let response = try run(
      """
      const blob=new Blob([123,'abc']);const original=blob.size;
      const slice=await blob.slice(-Infinity,Infinity).text();blob.close();
      let invalid=false;try{atob('%%%');}catch{invalid=true;}
      return [original,slice,blob.size,blob.isClosed,blob.buffer.length,invalid,atob('YQ')];
      """)
    XCTAssertEqual(
      response.result,
      .array([
        .number(6), .string("123abc"), .number(0), .bool(true), .number(0), .bool(true),
        .string("a"),
      ]))
  }

  func testNumericIntervalsCanBeCancelledByClearTimeout() throws {
    let response = try run(
      """
      let count=0;const id=setInterval(()=>count++,2);await sleep(20);
      clearTimeout(id);const before=count;await sleep(10);clearInterval(id);
      return [typeof id,before>0,count===before];
      """)
    XCTAssertEqual(response.result, .array([.string("number"), .bool(true), .bool(true)]))
  }

  func testXHRReuseAndAbortDuringStateChangeSuppressOldCompletion() throws {
    let response = try run(
      """
      const oldStart=globalThis.__httpStart,oldCancel=globalThis.__httpCancel;
      const callbacks=[];globalThis.__httpStart=(raw,callback)=>{callbacks.push(callback);return callbacks.length;};
      globalThis.__httpCancel=()=>{};
      try {
        const xhr=new XMLHttpRequest();xhr.open('GET','https://example.invalid/a');xhr.send();
        xhr.open('GET','https://example.invalid/b');xhr.send();
        callbacks[0](JSON.stringify({status:200,body:'old'}));
        const protectedNewRequest=xhr.readyState===1;
        const events=[];xhr.onload=()=>events.push('load');xhr.onabort=()=>events.push('abort');
        xhr.onreadystatechange=()=>{if(xhr.readyState===2)xhr.abort();};
        callbacks[1](JSON.stringify({status:200,body:'new'}));
        return [protectedNewRequest,events.join(','),xhr.readyState];
      } finally {globalThis.__httpStart=oldStart;globalThis.__httpCancel=oldCancel;}
      """)
    XCTAssertEqual(response.result, .array([.bool(true), .string("abort"), .number(0)]))
  }
}
