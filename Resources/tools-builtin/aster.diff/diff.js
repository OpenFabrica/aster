// 文本对比工具的界面逻辑：左右两栏逐行对比，显示增删行、行内改动与统计，折叠相同的行，可复制统一 diff。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.DiffCore;
  const MAX_LINES = 5000;
  const MAX_ROWS = 3000;
  const CONTEXT = 3;
  // 折叠至少要藏起这么多行，否则「展开」按钮比藏起来的行还占地方。
  const MIN_FOLD = 4;
  // 两栏合计超过这个字符数时输入去抖，短文本每次按键都直接重算。
  const DEBOUNCE_THRESHOLD = 20000;
  const SAMPLE_LEFT = '[server]\nhost = "127.0.0.1"\nport = 8080\ntimeout = 30\n\n[log]\nlevel = "info"\nfile = "/var/log/app.log"\n';
  const SAMPLE_RIGHT = '[server]\nhost = "0.0.0.0"\nport = 8080\ntimeout = 60\nkeepalive = true\n\n[log]\nlevel = "debug"\nfile = "/var/log/app.log"\n';

  const byId = (id) => document.getElementById(id);
  const ui = {
    left: byId('left'),
    right: byId('right'),
    leftStats: byId('left-stats'),
    rightStats: byId('right-stats'),
    ignoreWhitespace: byId('ignore-whitespace'),
    ignoreCase: byId('ignore-case'),
    onlyChanges: byId('only-changes'),
    swap: byId('swap'),
    copy: byId('copy-diff'),
    note: byId('note'),
    stats: byId('stats'),
    elapsed: byId('elapsed'),
    result: byId('result'),
    empty: byId('empty'),
    emptyHint: byId('empty-hint'),
    sample: byId('sample'),
  };
  // 最近一次对比结果（DiffCore.diffTexts 的返回值，外加 partner 与 elapsed）；有一栏为空时为 null。
  let current = null;
  // 用户点开过的折叠段，用段起点的操作下标标识；每次重新对比后清空。
  let expanded = new Set();

  // 创建元素并设置类名与文字。
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // 统计一栏的行数，显示在标题旁。
  function paneStats(text) {
    return text ? Kit.t('lineCount', { count: Kit.formatNumber(Core.splitLines(text).length) }) : '';
  }

  // 重新对比两栏并刷新结果。
  function compute() {
    const left = ui.left.value;
    const right = ui.right.value;
    ui.leftStats.textContent = paneStats(left);
    ui.rightStats.textContent = paneStats(right);
    expanded = new Set();
    // 只有一栏有内容时不对比：常见的是从终端带进来原文、还没粘贴修改后的版本，
    // 这时把整栏标成删除像是出了错。
    if (!left || !right) {
      current = null;
      showEmpty(Boolean(left || right));
      return;
    }
    const started = performance.now();
    current = Core.diffTexts(left, right, {
      maxLines: MAX_LINES,
      ignoreWhitespace: ui.ignoreWhitespace.checked,
      ignoreCase: ui.ignoreCase.checked,
    });
    current.partner = pairChanges(current.ops);
    current.elapsed = performance.now() - started;
    render();
  }

  const computeLater = Kit.debounce(compute, 250);

  // 输入变化后的重算：长文本去抖，短文本立即重算。
  function scheduleCompute() {
    if (ui.left.value.length + ui.right.value.length > DEBOUNCE_THRESHOLD) computeLater();
    else compute();
  }

  // 还不能对比：两栏都空时显示提示与示例按钮；已有一栏内容时只提示另一栏，
  // 不给示例按钮，因为示例会覆盖用户带进来的文本。
  function showEmpty(oneSideFilled) {
    ui.result.hidden = true;
    ui.empty.hidden = false;
    // 改 data-i18n 而不只改文字：切换语言时 Kit 按它重写文案。
    ui.emptyHint.dataset.i18n = oneSideFilled ? 'otherSideHint' : 'emptyHint';
    ui.emptyHint.textContent = Kit.t(ui.emptyHint.dataset.i18n);
    ui.sample.hidden = oneSideFilled;
    ui.note.hidden = true;
    ui.stats.replaceChildren();
    ui.elapsed.textContent = '';
    Kit.setEnabled(ui.copy, false);
  }

  // 同一段连续改动里，第 k 个删除行与第 k 个新增行配成一对，用来标出行内改了哪一部分。
  function pairChanges(ops) {
    const partner = new Map();
    let i = 0;
    while (i < ops.length) {
      if (ops[i].op === 'equal') {
        i += 1;
        continue;
      }
      let j = i;
      while (j < ops.length && ops[j].op !== 'equal') j += 1;
      const deletes = [];
      const inserts = [];
      for (let k = i; k < j; k += 1) (ops[k].op === 'delete' ? deletes : inserts).push(k);
      for (let k = 0; k < Math.min(deletes.length, inserts.length); k += 1) {
        partner.set(deletes[k], inserts[k]);
        partner.set(inserts[k], deletes[k]);
      }
      i = j;
    }
    return partner;
  }

  // 渲染统计与逐行结果。
  function render() {
    ui.empty.hidden = true;
    ui.result.hidden = false;
    ui.note.textContent = current.truncated ? Kit.t('truncatedInput', { limit: Kit.formatNumber(MAX_LINES) }) : '';
    ui.note.hidden = !current.truncated;
    ui.stats.replaceChildren(
      el('span', 'added', '+' + Kit.formatNumber(current.added)),
      el('span', 'removed', '−' + Kit.formatNumber(current.removed)),
      el('span', 'same', Kit.t('unchanged', { count: Kit.formatNumber(current.unchanged) })),
    );
    ui.elapsed.textContent = current.elapsed.toFixed(1) + ' ms';
    if (!current.added && !current.removed) {
      ui.result.replaceChildren(el('p', 'hint', Kit.t('identical')));
      Kit.setEnabled(ui.copy, false);
      return;
    }
    Kit.setEnabled(ui.copy, true);
    const fragment = document.createDocumentFragment();
    const rows = visibleRows(current.ops, ui.onlyChanges.checked);
    for (let i = 0; i < rows.length; i += 1) {
      if (i >= MAX_ROWS) {
        fragment.append(el('div', 'more hint', Kit.t('truncatedRender', { limit: Kit.formatNumber(MAX_ROWS) })));
        break;
      }
      fragment.append(rows[i].fold ? foldRow(rows[i]) : lineRow(rows[i].index));
    }
    ui.result.replaceChildren(fragment);
  }

  // 决定显示哪些行：不折叠时全显示；折叠时每处改动前后各留 3 行，中间成段的相同行收成一个可展开的按钮。
  function visibleRows(ops, fold) {
    const rows = [];
    let i = 0;
    while (i < ops.length) {
      if (!fold || ops[i].op !== 'equal') {
        rows.push({ index: i });
        i += 1;
        continue;
      }
      let j = i;
      while (j < ops.length && ops[j].op === 'equal') j += 1;
      // 开头的相同段前面没有改动，不用留上文；结尾的相同段后面没有改动，不用留下文。
      const keepHead = i === 0 ? 0 : CONTEXT;
      const keepTail = j === ops.length ? 0 : CONTEXT;
      const hidden = j - i - keepHead - keepTail;
      if (hidden < MIN_FOLD || expanded.has(i)) {
        for (let k = i; k < j; k += 1) rows.push({ index: k });
      } else {
        for (let k = i; k < i + keepHead; k += 1) rows.push({ index: k });
        rows.push({ fold: true, start: i, count: hidden });
        for (let k = j - keepTail; k < j; k += 1) rows.push({ index: k });
      }
      i = j;
    }
    return rows;
  }

  // 一行结果：旧行号、新行号、符号、内容。
  function lineRow(index) {
    const op = current.ops[index];
    const kind = op.op === 'equal' ? 'eq' : op.op === 'delete' ? 'del' : 'ins';
    const text = op.op === 'insert' ? current.linesB[op.b] : current.linesA[op.a];
    const row = el('div', 'line ' + kind);
    row.append(
      el('span', 'no', op.op === 'insert' ? '' : String(op.a + 1)),
      el('span', 'no', op.op === 'delete' ? '' : String(op.b + 1)),
      el('span', 'sign', kind === 'del' ? '−' : kind === 'ins' ? '+' : ''),
      lineText(index, op, text),
    );
    return row;
  }

  // 行内容；配成对的修改行把改动的那一段加深标出（整行都变了就不标）。
  function lineText(index, op, text) {
    const span = el('span', 'text');
    const partnerIndex = current.partner.get(index);
    if (partnerIndex === undefined) {
      span.textContent = text;
      return span;
    }
    const other = current.ops[partnerIndex];
    const oldText = op.op === 'delete' ? text : current.linesA[other.a];
    const newText = op.op === 'insert' ? text : current.linesB[other.b];
    const range = Core.changedSpan(oldText, newText);
    const end = op.op === 'delete' ? range.endOld : range.endNew;
    if (range.start === 0 && end === text.length) {
      span.textContent = text;
      return span;
    }
    span.append(text.slice(0, range.start), el('span', 'chg', text.slice(range.start, end)), text.slice(end));
    return span;
  }

  // 折叠段的「展开」按钮。
  function foldRow(row) {
    const button = el('button', 'fold', '⋯ ' + Kit.t('fold', { count: Kit.formatNumber(row.count) }));
    button.type = 'button';
    button.dataset.start = String(row.start);
    button.title = Kit.t('foldTitle');
    return button;
  }

  ui.left.addEventListener('input', scheduleCompute);
  ui.right.addEventListener('input', scheduleCompute);
  ui.ignoreWhitespace.addEventListener('change', compute);
  ui.ignoreCase.addEventListener('change', compute);
  ui.onlyChanges.addEventListener('change', () => {
    if (current) render();
  });
  ui.result.addEventListener('click', (event) => {
    const button = event.target.closest('.fold');
    if (!button) return;
    expanded.add(Number(button.dataset.start));
    render();
  });
  ui.swap.addEventListener('click', () => {
    const left = ui.left.value;
    ui.left.value = ui.right.value;
    ui.right.value = left;
    compute();
  });
  ui.copy.addEventListener('click', () => {
    if (current) Kit.copyText(Core.unifiedDiff(current, 'original', 'modified'));
  });
  ui.sample.addEventListener('click', () => {
    ui.left.value = SAMPLE_LEFT;
    ui.right.value = SAMPLE_RIGHT;
    compute();
  });

  Kit.onLocaleChange(compute);
  Kit.start({
    // 带进来的内容放进左栏（原文），焦点交给右栏，方便接着粘贴修改后的版本。
    onInput(text) {
      if (text) {
        ui.left.value = text;
        compute();
      }
      (ui.left.value ? ui.right : ui.left).focus({ preventScroll: true });
    },
    // 启动器搜索框继续输入的内容进右栏。
    onQuery(text) {
      ui.right.value = text;
      compute();
    },
  });
  compute();
})();
