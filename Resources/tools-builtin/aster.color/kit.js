// 内置网页工具的共用辅助：探测 window.aster、按 context.locale 选语言、跟随外观、显示提示与错误。
// 插件页面只能读取自己目录里的文件（aster-plugin://<id>/…），所以四个内置工具各带一份相同副本，改动时四份一起改。
(function (root) {
  'use strict';

  const LOCALES = ['zh-Hans', 'zh-Hant', 'en', 'ja', 'fr', 'de'];
  const FALLBACK_LOCALE = 'en';
  // 等 Aster 送来界面语言的最长时间；超时就先按当前语言显示，避免页面一直空白。
  const BOOT_TIMEOUT_MS = 400;

  // 各工具共用的文案；工具自己的文案在各自的 i18n.js 里，同名键以工具为准。
  const COMMON_STRINGS = {
    'zh-Hans': {
      copied: '已复制',
      inserted: '已预填到终端',
      needsAster: '在 Aster 里打开才能使用',
      'error.permission_denied': '这个工具没有所需的权限（{detail}）',
      'error.rate_limited': '操作太频繁，请稍后再试',
      'error.payload_too_large': '内容太大，无法处理',
      'error.unavailable': '暂时无法完成：{detail}',
      'error.invalid_params': '请求参数无效（{detail}）',
      'error.other': '出错了：{detail}',
    },
    'zh-Hant': {
      copied: '已複製',
      inserted: '已預填到終端機',
      needsAster: '在 Aster 中開啟才能使用',
      'error.permission_denied': '這個工具沒有所需的權限（{detail}）',
      'error.rate_limited': '操作太頻繁，請稍後再試',
      'error.payload_too_large': '內容太大，無法處理',
      'error.unavailable': '暫時無法完成：{detail}',
      'error.invalid_params': '請求參數無效（{detail}）',
      'error.other': '發生錯誤：{detail}',
    },
    en: {
      copied: 'Copied',
      inserted: 'Inserted into terminal',
      needsAster: 'Open this tool in Aster to use this',
      'error.permission_denied': 'This tool lacks the required permission ({detail})',
      'error.rate_limited': 'Too many requests. Try again in a moment',
      'error.payload_too_large': 'The content is too large',
      'error.unavailable': 'Could not complete this: {detail}',
      'error.invalid_params': 'Invalid request parameters ({detail})',
      'error.other': 'Something went wrong: {detail}',
    },
    ja: {
      copied: 'コピーしました',
      inserted: 'ターミナルに入力しました',
      needsAster: 'Aster で開くと使用できます',
      'error.permission_denied': 'このツールには必要な権限がありません（{detail}）',
      'error.rate_limited': '操作が多すぎます。しばらくしてからお試しください',
      'error.payload_too_large': '内容が大きすぎます',
      'error.unavailable': '完了できませんでした：{detail}',
      'error.invalid_params': 'リクエストのパラメータが無効です（{detail}）',
      'error.other': 'エラーが発生しました：{detail}',
    },
    fr: {
      copied: 'Copié',
      inserted: 'Inséré dans le terminal',
      needsAster: 'Ouvrez cet outil dans Aster pour utiliser cette fonction',
      'error.permission_denied': 'Cet outil n’a pas l’autorisation requise ({detail})',
      'error.rate_limited': 'Trop de requêtes. Réessayez dans un instant',
      'error.payload_too_large': 'Le contenu est trop volumineux',
      'error.unavailable': 'Action impossible pour le moment : {detail}',
      'error.invalid_params': 'Paramètres de requête non valides ({detail})',
      'error.other': 'Une erreur s’est produite : {detail}',
    },
    de: {
      copied: 'Kopiert',
      inserted: 'Ins Terminal eingefügt',
      needsAster: 'Öffne dieses Werkzeug in Aster, um dies zu verwenden',
      'error.permission_denied': 'Diesem Werkzeug fehlt die nötige Berechtigung ({detail})',
      'error.rate_limited': 'Zu viele Anfragen. Versuche es gleich noch einmal',
      'error.payload_too_large': 'Der Inhalt ist zu groß',
      'error.unavailable': 'Konnte nicht ausgeführt werden: {detail}',
      'error.invalid_params': 'Ungültige Anfrageparameter ({detail})',
      'error.other': 'Ein Fehler ist aufgetreten: {detail}',
    },
  };

  // window.aster 由 Aster 在文档开始时注入；直接用浏览器打开页面时不存在。
  const bridge = root.aster && typeof root.aster.onEnter === 'function' ? root.aster : null;
  let strings = COMMON_STRINGS;
  let locale = FALLBACK_LOCALE;
  const localeListeners = [];
  let statusTimer = 0;

  // 把 context.locale 归一成六种字典之一：繁体看 Hant 或台港澳地区，其余中文按简体，未知语言用英文。
  function normalizeLocale(raw) {
    if (typeof raw !== 'string' || !raw.trim()) return FALLBACK_LOCALE;
    const tag = raw.trim().replace(/_/g, '-');
    const exact = LOCALES.find((code) => code.toLowerCase() === tag.toLowerCase());
    if (exact) return exact;
    const parts = tag.toLowerCase().split('-');
    if (parts[0] === 'zh') {
      const traditional = parts.some((part) => part === 'hant' || part === 'tw' || part === 'hk' || part === 'mo');
      return traditional ? 'zh-Hant' : 'zh-Hans';
    }
    return LOCALES.includes(parts[0]) ? parts[0] : FALLBACK_LOCALE;
  }

  // 合并工具自己的六种语言字典。
  function defineStrings(toolStrings) {
    const merged = {};
    for (const code of LOCALES) {
      merged[code] = Object.assign({}, COMMON_STRINGS[code], (toolStrings && toolStrings[code]) || {});
    }
    strings = merged;
  }

  // 取当前语言的文案并替换 {name} 占位；缺失时依次退回英文、简体中文，最后返回键名，方便发现漏翻。
  function t(key, vars) {
    const table = strings[locale] || {};
    let text = table[key];
    if (text === undefined) text = (strings.en || {})[key];
    if (text === undefined) text = (strings['zh-Hans'] || {})[key];
    if (text === undefined) text = key;
    if (!vars) return text;
    return text.replace(/\{(\w+)\}/g, (whole, name) => (name in vars ? String(vars[name]) : whole));
  }

  // 按 data-i18n、data-i18n-placeholder、data-i18n-title、data-i18n-label 把当前语言的文案写进页面。
  function translatePage() {
    document.documentElement.lang = locale;
    const title = (strings[locale] || {}).title;
    if (title) document.title = title;
    document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
    document.querySelectorAll('[data-i18n-placeholder]').forEach((el) => { el.placeholder = t(el.dataset.i18nPlaceholder); });
    document.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
    document.querySelectorAll('[data-i18n-label]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nLabel)); });
    markBridgeOnly(document);
  }

  // 切换界面语言；语言真的变了才重写页面并通知工具重新渲染动态内容。
  function setLocale(raw) {
    const next = normalizeLocale(raw);
    if (next === locale && document.documentElement.lang === next) return;
    locale = next;
    translatePage();
    localeListeners.forEach((listener) => listener(locale));
  }

  // 外观以 Aster 送来的为准；shim 已经设置过属性，这里再设一次，兼容只发事件的宿主。
  function applyAppearance(appearance) {
    if (appearance !== 'light' && appearance !== 'dark') return;
    document.documentElement.dataset.asterAppearance = appearance;
    document.documentElement.style.colorScheme = appearance;
  }

  // 从 enter 事件或 tool.input 结果里取语言与外观。
  function applyContext(context, theme) {
    if (context && context.locale) setLocale(context.locale);
    applyAppearance((theme && theme.appearance) || (context && context.appearance));
  }

  // 撤掉启动时的隐藏，显示页面。
  function reveal() {
    document.documentElement.classList.remove('aster-booting');
  }

  // 没有 window.aster 时禁用依赖 App 的按钮（带 data-requires-bridge），并在提示里说明原因。
  function markBridgeOnly(scope) {
    document.documentElement.dataset.asterBridge = bridge ? 'on' : 'off';
    if (bridge) return;
    scope.querySelectorAll('[data-requires-bridge]').forEach((el) => {
      el.disabled = true;
      el.title = t('needsAster');
    });
  }

  // 设置按钮可用状态；依赖 App 的按钮在没有桥接时始终禁用。
  function setEnabled(el, enabled) {
    el.disabled = !enabled || (!bridge && el.hasAttribute('data-requires-bridge'));
  }

  // 在页面底部短暂显示一条提示；错误停留更久。
  function showStatus(message, kind) {
    const el = document.getElementById('status');
    if (!el) return;
    const tone = kind === 'error' ? ' error' : '';
    el.textContent = message;
    el.className = 'status visible' + tone;
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => { el.className = 'status' + tone; }, kind === 'error' ? 4000 : 1600);
  }

  // 把 AsterError 转成当前语言的提示；message 可能还带着 "<code>: " 前缀，去掉后作为细节。
  function errorMessage(error) {
    const code = error && typeof error.code === 'string' ? error.code : '';
    let detail = error && error.message ? String(error.message) : String(error);
    if (code && detail.startsWith(code + ': ')) detail = detail.slice(code.length + 2);
    const key = 'error.' + code;
    return t(code && key in (strings[locale] || {}) ? key : 'error.other', { detail });
  }

  // 调用一个 window.aster 方法：成功时提示 okKey，失败时把错误码转成友好提示；没有桥接时提示去 Aster 里打开。
  async function callBridge(invoke, okKey) {
    if (!bridge) {
      showStatus(t('needsAster'), 'error');
      return false;
    }
    try {
      await invoke(bridge);
      if (okKey) showStatus(t(okKey));
      return true;
    } catch (error) {
      showStatus(errorMessage(error), 'error');
      return false;
    }
  }

  // 写剪贴板（需要清单声明 clipboard.write）。
  function copyText(text) {
    return callBridge((aster) => aster.clipboard.writeText(text), 'copied');
  }

  // 把文字预填到来源终端，不回车（需要清单声明 terminal.insert）。
  function insertText(text) {
    return callBridge((aster) => aster.terminal.insert(text), 'inserted');
  }

  // 合并短时间内的多次调用，只执行最后一次。
  function debounce(fn, wait) {
    let timer = 0;
    return function (...args) {
      clearTimeout(timer);
      timer = setTimeout(() => fn.apply(this, args), wait);
    };
  }

  // 按当前语言格式化数字（千分位等）。
  function formatNumber(value, options) {
    return new Intl.NumberFormat(locale, options).format(value);
  }

  // 接上 Aster 事件：enter 预填输入，query 跟随启动器搜索框，theme 跟随外观。回调都可省略。
  function start(handlers) {
    const on = handlers || {};
    translatePage();
    if (!bridge) {
      reveal();
      return;
    }
    // 搜索框给过内容之后才把「清空」当成清空；否则空的 query 不该抹掉 enter 预填的内容。
    let queryOwnsInput = false;
    bridge.onEnter((event) => {
      const info = event || {};
      const input = info.input || {};
      applyContext(info.context || input.context, info.theme);
      reveal();
      queryOwnsInput = false;
      if (on.onInput) on.onInput(typeof input.text === 'string' ? input.text : '', info);
    });
    if (typeof bridge.onQuery === 'function') {
      bridge.onQuery((text) => {
        const value = typeof text === 'string' ? text : '';
        if (!value && !queryOwnsInput) return;
        queryOwnsInput = value !== '';
        if (on.onQuery) on.onQuery(value);
      });
    }
    if (typeof bridge.onThemeChange === 'function') {
      bridge.onThemeChange((theme) => applyAppearance(theme && theme.appearance));
    }
    // enter 事件可能在页面加载完之后才到；先用 tool.input 拿到界面语言，避免先闪一下英文。
    Promise.resolve()
      .then(() => bridge.getInput())
      .then((info) => {
        if (info) applyContext(info.context || (info.input && info.input.context));
        reveal();
      })
      .catch(reveal);
  }

  setTimeout(reveal, BOOT_TIMEOUT_MS);

  root.AsterKit = Object.freeze({
    bridge,
    get locale() { return locale; },
    normalizeLocale,
    defineStrings,
    t,
    translatePage,
    onLocaleChange(listener) { localeListeners.push(listener); },
    start,
    setEnabled,
    showStatus,
    errorMessage,
    callBridge,
    copyText,
    insertText,
    debounce,
    formatNumber,
  });
})(window);
