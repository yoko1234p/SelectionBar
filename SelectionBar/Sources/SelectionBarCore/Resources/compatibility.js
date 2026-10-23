/* Independently implemented host for documented PopClip extension APIs. */
const __runtimePhase = __phase;
let __populating = 0;
const __effects = [];
var __finished = false, __response = "";
const __effect = (type, data = {}) => {
  if (__populating || !["action", "auth"].includes(__runtimePhase)) throw Error(`${type} unavailable during population`);
  const effect = { type, ...data };
  if (__hasHost) {
    const value = __json(__host(JSON.stringify(effect))).result;
    return value;
  }
  __effects.push(effect);
};
const __promiseEffect = (type, data = {}) => {
  if (__populating || !["action", "auth"].includes(__runtimePhase)) return Promise.reject(Error(`${type} unavailable during population`));
  if (!__hasAsyncHost) return Promise.resolve().then(() => __effect(type, data));
  return new Promise((resolve, reject) => __hostAsync(JSON.stringify({ type, ...data }), (raw) => {
    try {
      resolve(__json(raw).result);
    } catch (error) {
      reject(error);
    }
  }));
};
const __json = (raw) => {
  const v = JSON.parse(raw);
  if (v.error) {
    const error = Error(v.error);
    Object.assign(error, v);
    throw error;
  }
  return v;
};
const __externalPromise = (data) => {
  if (__populating || !["action", "auth"].includes(__runtimePhase)) return Promise.reject(Error("External action unavailable during population"));
  return new Promise((resolve, reject) => __externalAsync(JSON.stringify(data), (raw) => {
    try {
      resolve(__json(raw));
    } catch (error) {
      reject(error);
    }
  }));
};
const print = (...args) => {
};
const console = { log: print, warn: print, error: print, info: print };
const setTimeout = (fn, ms = 0, ...args) => __timersAPI.start(fn, ms, false, args);
const clearTimeout = (id) => __timersAPI.clear(id);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let __definition;
const defineExtension = (definition) => {
  __definition = definition;
  return definition;
};
function __prepareInput(input) {
  for (const key of ["urls", "nonHttpUrls", "emails", "paths"]) {
    input.data[key] ??= [];
    input.data[key].ranges = input.__ranges?.[key] ?? [];
  }
  delete input.__ranges;
  if (input.html && globalThis.__bundledModules) {
    input.html = util.cleanHtml(input.html);
    input.markdown = util.htmlToMarkdown(input.html);
    try {
      input.xhtml = __bundledModules["dom-serializer"].default(__bundledModules.htmlparser2.parseDocument(input.html), { xmlMode: true });
    } catch {
      input.xhtml = input.html;
    }
  }
  return input;
}
const popclip = {
  input: __input,
  context: __context,
  options: new Proxy(__options, { get(target, key) {
    const value = target[key];
    if (key === "authsecret" && (value == null || value === "")) throw Error("Not signed in");
    return value;
  } }),
  get modifiers() {
    const flags = __populating || __runtimePhase === "population" ? 0 : __modifierFlags;
    return { shift: !!(flags & 131072), control: !!(flags & 262144), option: !!(flags & 524288), command: !!(flags & 1048576) };
  },
  pasteText: async (text, options = {}) => __promiseEffect("paste", { text: String(text), ...options }),
  copyText: async (text, options = {}) => __promiseEffect("copy", { text: String(text), ...options }),
  pasteContent: async (content, options = {}) => __promiseEffect("pasteContent", { content, ...options }),
  copyContent: async (content, options = {}) => __promiseEffect("copyContent", { content, ...options }),
  performCommand: async (command, options = {}) => {
    const value = await __promiseEffect("command", { command, ...options });
    if (value?.clipboard) Object.assign(__clipboard, value.clipboard);
    return value;
  },
  showText: (text, options = {}) => __effect("show", { text: String(text), ...options }),
  showSuccess: () => __effect("success"),
  showFailure: () => __effect("failure"),
  showSettings: () => __effect("settings"),
  appear: () => __effect("appear"),
  pressKey: async (key, modifiers = 0, options = {}) => __promiseEffect("key", { key, modifiers, ...options }),
  pressKeys: async (keys, options = {}) => __promiseEffect("keys", { keys: keys.map((key) => typeof key === "number" ? "0x" + key.toString(16) : key), ...options }),
  openUrl: async (url, options = {}) => __promiseEffect("url", { url: url instanceof URL ? url.toString().replace(/\+/g, "%20") : String(url), ...options }),
  openTemplateUrl: async (template, text = __input.text, options = {}) => {
    let q = String(text).trim();
    if (options.clean) q = q.replace(/\s+/g, " ");
    if (options.verbatim ?? popclip.modifiers.option) q = `"${q}"`;
    let encode = (s) => options.plus ? encodeURIComponent(s).replace(/%20/g, "+") : encodeURIComponent(s);
    let url = template.replace(/\*\*\*|\{popclip text\}/g, encode(q));
    for (const [k, v] of Object.entries(options.options ?? {})) url = url.split(`{popclip option ${k}}`).join(encode(v));
    if (options.copy) await popclip.copyText(q);
    return popclip.openUrl(url, options);
  },
  performService: async (name, input = __input.text) => __promiseEffect("service", { name, input }),
  runShortcut: async (name, options = {}) => __promiseEffect("shortcut", { name, ...options.input === void 0 ? {} : { input: options.input } }),
  revealFile: (path) => __effect("reveal", { path }),
  runAppleScript: async (source, options = {}) => (await __externalPromise({ kind: "applescript", source, options })).value,
  runAppleScriptFile: async (path, options = {}) => (await __externalPromise({ kind: "applescript", path, options })).value,
  runShellScript: async (source, options = {}) => __externalPromise({ kind: "shell", source, options }),
  runShellScriptFile: async (path, options = {}) => __externalPromise({ kind: "shell", path, options }),
  share: async (name, items) => __promiseEffect("share", { name, items: items.map((item) => item instanceof URL ? { url: item.toString().replace(/\+/g, "%20") } : item) }),
  signInRequiredError: (message) => {
    __effect("signInRequired", { extensionID: __extensionID });
    return Error(message ?? "Sign in required");
  },
  settingsRequiredError: (message) => {
    __effect("settings");
    return Error(message ?? "Settings required");
  }
};
function __readClipboard() {
  if (__hasHost && __runtimePhase === "action") {
    const current = __effect("clipboardRead");
    if (current && typeof current === "object") {
      for (const key of Object.keys(__clipboard)) delete __clipboard[key];
      Object.assign(__clipboard, current);
    }
  }
  return __clipboard;
}
const pasteboard = {
  get text() {
    return __readClipboard()["public.utf8-plain-text"] ?? "";
  },
  set text(text) {
    __effect("copy", { text: String(text), notify: false });
    for (const key of Object.keys(__clipboard)) delete __clipboard[key];
    __clipboard["public.utf8-plain-text"] = String(text);
  },
  get content() {
    return { ...__readClipboard() };
  },
  set content(content) {
    __effect("copyContent", { content, notify: false });
    for (const key of Object.keys(__clipboard)) delete __clipboard[key];
    Object.assign(__clipboard, content);
  }
};
const util = {
  constant: { MODIFIER_SHIFT: 131072, MODIFIER_CONTROL: 262144, MODIFIER_OPTION: 524288, MODIFIER_COMMAND: 1048576, KEY_RETURN: 36, KEY_TAB: 48, KEY_SPACE: 49 },
  base64Encode: (s, options = {}) => {
    let v = __utility("base64Encode", String(s));
    if (options.urlSafe) v = v.replace(/\+/g, "-").replace(/\//g, "_");
    return options.trimmed ? v.replace(/=+$/, "") : v;
  },
  base64Decode: (s) => __utility("base64Decode", String(s)),
  clarify: (s) => JSON.parse(__utility("base64Decode", s.replace(/[a-zA-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + (c.toLowerCase() <= "m" ? 13 : -13))))),
  randomUuid: () => __utility("uuid", ""),
  sleep,
  buildQuery: (params) => Object.entries(params).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&"),
  parseQuery: (q) => Object.fromEntries(q.replace(/^\?/, "").split("&").filter(Boolean).map((s) => {
    const i = s.indexOf("=");
    return [decodeURIComponent(i < 0 ? s : s.slice(0, i)), decodeURIComponent(i < 0 ? "" : s.slice(i + 1))];
  })),
  escapeRegExp: (s) => String(s).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
  escapeHtml: (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])
};
const $ = (strings, ...values) => popclip.runShellScript(strings.map((s, i) => s + (i < values.length ? `'${String(values[i]).replace(/'/g, "'\\''")}'` : "")).join(""), { interpreter: "/bin/zsh" });
const __moduleCache = {};
function require(name) {
  return __require(name, __packageRoot + "/Config.js");
}
function __require(name, from) {
  const resolved = JSON.parse(__readModule(name, from));
  if (resolved.error) throw Error(resolved.error);
  if (resolved.notFound) {
    if (!name.startsWith("./") && !name.startsWith("../")) {
      if (globalThis.__bundledModules && Object.prototype.hasOwnProperty.call(__bundledModules, name)) return __bundledModules[name];
      if (name === "popclip") return popclip;
    }
    return void 0;
  }
  const file = resolved;
  if (__moduleCache[file.path]) return __moduleCache[file.path].exports;
  const module = { exports: {} };
  __moduleCache[file.path] = module;
  if (file.format === "json") {
    module.exports = JSON.parse(file.source);
    return module.exports;
  }
  const code = typeof __transpile === "function" ? __transpile(file.source, file.path === __packageRoot + "/" + __config.module && __config.__sourceextension === "ts" ? file.path + ".ts" : file.path) : file.source.replace(/^export default /m, "module.exports.default = ");
  new Function("require", "module", "exports", code)((n) => __require(n, file.path), module, module.exports);
  return module.exports;
}
function __moduleInput(properties, dynamic) {
  if (dynamic) return __prepareInput(structuredClone(__input));
  const regex = properties.regex;
  const nativeProperties = { ...properties };
  if (regex instanceof RegExp) nativeProperties.regex = null;
  const input = JSON.parse(__matchAction(JSON.stringify(nativeProperties), JSON.stringify(__options)));
  if (!input) return null;
  if (regex instanceof RegExp) {
    const matcher = new RegExp(regex.source, regex.flags.replace(/[gy]/g, ""));
    const match = matcher.exec(input.matchedText);
    if (!match) return null;
    input.matchedText = match[0];
    input.regexResult = match;
  }
  return __prepareInput(input);
}
const __actionPropertyNames = Object.fromEntries([
  "excludedApps",
  "requiredApps",
  "captureHtml",
  "captureRtf",
  "stayVisible",
  "restorePasteboard",
  "wantsPrimaryDisplay",
  "wantsInitialDisplay",
  "preserveColor",
  "preserveAspect",
  "flipX",
  "flipY",
  "moveX",
  "moveY",
  "checkInstalled",
  "bundleIdentifiers",
  "authKeychain"
].map((name) => [name.toLowerCase(), name]));
function __mergedProperties(...sources) {
  const properties = {};
  for (const source of sources) {
    for (const [key, value] of Object.entries(source ?? {})) {
      properties[__actionPropertyNames[key.toLowerCase()] ?? key] = value;
    }
  }
  return properties;
}
async function __moduleList(source, inherited, path, submenu = false) {
  const dynamic = typeof source === "function";
  if (dynamic) {
    if (!(__config.entitlements ?? []).includes("dynamic")) throw Error("Population function requires dynamic entitlement");
    __populating++;
    try {
      source = await source(popclip.input, popclip.options, popclip.context);
    } finally {
      __populating--;
    }
  }
  if (!Array.isArray(source)) source = source == null ? [] : [source];
  return source.map((value, index) => {
    const action = typeof value === "function" ? { code: value } : value;
    if (!action || typeof action !== "object") return null;
    if (action.separator) return submenu ? { separator: true, path: [...path, index] } : null;
    const properties = __mergedProperties(submenu ? {} : inherited, action);
    const input = __moduleInput(properties, dynamic);
    return input ? { action, properties, input, path: [...path, index], dynamic } : null;
  }).filter(Boolean);
}
function __actionMetadata(entry) {
  if (entry.separator) return { separator: true, path: entry.path };
  const { action, properties, path } = entry;
  return {
    index: path[path.length - 1],
    path,
    title: typeof properties.title === "string" ? properties.title : properties.title ? __localize(JSON.stringify(properties.title)) : __config.__name,
    icon: properties.icon ?? null,
    iconProperties: Object.fromEntries(["preserveColor", "preserveAspect", "flipX", "flipY", "moveX", "moveY", "scale", "rotate", "square", "circle", "search", "strike", "filled", "monospaced"].flatMap((key) => {
      const value = properties[key];
      return value === void 0 ? [] : [[key, value]];
    })),
    disabled: typeof (action.code ?? action.action) !== "function" && !action.submenu,
    submenu: !!action.submenu,
    hasCode: typeof (action.code ?? action.action) === "function",
    captureHtml: !!properties.captureHtml,
    captureRtf: !!properties.captureRtf,
    wantsPrimaryDisplay: !!properties.wantsPrimaryDisplay,
    wantsInitialDisplay: !!properties.wantsInitialDisplay,
    apps: properties.apps ?? (properties.app ? [properties.app] : [])
  };
}
async function __findInitial(list, depth = 0, budget = { count: 0 }) {
  if (depth > 24) throw Error("Submenu nesting exceeds 24 levels");
  for (const entry of list) {
    if (++budget.count > 4096) throw Error("Action catalog exceeds 4096 entries");
    if (entry.separator || !entry.action.submenu) continue;
    const initial = entry.properties.wantsInitialDisplay;
    if (typeof entry.action.submenu === "function" && !initial) continue;
    const children = await __moduleList(entry.action.submenu, entry.properties, entry.path, true);
    if (initial && children.some((child) => !child.separator)) {
      return { path: entry.path, actions: children.map(__actionMetadata) };
    }
    const found = await __findInitial(children, depth + 1, budget);
    if (found) return found;
  }
  return null;
}
async function __start() {
  popclip.input = __prepareInput(popclip.input);
  let result, actions = [], options = [], authAvailable = false, didExecute = false, initialPath = null, initialActions = null;
  try {
    if (__config.module) {
      const exports = __require("./" + __config.module, __packageRoot + "/Config.js");
      let definition = __definition ?? exports?.default ?? exports;
      if (typeof definition === "function") definition = await definition(popclip.input, popclip.options, popclip.context);
      if (!definition || typeof definition !== "object") throw Error("Module does not export an extension definition");
      authAvailable = typeof definition.auth === "function";
      options = definition.options ?? __config.options ?? [];
      for (const option of options) {
        const id = option.identifier;
        if (option.type === "password" || option.type === "heading") {
          delete __options[id];
          continue;
        }
        const previous = option.migrateFrom ?? option.migratefrom;
        if (previous && typeof __storedOptions[previous] === "string" && __storedOptions[previous]) __options[id] = __storedOptions[previous];
        else if (__storedOptions[id] === void 0) __options[id] = option.type === "secret" ? __options[id] ?? "" : option.defaultValue ?? option.defaultvalue ?? (option.type === "boolean" ? true : option.type === "multiple" && !(option.allowNone ?? option.allownone) ? option.values?.[0] ?? "" : "");
      }
      if (__runtimePhase === "auth") {
        if (!authAvailable) throw Error("Extension does not define auth(info,flow).");
        const flow = async (url, params = {}, expect = []) => __promiseEffect("oauth", { url, params, expect });
        result = await definition.auth(__authInfo, flow);
      } else {
        const source = definition.actions ?? definition.submenu ?? (definition.action ? [definition.action] : []);
        const rootProperties = __mergedProperties(__config, definition);
        for (const key of ["name", "icon", "identifier", "popclipVersion", "macosVersion", "entitlements", "module", "showAs", "offersMultipleInstances"]) {
          delete rootProperties[key];
          if (__config[key.toLowerCase()] !== void 0) rootProperties[key] = __config[key.toLowerCase()];
        }
        let list = await __moduleList(source, rootProperties, [], !!definition.submenu);
        let target = null;
        const path = __modulePath ?? [];
        for (let depth = 0; depth < path.length; depth++) {
          target = list.find((entry) => entry.path[depth] === path[depth]);
          if (!target || target.separator) throw Error("Action no longer available");
          if (depth < path.length - 1) {
            if (!target.action.submenu) throw Error("Submenu no longer available");
            list = await __moduleList(target.action.submenu, target.properties, target.path, true);
          }
        }
        if (!path.length && __runtimePhase === "action") {
          const actionable = list.filter((entry) => !entry.separator);
          if (actionable.length === 1) target = actionable[0];
        }
        if (target && target.action.submenu && (__openSubmenu || typeof (target.action.code ?? target.action.action) !== "function")) {
          list = await __moduleList(target.action.submenu, target.properties, target.path, true);
          target = null;
        }
        actions = list.map(__actionMetadata);
        if (__runtimePhase === "population" && !path.length) {
          const initial = await __findInitial(list);
          if (initial) {
            initialPath = initial.path;
            initialActions = initial.actions;
          }
        }
        if (__runtimePhase === "action" && target && !target.separator) {
          const fn = target.action.code ?? target.action.action;
          if (typeof fn === "function") {
            if (definition.auth && !__options.authsecret) throw Error("此擴充需要登入；請到擴充設定按登入。");
            popclip.input = target.input;
            const p = target.properties;
            const apps = p.apps ?? (p.app ? [p.app] : []);
            if (apps.length) await __promiseEffect("checkApps", { apps });
            const before = p.before;
            if (before) await __promiseEffect("step", { step: before });
            result = await fn(popclip.input, popclip.options, popclip.context);
            const after = p.after;
            if (after) await __promiseEffect("step", { step: after, result: result ?? "", restore: p.restorePasteboard ?? false });
            if (p.stayVisible) __effect("appear");
            didExecute = true;
          }
        }
      }
    } else {
      let code = __config.javascript;
      if (__config.javascriptfile) code = __json(__readModule("./" + __config.javascriptfile, __packageRoot + "/Config.js")).source;
      if (typeof code !== "string") throw Error("No JavaScript action");
      if (typeof __transpile === "function") code = __transpile(code, __config.__sourceextension === "ts" ? "Config.ts" : "Config.js");
      if (__runtimePhase === "action") {
        result = await new Function("return (async()=>{" + code + "\n})()")();
        didExecute = true;
      }
    }
    __response = JSON.stringify({ result: result ?? null, effects: __effects, actions, options, authAvailable, didExecute, initialPath, initialActions, error: null });
  } catch (error) {
    __response = JSON.stringify({ result: null, effects: [], actions, options, authAvailable, didExecute, error: String(error.message ?? error) });
  }
  __finished = true;
}
