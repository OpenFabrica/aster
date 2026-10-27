// 行级文本对比的纯函数：Myers O(ND) 差分（「中间蛇」二分，线性空间）、行内改动范围与统一 diff 文本。
(function (root) {
  'use strict';

  // 文本拆成行：统一换行符；结尾的换行不算多出来的一行。
  function splitLines(text) {
    const normalized = String(text || '').replace(/\r\n?/g, '\n');
    if (!normalized) return [];
    const lines = normalized.split('\n');
    if (lines[lines.length - 1] === '') lines.pop();
    return lines;
  }

  // 两侧的行映射成整数编号，比较时只比数字；忽略空白 / 大小写只影响比较用的键，显示仍用原文。
  function encodeLines(linesA, linesB, options) {
    const ids = new Map();
    const encode = (lines) => {
      const out = new Int32Array(lines.length);
      for (let i = 0; i < lines.length; i += 1) {
        let key = lines[i];
        if (options.ignoreWhitespace) key = key.trim().replace(/\s+/g, ' ');
        if (options.ignoreCase) key = key.toLowerCase();
        let id = ids.get(key);
        if (id === undefined) {
          id = ids.size;
          ids.set(key, id);
        }
        out[i] = id;
      }
      return out;
    };
    return { a: encode(linesA), b: encode(linesB) };
  }

  // 两段之间一行相同的都没有时，Myers 搜索会走满 O((N+M)²)；先用集合判断，直接按整段替换处理。
  function sharesAnyLine(a, aLo, aHi, b, bLo, bHi) {
    const seen = new Set();
    for (let i = aLo; i < aHi; i += 1) seen.add(a[i]);
    for (let j = bLo; j < bHi; j += 1) {
      if (seen.has(b[j])) return true;
    }
    return false;
  }

  // 在 a[aLo, aHi) 与 b[bLo, bHi) 之间找「中间蛇」：同时从左上角正向、从右下角反向做 Myers 搜索，
  // 两条路径第一次重叠的位置一定落在某条最短编辑路径上，从那里切成两半递归，内存只要 O(N+M)。
  // 做法与 Google diff-match-patch 的 diff_bisect 一致。返回切分点 {x, y}（整个数组的下标），找不到返回 null。
  function bisect(a, aLo, aHi, b, bLo, bHi) {
    const n = aHi - aLo;
    const m = bHi - bLo;
    const maxD = Math.ceil((n + m) / 2);
    const offset = maxD;
    // k 的范围是 [-maxD, maxD]，下标 offset + k 落在 [0, 2·maxD]；多留一格，避免越界读成 undefined。
    const size = 2 * maxD + 2;
    const v1 = new Int32Array(size).fill(-1);
    const v2 = new Int32Array(size).fill(-1);
    v1[offset + 1] = 0;
    v2[offset + 1] = 0;
    const delta = n - m;
    // delta 为奇数时，正向路径会先碰到反向路径，只在正向一侧检查重叠；偶数时在反向一侧检查。
    const front = delta % 2 !== 0;
    // 路径越出右边界或下边界后，对应的对角线不用再搜，用这四个量收窄 k 的范围。
    let k1start = 0;
    let k1end = 0;
    let k2start = 0;
    let k2end = 0;
    for (let d = 0; d < maxD; d += 1) {
      for (let k1 = -d + k1start; k1 <= d - k1end; k1 += 2) {
        const k1Offset = offset + k1;
        let x1 = k1 === -d || (k1 !== d && v1[k1Offset - 1] < v1[k1Offset + 1]) ? v1[k1Offset + 1] : v1[k1Offset - 1] + 1;
        let y1 = x1 - k1;
        while (x1 < n && y1 < m && a[aLo + x1] === b[bLo + y1]) {
          x1 += 1;
          y1 += 1;
        }
        v1[k1Offset] = x1;
        if (x1 > n) {
          k1end += 2;
        } else if (y1 > m) {
          k1start += 2;
        } else if (front) {
          const k2Offset = offset + delta - k1;
          if (k2Offset >= 0 && k2Offset < size && v2[k2Offset] !== -1 && x1 >= n - v2[k2Offset]) {
            return { x: aLo + x1, y: bLo + y1 };
          }
        }
      }
      for (let k2 = -d + k2start; k2 <= d - k2end; k2 += 2) {
        const k2Offset = offset + k2;
        let x2 = k2 === -d || (k2 !== d && v2[k2Offset - 1] < v2[k2Offset + 1]) ? v2[k2Offset + 1] : v2[k2Offset - 1] + 1;
        let y2 = x2 - k2;
        while (x2 < n && y2 < m && a[aHi - 1 - x2] === b[bHi - 1 - y2]) {
          x2 += 1;
          y2 += 1;
        }
        v2[k2Offset] = x2;
        if (x2 > n) {
          k2end += 2;
        } else if (y2 > m) {
          k2start += 2;
        } else if (!front) {
          const k1Offset = offset + delta - k2;
          if (k1Offset >= 0 && k1Offset < size && v1[k1Offset] !== -1) {
            const x1 = v1[k1Offset];
            const y1 = offset + x1 - k1Offset;
            if (x1 >= n - x2) return { x: aLo + x1, y: bLo + y1 };
          }
        }
      }
    }
    return null;
  }

  // 递归比较 a[aLo, aHi) 与 b[bLo, bHi)，把编辑操作按顺序追加到 ops。
  function compareRange(a, aLo, aHi, b, bLo, bHi, ops) {
    // 先剥掉公共前缀与后缀：真实文本的改动通常集中在几处，这一步把大部分行挡在 O(ND) 搜索之外。
    let lo1 = aLo;
    let lo2 = bLo;
    while (lo1 < aHi && lo2 < bHi && a[lo1] === b[lo2]) {
      ops.push({ op: 'equal', a: lo1, b: lo2 });
      lo1 += 1;
      lo2 += 1;
    }
    let suffix = 0;
    while (aHi - suffix > lo1 && bHi - suffix > lo2 && a[aHi - 1 - suffix] === b[bHi - 1 - suffix]) suffix += 1;
    const hi1 = aHi - suffix;
    const hi2 = bHi - suffix;
    if (lo1 === hi1) {
      for (let j = lo2; j < hi2; j += 1) ops.push({ op: 'insert', b: j });
    } else if (lo2 === hi2) {
      for (let i = lo1; i < hi1; i += 1) ops.push({ op: 'delete', a: i });
    } else {
      const split = sharesAnyLine(a, lo1, hi1, b, lo2, hi2) ? bisect(a, lo1, hi1, b, lo2, hi2) : null;
      if (split) {
        compareRange(a, lo1, split.x, b, lo2, split.y, ops);
        compareRange(a, split.x, hi1, b, split.y, hi2, ops);
      } else {
        for (let i = lo1; i < hi1; i += 1) ops.push({ op: 'delete', a: i });
        for (let j = lo2; j < hi2; j += 1) ops.push({ op: 'insert', b: j });
      }
    }
    for (let i = 0; i < suffix; i += 1) ops.push({ op: 'equal', a: hi1 + i, b: hi2 + i });
  }

  // 每段连续改动里把删除行排在新增行前面，和常见 diff 的显示习惯一致；只调顺序，不改变结果。
  function groupChanges(ops) {
    const out = [];
    let i = 0;
    while (i < ops.length) {
      if (ops[i].op === 'equal') {
        out.push(ops[i]);
        i += 1;
        continue;
      }
      let j = i;
      while (j < ops.length && ops[j].op !== 'equal') j += 1;
      for (let k = i; k < j; k += 1) if (ops[k].op === 'delete') out.push(ops[k]);
      for (let k = i; k < j; k += 1) if (ops[k].op === 'insert') out.push(ops[k]);
      i = j;
    }
    return out;
  }

  // 对比两段文本。返回 {linesA, linesB, ops, added, removed, unchanged, truncated}；
  // ops 里 equal 带 a、b，delete 只带 a，insert 只带 b（都是从 0 开始的行下标）。超过 maxLines 的行不参与对比。
  function diffTexts(textA, textB, options) {
    const opts = options || {};
    const maxLines = opts.maxLines > 0 ? opts.maxLines : Infinity;
    let linesA = splitLines(textA);
    let linesB = splitLines(textB);
    const truncated = linesA.length > maxLines || linesB.length > maxLines;
    if (truncated) {
      linesA = linesA.slice(0, maxLines);
      linesB = linesB.slice(0, maxLines);
    }
    const { a, b } = encodeLines(linesA, linesB, opts);
    const raw = [];
    compareRange(a, 0, a.length, b, 0, b.length, raw);
    const ops = groupChanges(raw);
    let added = 0;
    let removed = 0;
    for (const op of ops) {
      if (op.op === 'insert') added += 1;
      else if (op.op === 'delete') removed += 1;
    }
    return { linesA, linesB, ops, added, removed, unchanged: ops.length - added - removed, truncated };
  }

  // 是否为 UTF-16 低位代理（代理对的后半个）。
  function isLowSurrogate(code) {
    return code >= 0xdc00 && code <= 0xdfff;
  }

  // 一对被修改的行去掉公共前缀和后缀，中间剩下的就是改动部分；O(n) 且对常见的局部修改足够准确。
  // 返回 {start, endOld, endNew}：旧行改动范围 [start, endOld)，新行 [start, endNew)；不会把代理对切开。
  function changedSpan(oldLine, newLine) {
    const max = Math.min(oldLine.length, newLine.length);
    let start = 0;
    while (start < max && oldLine.charCodeAt(start) === newLine.charCodeAt(start)) start += 1;
    if (start > 0 && start < oldLine.length && isLowSurrogate(oldLine.charCodeAt(start))) start -= 1;
    let endOld = oldLine.length;
    let endNew = newLine.length;
    while (endOld > start && endNew > start && oldLine.charCodeAt(endOld - 1) === newLine.charCodeAt(endNew - 1)) {
      endOld -= 1;
      endNew -= 1;
    }
    if (endOld < oldLine.length && isLowSurrogate(oldLine.charCodeAt(endOld))) {
      endOld += 1;
      endNew += 1;
    }
    return { start, endOld, endNew };
  }

  // 生成统一 diff 文本：--- / +++ 文件头，「@@ -旧起始,行数 +新起始,行数 @@」块头，默认 3 行上下文。
  // 行数为 0 时起始行号写成前一行（GNU diff 的约定），行数为 1 时省略「,1」。
  function unifiedDiff(result, oldName, newName, context) {
    const ctx = context === undefined ? 3 : context;
    const { ops, linesA, linesB } = result;
    // posA[i] / posB[i]：第 i 个操作之前已经走过的旧行数与新行数，用来算块头里的行号。
    const posA = new Int32Array(ops.length + 1);
    const posB = new Int32Array(ops.length + 1);
    for (let i = 0; i < ops.length; i += 1) {
      posA[i + 1] = posA[i] + (ops[i].op === 'insert' ? 0 : 1);
      posB[i + 1] = posB[i] + (ops[i].op === 'delete' ? 0 : 1);
    }
    const range = (start, count) => (count === 1 ? String(start) : start + ',' + count);
    const out = ['--- ' + oldName, '+++ ' + newName];
    let i = 0;
    while (i < ops.length) {
      while (i < ops.length && ops[i].op === 'equal') i += 1;
      if (i >= ops.length) break;
      const start = Math.max(0, i - ctx);
      // 向后合并：两处改动之间的相同行不超过 2×上下文时并进同一块，否则在这里结束本块。
      let lastChange = i;
      let j = i;
      while (j < ops.length) {
        if (ops[j].op !== 'equal') {
          lastChange = j;
          j += 1;
          continue;
        }
        let k = j;
        while (k < ops.length && ops[k].op === 'equal') k += 1;
        if (k >= ops.length || k - j > 2 * ctx) break;
        j = k;
      }
      const end = Math.min(ops.length, lastChange + 1 + ctx);
      const oldCount = posA[end] - posA[start];
      const newCount = posB[end] - posB[start];
      out.push('@@ -' + range(oldCount ? posA[start] + 1 : posA[start], oldCount)
        + ' +' + range(newCount ? posB[start] + 1 : posB[start], newCount) + ' @@');
      for (let p = start; p < end; p += 1) {
        const op = ops[p];
        if (op.op === 'equal') out.push(' ' + linesA[op.a]);
        else if (op.op === 'delete') out.push('-' + linesA[op.a]);
        else out.push('+' + linesB[op.b]);
      }
      i = end;
    }
    return out.join('\n') + '\n';
  }

  const api = { splitLines, diffTexts, changedSpan, unifiedDiff };
  root.DiffCore = api;
  if (typeof module === 'object' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
