/* Independent implementation of the documented passive extension utilities. */
(() => {
  const native = (operation, input = {}) => {
    const result = JSON.parse(__nativeExtras(operation, JSON.stringify(input)));
    if (result.error) throw new Error(result.error);
    return result.value;
  };
  const data = value => {
    if (!(value instanceof Uint8Array)) throw new TypeError('Expected Uint8Array');
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  };
  Object.assign(util, {
    base64Encode(value, options = {}) {
      const bytes = typeof value === 'string' ? Buffer.from(value, 'utf8') : data(value);
      let result = bytes.toString('base64');
      if (options.urlSafe) result = result.replace(/\+/g, '-').replace(/\//g, '_');
      return options.trimmed ? result.replace(/=+$/, '') : result;
    },
    base64Decode(value, options = {}) {
      const bytes = Buffer.from(String(value), 'base64');
      if (options.bytes) return new Uint8Array(bytes);
      const text = bytes.toString('utf8');
      if (!Buffer.from(text, 'utf8').equals(bytes)) throw new TypeError('Decoded data is not UTF-8 text');
      return text;
    },
    clarify(value) {
      return JSON.parse(util.base64Decode(String(value).replace(/[a-zA-Z]/g,
        char => String.fromCharCode(char.charCodeAt(0) + (char.toLowerCase() <= 'm' ? 13 : -13)))));
    },
    buildQuery(params) { return new URLSearchParams(params).toString(); },
    parseQuery(query) { return Object.fromEntries(new URLSearchParams(String(query).replace(/^\?/, ''))); },
    randomUuid() { return native('uuid'); },
    randomUniform(max) { return native('randomUniform', { max: Number(max) >>> 0 }); },
    getRandomValues(array) {
      if (!ArrayBuffer.isView(array) || array instanceof DataView || array instanceof Float32Array || array instanceof Float64Array) {
        throw new TypeError('getRandomValues requires an integer typed array');
      }
      const bytes = Buffer.from(native('random', { count: array.byteLength }), 'base64');
      new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
    },
    hash(value, algorithm) { return new Uint8Array(Buffer.from(native('hash', { data: data(value).toString('base64'), algorithm }), 'base64')); },
    hmac(value, key, algorithm) { return new Uint8Array(Buffer.from(native('hmac', { data: data(value).toString('base64'), key: data(key).toString('base64'), algorithm }), 'base64')); },
    getDictionaryDefinition(text) { return native('dictionary', { text: String(text) }) ?? undefined; },
    hasDictionaryDefinition(text) { return native('dictionary', { text: String(text) }) != null; },
    getSpellingLanguages() { return native('spellingLanguages'); },
    getPreferredSpellingLanguages() { return native('preferredSpellingLanguages'); },
    checkSpelling(text, options) { return native('checkSpelling', { text: String(text), language: options?.language }); },
    getSpellingGuesses(text, options) { return native('spellingGuesses', { text: String(text), ...options }); },
    localize(text) {
      const translations = {
        'zh-Hant': { Cut:'剪下', Copy:'複製', Paste:'貼上', 'Paste and Enter':'貼上並送出', 'Paste and Match Style':'貼上並符合樣式' },
        'zh-Hans': { Cut:'剪切', Copy:'复制', Paste:'粘贴', 'Paste and Enter':'粘贴并回车', 'Paste and Match Style':'粘贴并匹配样式' },
        ja: { Cut:'カット', Copy:'コピー', Paste:'ペースト' },
        ko: { Cut:'오려두기', Copy:'복사하기', Paste:'붙여넣기' },
      };
      const code = native('locale').localeIdentifier.replace(/_/g, '-');
      const language = code.startsWith('zh') ? (/Hant|HK|TW|MO/i.test(code) ? 'zh-Hant' : 'zh-Hans') : code.split('-')[0];
      return translations[language]?.[text] ?? String(text);
    },
    htmlToMarkdown(html, options = {}) {
      return new __bundledModules.turndown({ headingStyle: 'atx', ...options }).turndown(String(html));
    },
    cleanHtml(html) { return __bundledModules['sanitize-html'](String(html)); },
  });
  Object.defineProperties(util, {
    localeInfo: { get: () => native('locale') },
    timeZoneInfo: { get: () => native('timeZone') },
  });
  Object.assign(util.constant, {
    KEY_DELETE:51, KEY_ESCAPE:53, KEY_LEFTARROW:123, KEY_RIGHTARROW:124, KEY_DOWNARROW:125, KEY_UPARROW:126,
  });
  const richValues = new WeakMap();
  globalThis.RichString = class RichString {
    constructor(source, options = {}) {
      let format = options.format ?? 'rtf';
      let text = String(source);
      if (format === 'markdown') { text = __renderMarkdown(text); format = 'html'; }
      if (format === 'html') {
        const sanitizer = __bundledModules['sanitize-html'];
        text = sanitizer(text, {
          allowedTags: [...new Set([...sanitizer.defaults.allowedTags, 'u', 's', 'strike', 'font'])],
          allowedAttributes: { '*':['style'], a:['href','name','target'], font:['color','face','size'] },
          allowedStyles: { '*': {
            color: [/^#[0-9a-f]{3,8}$/i, /^[a-z]+$/i, /^rgba?\([\d\s.,%]+\)$/i],
            'background-color': [/^#[0-9a-f]{3,8}$/i, /^[a-z]+$/i, /^rgba?\([\d\s.,%]+\)$/i],
            'font-size': [/^\d{1,3}(?:\.\d+)?(?:px|pt|em|%)$/],
            'font-family': [/^[\w\s,"'-]+$/],
            'font-weight': [/^(?:normal|bold|[1-9]00)$/],
            'font-style': [/^(?:normal|italic|oblique)$/],
            'text-decoration': [/^(?:none|underline|line-through)$/],
            'text-align': [/^(?:left|right|center|justify)$/],
          } },
        });
        text = __bundledModules['dom-serializer'].default(__bundledModules.htmlparser2.parseDocument(text), { xmlMode:true });
      }
      const value = native('richString', { source:text, format });
      richValues.set(this, value);
    }
    get rtf() { return richValues.get(this).rtf; }
    get html() { return richValues.get(this).html; }
    toJSON() { return { __richString:true, rtf:this.rtf, html:this.html }; }
  };
  // Native timers run on the same JavaScript thread; cancellation invalidates every outstanding timer.
  globalThis.setInterval = (callback, delay = 0, ...args) => __timersAPI.start(callback, delay, true, args);
  globalThis.clearInterval = id => __timersAPI.clear(id);
})();
