// Aster 网页工具运行时：文档开始时注入（仅主 frame、page 内容世界），给插件页面提供 `window.aster`。
// 请求经 `window.webkit.messageHandlers.aster` 发给原生，事件由原生调用 `window.__asterReceive(event)` 送达。
// 协议见 docs/developer/tools-and-plugins.md「网页工具」。这里不使用 eval / Function，页面 CSP 也不允许。
(() => {
  "use strict";

  if (Object.prototype.hasOwnProperty.call(window, "aster")) return;

  const PROTOCOL_VERSION = 1;
  // 注入时就取下通道引用：页面之后改写 `window.webkit` 也不影响桥接。
  const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aster;
  const postMessage = channel && typeof channel.postMessage === "function" ? channel.postMessage.bind(channel) : null;
  const ERROR_PATTERN = /^([a-z_]+): ([\s\S]*)$/;

  // 桥接失败时 Promise 拒绝的错误：`code` 是原生错误码（如 permission_denied），`message` 是说明。
  class AsterError extends Error {
    constructor(code, message) {
      super(message);
      this.name = "AsterError";
      this.code = code;
    }
  }

  // 原生回复的错误字符串是 "<code>: <message>"，解析不出时归为 failed。
  const toAsterError = (error) => {
    if (error instanceof AsterError) return error;
    const text = error && typeof error.message === "string" ? error.message : String(error);
    const match = ERROR_PATTERN.exec(text);
    return match ? new AsterError(match[1], match[2]) : new AsterError("failed", text);
  };

  // 发一次桥接调用；原生回 undefined 时归一成 null，失败统一转成 AsterError。
  const call = (method, params) => {
    if (!postMessage) return Promise.reject(new AsterError("unavailable", "Aster bridge is unavailable"));
    let pending;
    try {
      pending = postMessage({ v: PROTOCOL_VERSION, method, params: params || {} });
    } catch (error) {
      return Promise.reject(toAsterError(error));
    }
    return Promise.resolve(pending).then(
      (value) => (value === undefined ? null : value),
      (error) => { throw toAsterError(error); }
    );
  };

  // 参数整理时抛出的错误也以拒绝的 Promise 返回，调用方只需要处理一种失败形式。
  const guarded = (run) => {
    try {
      return run();
    } catch (error) {
      return Promise.reject(toAsterError(error));
    }
  };

  // 文本参数：字符串原样传，null / undefined 交给原生报 invalid_params，其它值转成字符串。
  const asText = (value) => (typeof value === "string" || value == null ? value : String(value));

  // 存储值必须是 JSON：先序列化再解析，Date 变成字符串、函数被丢弃，无法序列化的值直接拒绝。
  const toJSONValue = (value) => {
    if (value === undefined) throw new AsterError("invalid_params", "value must not be undefined");
    let text;
    try {
      text = JSON.stringify(value);
    } catch (error) {
      throw new AsterError("invalid_params", "value is not JSON serializable");
    }
    if (text === undefined) throw new AsterError("invalid_params", "value is not JSON serializable");
    return JSON.parse(text);
  };

  // 请求头支持普通对象、`Headers` 实例与 `[name, value]` 数组，统一成字符串到字符串的对象。
  const headerObject = (headers) => {
    const result = {};
    if (typeof headers.forEach === "function" && typeof headers.get === "function") {
      headers.forEach((value, name) => { result[String(name)] = String(value); });
      return result;
    }
    const entries = Array.isArray(headers) ? headers : Object.entries(headers);
    for (const [name, value] of entries) result[String(name)] = String(value);
    return result;
  };

  // `net.fetch(url, {method, headers, body})` 的参数；body 只接受字符串。
  const fetchParams = (url, options) => {
    const opts = options || {};
    const params = { url: String(url) };
    if (opts.method != null) params.method = String(opts.method);
    if (opts.headers != null) params.headers = headerObject(opts.headers);
    if (opts.body != null) {
      if (typeof opts.body !== "string") throw new AsterError("invalid_params", "body must be a string");
      params.body = opts.body;
    }
    return params;
  };

  // `files.pick({extensions, multiple})` 的参数；extensions 可以是单个字符串或数组。
  const pickParams = (options) => {
    const opts = options || {};
    const params = {};
    if (opts.extensions != null) {
      params.extensions = (Array.isArray(opts.extensions) ? opts.extensions : [opts.extensions]).map(String);
    }
    if (opts.multiple != null) params.multiple = Boolean(opts.multiple);
    return params;
  };

  // MARK: 外观

  // WebView 的外观由原生设置成与 App 一致，注入时先按 prefers-color-scheme 标好，
  // 之后以 enter / theme 事件为准。
  const colorSchemeQuery = typeof window.matchMedia === "function" ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  let appearance = colorSchemeQuery && colorSchemeQuery.matches ? "dark" : "light";

  // 把当前外观写到 <html>：data-aster-appearance 供插件 CSS 选择，color-scheme 让表单控件与滚动条跟着变。
  const paintAppearance = () => {
    const root = document.documentElement;
    if (!root) return false;
    root.dataset.asterAppearance = appearance;
    root.style.colorScheme = appearance;
    return true;
  };

  const setAppearance = (theme) => {
    appearance = theme && theme.appearance === "dark" ? "dark" : "light";
    paintAppearance();
  };

  if (!paintAppearance()) document.addEventListener("DOMContentLoaded", paintAppearance, { once: true });

  // MARK: 事件

  const listeners = { enter: [], query: [], theme: [] };
  let lastEnter = null;

  // 单个回调出错只记到控制台，不影响其它回调。
  const invoke = (callback, value) => {
    try {
      callback(value);
    } catch (error) {
      console.error(error);
    }
  };

  const emit = (kind, value) => {
    for (const callback of listeners[kind].slice()) invoke(callback, value);
  };

  // 注册回调，返回取消注册的函数；`replay` 不为空时立即用它调用一次（onEnter 注册晚了也能收到）。
  const subscribe = (kind, callback, replay) => {
    if (typeof callback !== "function") throw new TypeError("callback must be a function");
    listeners[kind].push(callback);
    if (replay != null) invoke(callback, replay);
    return () => {
      const index = listeners[kind].indexOf(callback);
      if (index >= 0) listeners[kind].splice(index, 1);
    };
  };

  // 原生事件入口：enter 缓存最近一次并同步外观，query 只给文本，theme 同步外观后通知。
  const receive = (event) => {
    if (!event || typeof event !== "object") return;
    switch (event.type) {
      case "enter": {
        if (event.theme) setAppearance(event.theme);
        lastEnter = Object.freeze({ code: event.code, input: event.input, context: event.context, theme: event.theme });
        emit("enter", lastEnter);
        break;
      }
      case "query":
        emit("query", typeof event.text === "string" ? event.text : "");
        break;
      case "theme":
        setAppearance(event.theme);
        emit("theme", event.theme);
        break;
      default:
        break;
    }
  };

  // MARK: API

  const aster = Object.freeze({
    version: PROTOCOL_VERSION,
    AsterError,
    onEnter: (callback) => subscribe("enter", callback, lastEnter),
    onQuery: (callback) => subscribe("query", callback),
    onThemeChange: (callback) => subscribe("theme", callback),
    getInput: () => call("tool.input"),
    setHeight: (px) => call("ui.setHeight", { height: Number(px) }),
    close: () => call("ui.close"),
    storage: Object.freeze({
      get: (key) => call("storage.get", { key: asText(key) }),
      set: (key, value) => guarded(() => call("storage.set", { key: asText(key), value: toJSONValue(value) })),
      remove: (key) => call("storage.remove", { key: asText(key) }),
      keys: () => call("storage.keys"),
    }),
    clipboard: Object.freeze({
      readText: () => call("clipboard.readText"),
      writeText: (text) => call("clipboard.writeText", { text: asText(text) }),
    }),
    terminal: Object.freeze({
      insert: (text) => call("terminal.insert", { text: asText(text) }),
      selection: () => call("terminal.selection"),
    }),
    files: Object.freeze({
      pick: (options) => guarded(() => call("files.pick", pickParams(options))),
      read: (path, encoding) => call("files.read", { path: asText(path), encoding: encoding == null ? "utf8" : String(encoding) }),
    }),
    net: Object.freeze({
      fetch: (url, options) => guarded(() => call("net.fetch", fetchParams(url, options))),
    }),
    notify: (title, body) => call("notify", body == null ? { title: asText(title) } : { title: asText(title), body: asText(body) }),
    openURL: (url) => call("shell.openURL", { url: String(url) }),
  });

  // 只读、不可重定义：页面脚本可以读但改不掉这两个入口。
  Object.defineProperty(window, "aster", { value: aster, enumerable: true, configurable: false, writable: false });
  Object.defineProperty(window, "__asterReceive", { value: receive, enumerable: false, configurable: false, writable: false });
})();
