// 密码生成工具的持久化：规则、属性定义与上次选择存 aster.storage（非机密）；历史存 aster.secureStorage（加密落盘）。
// 所有读写排进同一条队列，连续复制、删除时不会互相覆盖。没有 window.aster 时设置只放在内存里，历史不可用。
(function () {
  'use strict';

  const Core = window.PasswordCore;
  const bridge = window.AsterKit.bridge;
  const KEYS = { rules: 'rules', attributes: 'attributes', selection: 'selection', history: 'history' };

  // 浏览器直接打开时的内存替身，接口与 aster.storage 一致。
  const memory = new Map();
  const memoryStorage = {
    get: async (key) => (memory.has(key) ? memory.get(key) : null),
    set: async (key, value) => { memory.set(key, value); return null; },
    remove: async (key) => { memory.delete(key); return null; },
    keys: async () => Array.from(memory.keys()),
  };
  const plain = bridge && bridge.storage ? bridge.storage : memoryStorage;
  // 旧版 Aster 没有 secureStorage：历史功能整体停用，绝不退回明文存储。
  const secure = bridge && bridge.secureStorage && typeof bridge.secureStorage.get === 'function' ? bridge.secureStorage : null;

  let history = [];
  let historyLoaded = false;
  let chain = Promise.resolve();

  // 历史不可用时抛出的错误；界面据此显示专门的提示。
  class SecureUnavailableError extends Error {
    constructor() {
      super('secure storage unavailable');
      this.code = 'secure_unavailable';
    }
  }

  // 把一个异步任务排进队列；前一个失败不影响后一个执行。
  function queue(task) {
    const run = chain.then(task);
    chain = run.catch(() => {});
    return run;
  }

  // 读取规则、属性定义与上次选择；某一项读失败时用默认值，并把第一个错误交给 onError。
  async function loadSettings(onError) {
    const read = (key) => queue(() => plain.get(key)).catch((error) => {
      if (onError) onError(error);
      return null;
    });
    const [rules, attributes, selection] = await Promise.all([read(KEYS.rules), read(KEYS.attributes), read(KEYS.selection)]);
    return {
      rules: Core.sanitizeRules(rules),
      attributes: Core.sanitizeAttributes(attributes),
      selection: selection && typeof selection === 'object' ? {
        ruleId: typeof selection.ruleId === 'string' ? selection.ruleId : 'strong',
        params: Core.normalizeParams(selection.params),
      } : null,
    };
  }

  // 保存用户规则列表（只存 id、名字与参数）。
  function saveRules(rules) {
    const value = rules.map((rule) => ({ id: rule.id, name: rule.name, params: Core.normalizeParams(rule.params) }));
    return queue(() => plain.set(KEYS.rules, value));
  }

  // 保存用户属性定义（只存 id 与名字）。
  function saveAttributes(attributes) {
    const value = attributes.map((item) => ({ id: item.id, name: item.name }));
    return queue(() => plain.set(KEYS.attributes, value));
  }

  // 保存当前选中的规则与参数（含未保存的修改），下次打开时恢复。
  function saveSelection(ruleId, params) {
    return queue(() => plain.set(KEYS.selection, { ruleId, params: Core.normalizeParams(params) }));
  }

  // 从加密存储读取历史（只读一次，之后用缓存）；不可用时抛 SecureUnavailableError。
  function loadHistory() {
    return queue(async () => {
      if (!secure) throw new SecureUnavailableError();
      if (!historyLoaded) {
        history = Core.sanitizeHistory(await secure.get(KEYS.history));
        historyLoaded = true;
      }
      return history;
    });
  }

  // 修改历史：mutator 收到当前历史的副本、返回新历史；写入成功后才更新缓存，写失败时原内容不变。
  // 还没读过历史时先读，避免用空列表覆盖已有记录。
  function updateHistory(mutator) {
    return queue(async () => {
      if (!secure) throw new SecureUnavailableError();
      if (!historyLoaded) {
        history = Core.sanitizeHistory(await secure.get(KEYS.history));
        historyLoaded = true;
      }
      const next = mutator(history.slice());
      if (next.length) await secure.set(KEYS.history, next);
      else await secure.remove(KEYS.history);
      history = next;
      return history;
    });
  }

  window.PasswordStore = Object.freeze({
    get history() { return history; },
    get historyLoaded() { return historyLoaded; },
    secureAvailable: !!secure,
    SecureUnavailableError,
    loadSettings,
    saveRules,
    saveAttributes,
    saveSelection,
    loadHistory,
    updateHistory,
  });
})();
