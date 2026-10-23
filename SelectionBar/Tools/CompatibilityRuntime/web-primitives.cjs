const bytes = value => {
  if (value instanceof Blob) return value.buffer;
  if (typeof value === 'string') return Buffer.from(value, 'utf8');
  if (value instanceof ArrayBuffer) return Buffer.from(value);
  if (ArrayBuffer.isView(value)) return Buffer.from(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError('Expected string, Blob, ArrayBuffer or typed array');
};
class Blob {
  constructor(parts = [], options = {}) {
    this._bytes = Buffer.concat(Array.from(parts, part => {
      if (part instanceof Blob || part instanceof ArrayBuffer || ArrayBuffer.isView(part)) return bytes(part);
      return Buffer.from(String(part), 'utf8');
    }));
    this._type = /^[\x20-\x7e]*$/.test(options.type ?? '') ? String(options.type ?? '').toLowerCase() : '';
    this._closed = false;
  }
  get buffer() { return Buffer.from(this._bytes); }
  get size() { return this._bytes.length; }
  get type() { return this._type; }
  get isClosed() { return this._closed; }
  slice(start = 0, end = this.size, contentType = '') {
    const normalize = value => {
      const number = Number(value);
      if (Number.isNaN(number) || number === -Infinity) return 0;
      if (number === Infinity) return this.size;
      const integer = Math.trunc(number);
      return integer < 0 ? Math.max(this.size + integer, 0) : Math.min(integer, this.size);
    };
    const first = normalize(start), last = normalize(end);
    return new Blob([this._bytes.subarray(first, Math.max(first, last))], { type: contentType });
  }
  close() { this._closed = true; this._bytes = Buffer.alloc(0); }
  async text() { return this._bytes.toString('utf8'); }
  async arrayBuffer() {
    return this._bytes.buffer.slice(this._bytes.byteOffset, this._bytes.byteOffset + this.size);
  }
  get [Symbol.toStringTag]() { return 'Blob'; }
}
globalThis.Blob = Blob;

// Both timer APIs share numeric identifiers, so either clear function can cancel either kind.
let timerSequence = 0;
const timers = new Map();
globalThis.__timersAPI = {
  start(callback, delay = 0, repeating = false, args = []) {
    if (typeof callback !== 'function') throw new TypeError('Timer callback must be a function');
    const id = ++timerSequence;
    const milliseconds = Math.min(2147483647, Math.max(repeating ? 1 : 0, Number(delay) || 0));
    const token = { native:null };
    const fire = () => {
      if (timers.get(id) !== token) return;
      if (!repeating) timers.delete(id);
      callback(...args);
      if (repeating && timers.get(id) === token) token.native = __setTimer(fire, milliseconds);
    };
    timers.set(id, token);
    token.native = __setTimer(fire, milliseconds);
    return id;
  },
  clear(id) {
    const token = timers.get(Number(id));
    if (token) { timers.delete(Number(id)); __clearTimer(token.native); }
  },
};

class Events {
  constructor() { this._listeners = Object.create(null); }
  addEventListener(type, listener) {
    if (typeof listener !== 'function') return;
    (this._listeners[type] ??= new Set()).add(listener);
  }
  removeEventListener(type, listener) { this._listeners[type]?.delete(listener); }
  _emit(type) {
    const event = { type, target: this, currentTarget: this, loaded: this._loaded ?? 0, lengthComputable: false };
    const callbacks = [...(this._listeners[type] ?? [])];
    if (typeof this['on' + type] === 'function') callbacks.unshift(this['on' + type]);
    for (const callback of callbacks) callback.call(this, event);
  }
}
class XMLHttpRequest extends Events {
  constructor() {
    super();
    this.readyState = 0; this.status = 0; this.statusText = '';
    this.timeout = 0; this.responseType = ''; this.responseURL = '';
    this.withCredentials = false; this.response = null; this.responseText = '';
    this.upload = new Events(); this._headers = Object.create(null); this._responseHeaders = {};
    this._generation = 0;
  }
  open(method, url, async = true, username, password) {
    if (this._sent) this.abort();
    this._generation++;
    this._method = String(method).toUpperCase(); this._url = new URL(String(url)).href;
    if (!/^https?:/.test(this._url)) throw new TypeError('Only HTTP(S) requests are supported');
    this._async = Boolean(async); this._aborted = false; this._sent = false;
    this.status = 0; this.statusText = ''; this.response = null; this.responseText = ''; this.responseURL = '';
    this._headers = Object.create(null); this._responseHeaders = {};
    if (username !== undefined) this._headers.Authorization = 'Basic ' + Buffer.from(`${username}:${password ?? ''}`).toString('base64');
    this._state(1);
  }
  setRequestHeader(name, value) {
    if (this.readyState !== 1 || this._sent) throw new Error('Invalid XHR state');
    const key = String(name).toLowerCase();
    if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(key) || /[\r\n\0]/.test(String(value))) throw new TypeError('Invalid HTTP header');
    this._headers[key] = key in this._headers ? this._headers[key] + ', ' + value : String(value);
  }
  getResponseHeader(name) { return this.readyState < 2 ? null : this._responseHeaders[String(name).toLowerCase()] ?? null; }
  getAllResponseHeaders() {
    return this.readyState < 2 ? '' : Object.entries(this._responseHeaders).map(([k, v]) => `${k}: ${v}\r\n`).join('');
  }
  overrideMimeType(mime) { this._mime = String(mime); }
  _state(state) { this.readyState = state; this._emit('readystatechange'); }
  _fail(type, generation = this._generation) {
    if (generation !== this._generation) return;
    this.status = 0; this._sent = false; this._state(4);
    if (generation !== this._generation) return;
    this._emit(type);
    if (generation === this._generation) this._emit('loadend');
  }
  send(body = null) {
    if (this.readyState !== 1 || this._sent) throw new Error('Invalid XHR state');
    if (!Number.isFinite(this.timeout) || this.timeout < 0) throw new TypeError('Invalid XHR timeout');
    const request = { url: this._url, method: this._method, headers: this._headers, timeout: this.timeout };
    if (body !== null && this._method !== 'GET' && this._method !== 'HEAD') {
      request.bodyBase64 = bytes(body).toString('base64');
      if (body instanceof Blob && body.type && !this._headers['content-type']) request.headers['content-type'] = body.type;
    }
    const generation = ++this._generation;
    const active = () => generation === this._generation && !this._aborted;
    this._sent = true; this._emit('loadstart');
    if (!active()) return;
    const complete = raw => {
      if (!active()) return;
      this._nativeID = null;
      let result;
      try { result = JSON.parse(raw); } catch { this._fail('error', generation); return; }
      if (result.error) { this._fail(result.timeout || /timed?\s*out|逾時|超時|-1001/i.test(result.error) ? 'timeout' : 'error', generation); return; }
      this.status = result.status; this.statusText = result.statusText ?? '';
      this.responseURL = result.responseURL ?? result.url ?? this._url;
      this._responseHeaders = Object.fromEntries(Object.entries(result.headers ?? {}).map(([k,v]) => [k.toLowerCase(), String(v)]));
      this._state(2);
      if (!active()) return;
      const data = result.bodyBase64 !== undefined ? Buffer.from(result.bodyBase64, 'base64') : Buffer.from(result.body ?? '', 'utf8');
      this._loaded = data.length; this.responseText = data.toString('utf8'); this._state(3);
      if (!active()) return;
      switch (this.responseType) {
        case 'arraybuffer': this.response = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength); break;
        case 'blob': this.response = new Blob([data], { type: this._mime ?? this.getResponseHeader('content-type') ?? '' }); break;
        case 'json': try { this.response = JSON.parse(this.responseText); } catch { this.response = null; } break;
        default: this.response = this.responseText;
      }
      this._sent = false; this._state(4);
      if (!active()) return;
      this._emit('progress'); if (!active()) return;
      this._emit('load'); if (!active()) return;
      this._emit('loadend');
    };
    if (this._async && typeof globalThis.__httpStart === 'function') {
      const id = __httpStart(JSON.stringify(request), complete);
      if (active() && this._sent) this._nativeID = id;
    } else {
      const perform = () => { if (active()) { try { complete(__http(JSON.stringify(request))); } catch { this._fail('error', generation); } } };
      if (this._async) this._timer = __setTimer(perform, 0); else perform();
    }
  }
  abort() {
    const generation = ++this._generation;
    this._aborted = true;
    if (this._nativeID != null && typeof globalThis.__httpCancel === 'function') __httpCancel(this._nativeID);
    if (this._timer != null) __clearTimer(this._timer);
    this._nativeID = null; this._timer = null;
    const active = this._sent; this._sent = false;
    if (active) this._fail('abort', generation);
    if (generation === this._generation) this.readyState = 0;
  }
}
for (const [name, value] of Object.entries({ UNSENT:0, OPENED:1, HEADERS_RECEIVED:2, LOADING:3, DONE:4 })) {
  Object.defineProperty(XMLHttpRequest, name, { value });
  Object.defineProperty(XMLHttpRequest.prototype, name, { value });
}
globalThis.XMLHttpRequest = XMLHttpRequest;
