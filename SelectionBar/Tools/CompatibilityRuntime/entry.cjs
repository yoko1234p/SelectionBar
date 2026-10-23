// Real, independently licensed packages. No original application's executable code.
globalThis.Buffer = require('buffer').Buffer;
require('fast-text-encoding');
require('core-js/actual/structured-clone');
const urls = require('whatwg-url');
globalThis.URL = urls.URL;
globalThis.URLSearchParams = urls.URLSearchParams;
globalThis.atob = input => {
  let value = String(input).replace(/[\t\n\f\r ]/g, '');
  if (value.length % 4 === 0) value = value.replace(/={1,2}$/, '');
  if (value.length % 4 === 1 || /[^a-zA-Z0-9+/]/.test(value)) throw new TypeError('Invalid base64 string');
  return Buffer.from(value, 'base64').toString('binary');
};
globalThis.btoa = input => {
  const text = String(input);
  if ([...text].some(char => char.charCodeAt(0) > 255)) throw new TypeError('btoa requires byte characters');
  return Buffer.from(text, 'binary').toString('base64');
};
require('./web-primitives.cjs');
const modules = {
  axios: require('axios'), buffer: require('buffer'),
  'case-anything': require('case-anything'), 'content-type': require('content-type'),
  'dom-serializer': require('dom-serializer'), 'emoji-regex': require('emoji-regex'),
  entities: require('entities'), 'fast-json-stable-stringify': require('fast-json-stable-stringify'),
  'fast-plist': require('fast-plist'), htmlparser2: require('htmlparser2'),
  'js-yaml': require('js-yaml'), linkedom: require('linkedom'), linkifyjs: require('linkifyjs'),
  'oauth-1.0a': require('oauth-1.0a'), 'rot13-cipher': require('rot13-cipher'),
  'sanitize-html': require('sanitize-html'), sucrase: require('sucrase'),
  turndown: require('turndown'), valibot: require('valibot'),
};
// Turndown's browser build otherwise expects a global document. Give it a private
// parsed tree, preserving its public constructor/prototype without exposing DOM globals.
const convertMarkdown = modules.turndown.prototype.turndown;
modules.turndown.prototype.turndown = function (input) {
  if (typeof input === 'string') {
    input = modules.linkedom.parseHTML('<html><head></head><body>' + input + '</body></html>').document.body;
  }
  return convertMarkdown.call(this, input);
};
// CommonJS functions are imported directly; ESM default values retain named exports.
for (const [name, value] of Object.entries(modules)) {
  if (value && typeof value.default === 'function') {
    const exported = value.default;
    for (const key of Object.keys(value)) {
      if (!(key in exported)) Object.defineProperty(exported, key, { value: value[key], enumerable: true });
    }
    modules[name] = exported;
  }
}
globalThis.__bundledModules = modules;
globalThis.__renderMarkdown = source => require('marked').marked.parse(String(source), { async: false, gfm: true });
globalThis.__transpile = (source, filename) => modules.sucrase.transform(String(source), {
  transforms: /\.ts$/i.test(filename) ? ['typescript', 'imports'] : ['imports'],
  filePath: filename, disableESTransforms: true,
}).code;
