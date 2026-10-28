// 密码生成的纯逻辑：规则参数校验、无偏随机取字符、强度估算、规则 / 用途属性 / 历史的整理。不碰 DOM，便于在 Node 里测试。
(function (root) {
  'use strict';

  const MIN_LENGTH = 4;
  const MAX_LENGTH = 128;
  const HISTORY_LIMIT = 500;
  const NAME_LIMIT = 32;
  const TEXT_LIMIT = 256;
  const VALUE_LIMIT = 512;
  const UPPER = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  const LOWER = 'abcdefghijklmnopqrstuvwxyz';
  const DIGITS = '0123456789';
  const DEFAULT_SYMBOLS = '!@#$%^&*()-_=+[]{};:,.?/';
  // 易混字符：大写 I、小写 l、数字 1、竖线，大写 O、数字 0、小写 o，以及几种引号。
  const AMBIGUOUS = "Il1|O0o`'\"";
  const CLASS_IDS = ['upper', 'lower', 'digits', 'symbols'];

  // 默认规则不可删除；名字由界面按 id 本地化。
  const DEFAULT_RULES = Object.freeze([
    { id: 'strong', builtin: true, params: params({ length: 20 }) },
    { id: 'alnum', builtin: true, params: params({ length: 16, symbols: false }) },
    { id: 'pin', builtin: true, params: params({ length: 6, upper: false, lower: false, symbols: false }) },
    { id: 'readable', builtin: true, params: params({ length: 16, symbols: false, excludeAmbiguous: true }) },
  ]);

  // 默认用途属性不可删除；名字由界面按 id 本地化。
  const DEFAULT_ATTRIBUTES = Object.freeze([
    { id: 'site', builtin: true },
    { id: 'account', builtin: true },
    { id: 'category', builtin: true },
    { id: 'note', builtin: true },
  ]);

  // 参数非法时抛出的错误；code 供界面查文案，detail 是补充信息（如字符类名）。
  class PasswordError extends Error {
    constructor(code, detail) {
      super(code);
      this.name = 'PasswordError';
      this.code = code;
      this.detail = detail;
    }
  }

  // 用默认值（强密码）补齐一份规则参数。
  function params(overrides) {
    return Object.assign({
      length: 20,
      upper: true,
      lower: true,
      digits: true,
      symbols: true,
      symbolSet: DEFAULT_SYMBOLS,
      excludeAmbiguous: false,
      exclude: '',
      requireEach: true,
    }, overrides || {});
  }

  // 去掉控制字符并限制长度；非字符串返回空串。
  function cleanText(value, limit) {
    if (typeof value !== 'string') return '';
    return Array.from(value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, '')).slice(0, limit).join('');
  }

  // 把来自存储或输入的参数整理成合法形状：长度取整并收进 4–128，布尔与字符串字段兜底。
  function normalizeParams(raw) {
    const base = params();
    const input = raw && typeof raw === 'object' ? raw : {};
    const length = Math.round(Number(input.length));
    const flag = (key) => (typeof input[key] === 'boolean' ? input[key] : base[key]);
    return {
      length: Number.isFinite(length) ? Math.min(MAX_LENGTH, Math.max(MIN_LENGTH, length)) : base.length,
      upper: flag('upper'),
      lower: flag('lower'),
      digits: flag('digits'),
      symbols: flag('symbols'),
      symbolSet: typeof input.symbolSet === 'string' ? cleanText(input.symbolSet, TEXT_LIMIT) : base.symbolSet,
      excludeAmbiguous: flag('excludeAmbiguous'),
      exclude: cleanText(input.exclude, TEXT_LIMIT),
      requireEach: flag('requireEach'),
    };
  }

  // 两份参数是否等价（用于判断「改过但未保存」）。
  function sameParams(a, b) {
    const x = normalizeParams(a);
    const y = normalizeParams(b);
    return Object.keys(x).every((key) => x[key] === y[key]);
  }

  // 按码位去重（符号集可能含非 ASCII 字符）。
  function uniqueChars(text) {
    return Array.from(new Set(Array.from(text)));
  }

  // 计算各字符类与总字符池；校验失败抛 PasswordError，不生成任何东西。
  function buildPools(raw) {
    const p = raw || {};
    const length = Number(p.length);
    if (!Number.isInteger(length) || length < MIN_LENGTH || length > MAX_LENGTH) {
      throw new PasswordError('lengthRange');
    }
    const excluded = new Set(Array.from(String(p.exclude || '')));
    if (p.excludeAmbiguous) Array.from(AMBIGUOUS).forEach((ch) => excluded.add(ch));
    const sources = { upper: UPPER, lower: LOWER, digits: DIGITS, symbols: String(p.symbolSet || '') };
    const classes = [];
    for (const id of CLASS_IDS) {
      if (!p[id]) continue;
      const chars = uniqueChars(sources[id]).filter((ch) => !excluded.has(ch) && !/\s/.test(ch));
      classes.push({ id, chars });
    }
    if (!classes.length) throw new PasswordError('noClass');
    // 符号集里可能混入字母或数字，总字符池按去重后的并集算，避免某些字符权重翻倍。
    const pool = uniqueChars(classes.map((item) => item.chars.join('')).join(''));
    if (!pool.length) throw new PasswordError('emptyPool');
    if (p.requireEach) {
      const empty = classes.find((item) => !item.chars.length);
      if (empty) throw new PasswordError('emptyClass', empty.id);
      if (length < classes.length) throw new PasswordError('tooShort', classes.length);
    }
    return { length, classes, pool, requireEach: !!p.requireEach };
  }

  // 校验参数：合法返回 null，否则返回 PasswordError。
  function validate(raw) {
    try {
      buildPools(raw);
      return null;
    } catch (error) {
      if (error instanceof PasswordError) return error;
      throw error;
    }
  }

  // 默认随机源：Web Crypto 的 getRandomValues（浏览器与 Node 19+ 都有）。
  function cryptoFill(array) {
    return root.crypto.getRandomValues(array);
  }

  // 取 [0, n) 的均匀随机整数。拒绝采样：只接受落在 n 的整数倍以内的 32 位值，避免直接取模带来的偏差。
  function randomBelow(n, fill) {
    if (!Number.isInteger(n) || n < 1 || n > 0x100000000) throw new RangeError('randomBelow: n out of range');
    const limit = Math.floor(0x100000000 / n) * n;
    const buffer = new Uint32Array(1);
    const source = fill || cryptoFill;
    for (;;) {
      source(buffer);
      if (buffer[0] < limit) return buffer[0] % n;
    }
  }

  // 无偏的 Fisher–Yates 洗牌（原地），从后往前与 [0, i] 中的随机位置交换。
  function shuffle(items, fill) {
    for (let i = items.length - 1; i > 0; i -= 1) {
      const j = randomBelow(i + 1, fill);
      const tmp = items[i];
      items[i] = items[j];
      items[j] = tmp;
    }
    return items;
  }

  // 按规则生成一个密码；要求每类至少一个时先从每类各取一个，其余从总池取，最后整体洗牌。
  function generate(raw, fill) {
    const { length, classes, pool, requireEach } = buildPools(raw);
    const chars = [];
    if (requireEach) classes.forEach((item) => chars.push(item.chars[randomBelow(item.chars.length, fill)]));
    while (chars.length < length) chars.push(pool[randomBelow(pool.length, fill)]);
    return shuffle(chars, fill).join('');
  }

  // 估算熵（bits）= 长度 × log2(字符池大小)；参数非法返回 0。
  function entropyBits(raw) {
    try {
      const { length, pool } = buildPools(raw);
      return pool.length > 1 ? length * Math.log2(pool.length) : 0;
    } catch (error) {
      if (error instanceof PasswordError) return 0;
      throw error;
    }
  }

  // 熵对应的强度等级：< 45 弱，< 70 中，< 100 强，其余很强。
  function strength(bits) {
    if (bits < 45) return 'weak';
    if (bits < 70) return 'fair';
    if (bits < 100) return 'strong';
    return 'veryStrong';
  }

  // 生成一个随机 id（16 位十六进制），用于规则、属性与历史条目。
  function makeId(fill) {
    const buffer = new Uint32Array(2);
    (fill || cryptoFill)(buffer);
    return Array.from(buffer, (n) => n.toString(16).padStart(8, '0')).join('');
  }

  // 校验并整理一个名字（规则名或属性名）：去首尾空白、非空、不超过 32 字符、不与已有名字重名（不区分大小写）。
  function checkName(name, existingNames) {
    const text = cleanText(String(name || ''), NAME_LIMIT + 1).trim();
    if (!text) throw new PasswordError('nameEmpty');
    if (Array.from(text).length > NAME_LIMIT) throw new PasswordError('nameTooLong', NAME_LIMIT);
    const lower = text.toLocaleLowerCase();
    if ((existingNames || []).some((other) => String(other).toLocaleLowerCase() === lower)) {
      throw new PasswordError('nameTaken');
    }
    return text;
  }

  // 整理存储里的用户规则：丢弃形状不对的条目，参数重新规范化。
  function sanitizeRules(raw) {
    if (!Array.isArray(raw)) return [];
    const seen = new Set();
    const rules = [];
    for (const item of raw) {
      if (!item || typeof item.id !== 'string' || typeof item.name !== 'string' || seen.has(item.id)) continue;
      const name = cleanText(item.name, NAME_LIMIT).trim();
      if (!name) continue;
      seen.add(item.id);
      rules.push({ id: item.id, name, params: normalizeParams(item.params) });
    }
    return rules;
  }

  // 整理存储里的用户属性定义：只保留 {id, name}。
  function sanitizeAttributes(raw) {
    if (!Array.isArray(raw)) return [];
    const seen = new Set(DEFAULT_ATTRIBUTES.map((item) => item.id));
    const result = [];
    for (const item of raw) {
      if (!item || typeof item.id !== 'string' || typeof item.name !== 'string' || seen.has(item.id)) continue;
      const name = cleanText(item.name, NAME_LIMIT).trim();
      if (!name) continue;
      seen.add(item.id);
      result.push({ id: item.id, name });
    }
    return result;
  }

  // 只保留非空的属性值（去首尾空白、限长），返回 {id: 值}。
  function compactAttributes(values) {
    const result = {};
    for (const [id, value] of Object.entries(values || {})) {
      const text = cleanText(typeof value === 'string' ? value : '', VALUE_LIMIT).trim();
      if (text) result[id] = text;
    }
    return result;
  }

  // 整理加密存储里的历史：丢弃形状不对的条目，补齐字段，最多 500 条。
  function sanitizeHistory(raw) {
    if (!Array.isArray(raw)) return [];
    const result = [];
    for (const item of raw) {
      if (!item || typeof item.password !== 'string' || !item.password) continue;
      const rule = item.rule && typeof item.rule === 'object' ? item.rule : {};
      const names = item.attributeNames && typeof item.attributeNames === 'object' ? item.attributeNames : {};
      result.push({
        id: typeof item.id === 'string' ? item.id : makeId(),
        password: item.password,
        createdAt: typeof item.createdAt === 'string' ? item.createdAt : new Date(0).toISOString(),
        rule: {
          id: typeof rule.id === 'string' ? rule.id : '',
          name: typeof rule.name === 'string' ? rule.name : '',
          params: normalizeParams(rule.params),
        },
        attributes: compactAttributes(item.attributes),
        attributeNames: Object.fromEntries(Object.entries(names).filter(([, value]) => typeof value === 'string')),
      });
      if (result.length >= HISTORY_LIMIT) break;
    }
    return result;
  }

  // 两组属性值整理后是否完全相同（只比非空的值，不看名字）。
  function sameAttributes(a, b) {
    const left = compactAttributes(a);
    const right = compactAttributes(b);
    const keys = Object.keys(left);
    return keys.length === Object.keys(right).length && keys.every((id) => left[id] === right[id]);
  }

  // 记录一次复制：新条目放最前；同一个密码已存在时合并属性（新值覆盖、空值不清掉旧值）并更新时间，移到最前。
  // replaceId 是生成页上一次记录的条目：它还在、且用途属性和这次完全相同时，直接换成新密码，不新增条目，
  // 这样同一用途反复重新生成、复制只留一条。返回新数组，不改动传入的历史；超过 500 条时丢掉最旧的。
  function recordCopy(history, entry, now, replaceId) {
    const time = (now || new Date()).toISOString();
    const list = Array.isArray(history) ? history.slice() : [];
    const attributes = compactAttributes(entry.attributes);
    let index = replaceId ? list.findIndex((item) => item.id === replaceId && sameAttributes(item.attributes, attributes)) : -1;
    if (index < 0) index = list.findIndex((item) => item.password === entry.password);
    const names = {};
    for (const id of Object.keys(attributes)) names[id] = (entry.attributeNames || {})[id] || id;
    let next;
    if (index >= 0) {
      const old = list.splice(index, 1)[0];
      next = Object.assign({}, old, {
        password: entry.password,
        createdAt: time,
        rule: entry.rule || old.rule,
        attributes: Object.assign({}, old.attributes, attributes),
        attributeNames: Object.assign({}, old.attributeNames, names),
      });
    } else {
      next = { id: entry.id || makeId(), password: entry.password, createdAt: time, rule: entry.rule, attributes, attributeNames: names };
    }
    list.unshift(next);
    return list.slice(0, HISTORY_LIMIT);
  }

  // 修改一条历史的密码与用途属性：属性按传入的整份替换（清空即删除），时间、规则与位置不变。
  // 密码去掉控制字符后不能为空（PasswordError passwordEmpty）；找不到条目时抛 entryMissing。返回新数组。
  function editEntry(history, id, changes) {
    const password = cleanText(changes.password, VALUE_LIMIT);
    if (!password.trim()) throw new PasswordError('passwordEmpty');
    const list = Array.isArray(history) ? history.slice() : [];
    const index = list.findIndex((item) => item.id === id);
    if (index < 0) throw new PasswordError('entryMissing');
    const attributes = compactAttributes(changes.attributes);
    const names = {};
    for (const key of Object.keys(attributes)) {
      names[key] = (changes.attributeNames || {})[key] || (list[index].attributeNames || {})[key] || key;
    }
    list[index] = Object.assign({}, list[index], { password, attributes, attributeNames: names });
    return list;
  }

  // 按搜索词过滤历史：空白分隔的每个词都要出现在属性值或规则名里（不区分大小写，不搜密码本身）。
  // ruleName(entry) 返回条目当前应显示的规则名。
  function filterHistory(history, query, ruleName) {
    const terms = String(query || '').toLocaleLowerCase().split(/\s+/).filter(Boolean);
    if (!terms.length) return history.slice();
    return history.filter((entry) => {
      const haystack = Object.values(entry.attributes || {})
        .concat([entry.rule && entry.rule.name, ruleName ? ruleName(entry) : ''])
        .join('\n')
        .toLocaleLowerCase();
      return terms.every((term) => haystack.includes(term));
    });
  }

  // 启动器输入是否是合法长度：4–128 的整数，返回数字，否则返回 null。
  function parseLength(text) {
    const trimmed = String(text || '').trim();
    if (!/^\d{1,3}$/.test(trimmed)) return null;
    const value = Number(trimmed);
    return value >= MIN_LENGTH && value <= MAX_LENGTH ? value : null;
  }

  const api = {
    MIN_LENGTH,
    MAX_LENGTH,
    HISTORY_LIMIT,
    NAME_LIMIT,
    VALUE_LIMIT,
    DEFAULT_SYMBOLS,
    AMBIGUOUS,
    CLASS_IDS,
    DEFAULT_RULES,
    DEFAULT_ATTRIBUTES,
    PasswordError,
    params,
    normalizeParams,
    sameParams,
    buildPools,
    validate,
    randomBelow,
    shuffle,
    generate,
    entropyBits,
    strength,
    makeId,
    checkName,
    sanitizeRules,
    sanitizeAttributes,
    compactAttributes,
    sameAttributes,
    sanitizeHistory,
    recordCopy,
    editEntry,
    filterHistory,
    parseLength,
  };
  root.PasswordCore = api;
  if (typeof module === 'object' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
