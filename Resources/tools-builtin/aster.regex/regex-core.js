// 正则匹配的纯函数，Worker 与主线程退路共用：编译、逐个取出匹配与分组位置、处理零宽匹配，数量有上限。
(function (root) {
  'use strict';

  // 界面上可切换的标志；d（分组位置）由这里自动加上。
  const USER_FLAGS = 'gimsuy';
  // 单个匹配或分组回传给页面的最长文字；位置信息完整保留，只截断展示用的文字，避免消息过大。
  const TEXT_PREVIEW = 400;

  // 去掉不认识和重复的标志，按固定顺序排列。
  function normalizeFlags(flags) {
    const wanted = String(flags || '');
    return USER_FLAGS.split('').filter((flag) => wanted.includes(flag)).join('');
  }

  // 按出现顺序列出捕获分组的名字（无名为 null），把 exec 结果里的编号分组和命名分组对上。
  // 需要跳过转义字符和字符类 [...]，并区分 (?: (?= (?! (?<= (?<! 这些不捕获的括号。
  function captureNames(pattern) {
    const names = [];
    let inClass = false;
    for (let i = 0; i < pattern.length; i += 1) {
      const ch = pattern[i];
      if (ch === '\\') {
        i += 1;
      } else if (inClass) {
        if (ch === ']') inClass = false;
      } else if (ch === '[') {
        inClass = true;
      } else if (ch === '(') {
        if (pattern[i + 1] !== '?') {
          names.push(null);
        } else {
          const named = /^\(\?<([A-Za-z_$][\w$]*)>/.exec(pattern.slice(i, i + 80));
          if (named) names.push(named[1]);
        }
      }
    }
    return names;
  }

  // 编译用户的正则；额外加 d 标志拿到分组位置，引擎不支持 d 时退回不带 d（语法错误照常抛出）。
  function compile(pattern, flags) {
    const clean = normalizeFlags(flags);
    try {
      return new RegExp(pattern, clean + 'd');
    } catch (error) {
      return new RegExp(pattern, clean);
    }
  }

  // 零宽匹配后 exec 会停在原地，需要手动前进：u 模式下跳过整个代理对，否则前进一个 UTF-16 单元。
  function advanceIndex(text, index, unicode) {
    if (unicode && index + 1 < text.length) {
      const high = text.charCodeAt(index);
      const low = text.charCodeAt(index + 1);
      if (high >= 0xd800 && high <= 0xdbff && low >= 0xdc00 && low <= 0xdfff) return index + 2;
    }
    return index + 1;
  }

  // 截断展示用文字。
  function preview(text) {
    return text.length > TEXT_PREVIEW ? text.slice(0, TEXT_PREVIEW) : text;
  }

  // 把一次 exec 的结果整理成可以 postMessage 的普通对象。
  function describe(match, names) {
    const groups = [];
    for (let i = 1; i < match.length; i += 1) {
      const span = match.indices ? match.indices[i] : null;
      groups.push({
        n: i,
        name: names[i - 1] || null,
        text: match[i] === undefined ? null : preview(match[i]),
        start: span ? span[0] : -1,
        end: span ? span[1] : -1,
      });
    }
    return { start: match.index, end: match.index + match[0].length, text: preview(match[0]), groups };
  }

  // 运行一次匹配。没有 g / y 时只取第一处（与 String.prototype.match 一致）；超过 limit 处就停下并标记 truncated。
  function run(pattern, flags, text, limit) {
    const started = Date.now();
    const re = compile(pattern, flags);
    const names = captureNames(pattern);
    const max = limit > 0 ? limit : 1000;
    const matches = [];
    let truncated = false;
    if (!re.global && !re.sticky) {
      const match = re.exec(text);
      if (match) matches.push(describe(match, names));
    } else {
      re.lastIndex = 0;
      let match = re.exec(text);
      while (match) {
        if (matches.length >= max) {
          truncated = true;
          break;
        }
        matches.push(describe(match, names));
        if (match[0].length === 0) re.lastIndex = advanceIndex(text, re.lastIndex, re.unicode);
        match = re.exec(text);
      }
    }
    return { matches, truncated, flags: normalizeFlags(flags), elapsed: Date.now() - started };
  }

  // pattern[i] 起是否为能重复多次的量词：+、*、{n,}、{n,m}，以及次数大于 1 的 {n}；? 和 {1} 不算。
  function isRepeat(pattern, i) {
    const ch = pattern[i];
    if (ch === '+' || ch === '*') return true;
    if (ch !== '{') return false;
    const match = /^\{(\d+)(,(\d*))?\}/.exec(pattern.slice(i, i + 24));
    if (!match) return false;
    if (match[2] === undefined) return Number(match[1]) > 1;
    return match[3] === '' || Number(match[3]) > 1;
  }

  // 粗略判断「量词套量词」：带重复量词的分组里面还有重复量词，例如 (a+)+、(\w*)*、(?:x+y){2,}。
  // 这是灾难性回溯最常见的形状。只在 Worker 不可用、只能在主线程匹配时用来拦截，宁可误拦，不求完备。
  function hasNestedQuantifier(pattern) {
    // 每层分组一个标记：这层里面是否出现过重复量词。
    const stack = [];
    let inClass = false;
    for (let i = 0; i < pattern.length; i += 1) {
      const ch = pattern[i];
      if (ch === '\\') {
        i += 1;
      } else if (inClass) {
        inClass = ch !== ']';
      } else if (ch === '[') {
        inClass = true;
      } else if (ch === '(') {
        stack.push(false);
      } else if (ch === ')') {
        const inner = stack.pop() === true;
        const repeated = isRepeat(pattern, i + 1);
        if (inner && repeated) return true;
        if (stack.length && (inner || repeated)) stack[stack.length - 1] = true;
      } else if (stack.length && isRepeat(pattern, i)) {
        stack[stack.length - 1] = true;
      }
    }
    return false;
  }

  // 正则字面量的正文里，字符类之外的 / 必须转义；有未转义的 / 说明它不是字面量（例如 /usr/local/ 这样的路径）。
  function hasBareSlash(body) {
    let inClass = false;
    for (let i = 0; i < body.length; i += 1) {
      const ch = body[i];
      if (ch === '\\') i += 1;
      else if (inClass) inClass = ch !== ']';
      else if (ch === '[') inClass = true;
      else if (ch === '/') return true;
    }
    return false;
  }

  // 把 /pattern/flags 形式拆开；不是这种形式、标志不认识或正文里有未转义的 / 时返回 null。
  function splitLiteral(value) {
    const match = /^\/([\s\S]+)\/([a-z]*)$/.exec(String(value || '').trim());
    if (!match || /[^gimsuyd]/.test(match[2]) || hasBareSlash(match[1])) return null;
    return { pattern: match[1], flags: normalizeFlags(match[2]) };
  }

  const api = { USER_FLAGS, normalizeFlags, captureNames, compile, run, hasNestedQuantifier, splitLiteral };
  root.RegexCore = api;
  if (typeof module === 'object' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
