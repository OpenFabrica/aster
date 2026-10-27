// 正则测试工具的界面逻辑：高亮匹配、列出分组；匹配在 Worker 里跑，超过 1 秒就终止，Worker 不可用时退回主线程。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.RegexCore;
  const TIMEOUT_MS = 1000;
  // Worker 加载脚本的最长等待；超过就当作 Worker 不可用。
  const STARTUP_TIMEOUT_MS = 3000;
  const MAX_MATCHES = 1000;
  const WORKER_TEXT_LIMIT = 500000;
  // 主线程匹配无法中途打断：除了拦截嵌套量词，还限制文本长度，降低回溯卡住页面的风险。
  const MAIN_THREAD_TEXT_LIMIT = 20000;
  // 文本较长时输入去抖；短文本每次按键都直接匹配，结果几毫秒就回来，高亮不闪。
  const DEBOUNCE_THRESHOLD = 50000;
  const SAMPLE = {
    pattern: '(?<year>\\d{4})-(?<month>\\d{2})-(?<day>\\d{2})',
    flags: 'g',
    text: '2026-10-27 09:15:02 INFO  Aster started\n'
      + '2026-10-27 09:15:07 WARN  Plugin aster.regex reloaded\n'
      + 'Release 0.6.26 shipped on 2026-10-20.',
  };

  const byId = (id) => document.getElementById(id);
  const ui = {
    patternBox: byId('pattern-box'),
    pattern: byId('pattern'),
    flagText: byId('flag-text'),
    summary: byId('summary'),
    elapsed: byId('elapsed'),
    copyRegex: byId('copy-regex'),
    copyMatches: byId('copy-matches'),
    error: byId('error'),
    note: byId('note'),
    textStats: byId('text-stats'),
    backdrop: byId('backdrop'),
    text: byId('text'),
    matches: byId('matches'),
    empty: byId('empty'),
    sample: byId('sample'),
    emptyHint: byId('empty-hint'),
  };
  const flagButtons = Array.from(document.querySelectorAll('.flag'));
  // 匹配引擎状态：mode 为 'worker' 或 'main'；ready 表示当前 Worker 已加载完脚本，everReady 表示 Worker 至少成功启动过一次。
  const engine = { worker: null, ready: false, everReady: false, mode: 'worker', pending: null, seq: 0 };
  let flags = 'g';
  // 当前显示的结果 {job, result}；复制匹配、点击定位都用它。
  let shown = null;
  let activeMark = null;

  // 创建元素并设置类名与文字。
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // MARK: - 匹配引擎

  // 按需创建 Worker；构造函数直接抛错（例如被 CSP 拦下）时返回 null。
  function ensureWorker() {
    if (engine.worker) return engine.worker;
    try {
      engine.worker = new Worker('regex-worker.js');
    } catch (error) {
      return null;
    }
    engine.ready = false;
    engine.worker.onmessage = onWorkerMessage;
    engine.worker.onerror = onWorkerError;
    return engine.worker;
  }

  // 结束 Worker 线程；下次需要时再新建。
  function terminateWorker() {
    if (!engine.worker) return;
    engine.worker.terminate();
    engine.worker = null;
    engine.ready = false;
  }

  // 放弃还在跑的任务：旧结果已经没用，而且它可能正卡在回溯里，所以连线程一起结束。
  function cancelPending() {
    if (!engine.pending) return;
    clearTimeout(engine.pending.timer);
    engine.pending = null;
    terminateWorker();
  }

  // 给当前任务计时。Worker 就绪后才开始 1 秒的匹配预算：加载脚本慢不能算成正则超时，
  // 更不能因此误判 Worker 不可用、把可能卡死的正则挪到主线程跑；还没就绪时只等启动，最多 3 秒。
  function armTimer() {
    const pending = engine.pending;
    if (!pending) return;
    clearTimeout(pending.timer);
    const id = pending.id;
    pending.timer = engine.ready
      ? setTimeout(() => onTimeout(id), TIMEOUT_MS)
      : setTimeout(() => onStartupTimeout(id), STARTUP_TIMEOUT_MS);
  }

  // 执行一次任务：Worker 模式下发消息并计时；主线程模式下直接同步算。
  function runJob(job) {
    cancelPending();
    if (engine.mode === 'main') {
      runOnMainThread(job);
      return;
    }
    const worker = ensureWorker();
    if (!worker) {
      fallBackToMainThread();
      return;
    }
    engine.seq += 1;
    engine.pending = { id: engine.seq, job, timer: 0 };
    worker.postMessage({ id: engine.seq, pattern: job.pattern, flags: job.flags, text: job.text, limit: MAX_MATCHES });
    armTimer();
  }

  // 主线程匹配无法中途打断：先拦下「量词套量词」这类最常见的灾难性写法，宁可不跑也不能把页面卡死。
  function runOnMainThread(job) {
    if (Core.hasNestedQuantifier(job.pattern)) {
      showProblem(Kit.t('unsafeOnMainThread'));
      return;
    }
    try {
      showResult(job, Core.run(job.pattern, job.flags, job.text, MAX_MATCHES));
    } catch (error) {
      showInvalid(error.message);
    }
  }

  // Worker 回消息：ready 表示脚本已加载、开始给任务计时；其余是任务结果，只认当前任务的 id。
  function onWorkerMessage(event) {
    const data = event.data || {};
    if (data.type === 'ready') {
      engine.ready = true;
      engine.everReady = true;
      armTimer();
      return;
    }
    const pending = engine.pending;
    if (!pending || data.id !== pending.id) return;
    clearTimeout(pending.timer);
    engine.pending = null;
    if (data.ok) showResult(pending.job, data.result);
    else showInvalid(data.error);
  }

  // Worker 出错：从没成功启动过（CSP、MIME 类型等导致脚本加载失败）就改用主线程；启动过的只影响这一次，下次重建。
  function onWorkerError(event) {
    if (event && event.preventDefault) event.preventDefault();
    const pending = engine.pending;
    if (pending) clearTimeout(pending.timer);
    engine.pending = null;
    terminateWorker();
    if (!engine.everReady) {
      fallBackToMainThread();
      return;
    }
    if (pending) showProblem((event && event.message) || 'Worker error');
  }

  // 匹配超过 1 秒：结束 Worker 线程并提示可能是灾难性回溯。
  function onTimeout(id) {
    const pending = engine.pending;
    if (!pending || pending.id !== id) return;
    engine.pending = null;
    terminateWorker();
    showProblem(Kit.t('timeout'));
  }

  // Worker 3 秒还没加载完：从没启动成功过就当作不可用（例如被静默拦下），改用主线程；启动成功过则只算这一次超时。
  function onStartupTimeout(id) {
    const pending = engine.pending;
    if (!pending || pending.id !== id) return;
    engine.pending = null;
    terminateWorker();
    if (engine.everReady) showProblem(Kit.t('timeout'));
    else fallBackToMainThread();
  }

  // 切到主线程模式并按新的文本上限重算。
  function fallBackToMainThread() {
    if (engine.pending) clearTimeout(engine.pending.timer);
    engine.pending = null;
    terminateWorker();
    engine.mode = 'main';
    document.documentElement.dataset.regexEngine = 'main';
    refresh();
  }

  // MARK: - 刷新与渲染

  // 读取当前输入并刷新：正则为空或语法错误时直接更新界面，否则发一次匹配任务。
  function refresh() {
    const pattern = ui.pattern.value;
    const text = ui.text.value;
    ui.flagText.textContent = flags;
    // 结尾的换行不算多出来的一行。
    const lines = text.split('\n').length - (text.endsWith('\n') ? 1 : 0);
    ui.textStats.textContent = text ? Kit.t('textStats', {
      chars: Kit.formatNumber(text.length),
      lines: Kit.formatNumber(lines),
    }) : '';
    ui.error.hidden = true;
    ui.patternBox.classList.remove('invalid');
    const limit = engine.mode === 'main' ? MAIN_THREAD_TEXT_LIMIT : WORKER_TEXT_LIMIT;
    showNote(engine.mode === 'main' ? Kit.t('mainThread', { count: Kit.formatNumber(limit) })
      : text.length > limit ? Kit.t('textTruncated', { count: Kit.formatNumber(limit) }) : '');
    if (!pattern) {
      cancelPending();
      showIdle();
      return;
    }
    // 编译很快且不会回溯，先在主线程检查语法，错误能立刻显示。
    try {
      Core.compile(pattern, flags);
    } catch (error) {
      cancelPending();
      showInvalid(error.message);
      return;
    }
    Kit.setEnabled(ui.copyRegex, true);
    runJob({ pattern, flags, text: text.length > limit ? text.slice(0, limit) : text });
  }

  const refreshLater = Kit.debounce(refresh, 150);

  // 输入变化后的刷新：长文本去抖，短文本立即刷新。
  function scheduleRefresh() {
    if (ui.text.value.length > DEBOUNCE_THRESHOLD) refreshLater();
    else refresh();
  }

  // 显示或隐藏黄色说明条。
  function showNote(text) {
    ui.note.textContent = text;
    ui.note.hidden = !text;
  }

  // 正则为空：清掉高亮与结果，显示提示。已有测试文本时只提示输入正则，不给示例按钮，
  // 因为示例会覆盖用户带进来的文本。
  function showIdle() {
    shown = null;
    const hasText = Boolean(ui.text.value);
    // 改 data-i18n 而不只改文字：切换语言时 Kit 按它重写文案。
    ui.emptyHint.dataset.i18n = hasText ? 'patternHint' : 'emptyHint';
    ui.emptyHint.textContent = Kit.t(ui.emptyHint.dataset.i18n);
    ui.sample.hidden = hasText;
    renderHighlights(ui.text.value, []);
    ui.matches.replaceChildren();
    ui.matches.hidden = true;
    ui.empty.hidden = false;
    ui.summary.textContent = '';
    ui.elapsed.textContent = '';
    Kit.setEnabled(ui.copyRegex, false);
    Kit.setEnabled(ui.copyMatches, false);
  }

  // 正则无效：标红输入框并显示引擎给出的错误。
  function showInvalid(message) {
    ui.patternBox.classList.add('invalid');
    Kit.setEnabled(ui.copyRegex, false);
    showProblem(Kit.t('invalid', { message }));
  }

  // 出错或超时：清掉旧结果，显示红色说明。
  function showProblem(message) {
    shown = null;
    ui.error.textContent = message;
    ui.error.hidden = false;
    renderHighlights(ui.text.value, []);
    ui.matches.replaceChildren();
    ui.matches.hidden = false;
    ui.empty.hidden = true;
    ui.summary.textContent = '';
    ui.elapsed.textContent = '';
    Kit.setEnabled(ui.copyMatches, false);
  }

  // 显示一次匹配结果；用户已经改了文本（结果对不上）时跳过，等下一次结果。
  function showResult(job, result) {
    const text = ui.text.value;
    if (!text.startsWith(job.text) || ui.pattern.value !== job.pattern || flags !== job.flags) return;
    shown = { job, result };
    const count = result.matches.length;
    ui.summary.textContent = count === 0 ? Kit.t('summary.none')
      : count === 1 ? Kit.t('summary.one') : Kit.t('summary.count', { count: Kit.formatNumber(count) });
    const extra = [result.elapsed + ' ms'];
    if (result.truncated) extra.unshift(Kit.t('summary.truncated', { count: Kit.formatNumber(MAX_MATCHES) }));
    ui.elapsed.textContent = extra.join(' · ');
    renderHighlights(text, result.matches);
    renderMatches(result.matches);
    Kit.setEnabled(ui.copyMatches, result.matches.some((match) => match.end > match.start));
  }

  // 背景层与输入框逐字对齐，匹配处用 <mark> 垫底色。
  function renderHighlights(text, matches) {
    const fragment = document.createDocumentFragment();
    let last = 0;
    matches.forEach((match, index) => {
      if (match.start < last) return;
      fragment.append(text.slice(last, match.start));
      const mark = el('mark', (index % 2 ? 'alt' : '') + (match.end === match.start ? ' empty' : ''));
      mark.dataset.index = String(index);
      mark.textContent = text.slice(match.start, match.end);
      fragment.append(mark);
      last = match.end;
    });
    // textarea 在结尾换行后会多显示一行，div 不会；末尾补一个空格让两层高度相同，滚动才能对齐。
    fragment.append(text.slice(last) + ' ');
    ui.backdrop.replaceChildren(fragment);
    activeMark = null;
    syncScroll();
  }

  // 生成匹配列表：序号、匹配文字、位置，以及每个分组（命名分组同时显示编号与名字）。
  function renderMatches(matches) {
    ui.empty.hidden = true;
    ui.matches.hidden = false;
    if (!matches.length) {
      ui.matches.replaceChildren(el('p', 'hint', Kit.t('noMatches')));
      return;
    }
    const fragment = document.createDocumentFragment();
    matches.forEach((match, index) => {
      const item = el('button', 'match');
      item.type = 'button';
      item.dataset.index = String(index);
      const head = el('div', 'match-head');
      head.append(
        el('span', 'match-no', String(index + 1)),
        visibleText('match-text', match.text, match.end - match.start),
        el('span', 'match-pos', match.start + '–' + match.end),
      );
      item.append(head);
      if (match.groups.length) {
        const groups = el('div', 'groups');
        for (const group of match.groups) {
          const chip = el('span', 'group');
          chip.append(el('span', 'group-name', group.name ? group.n + ' · ' + group.name : String(group.n)));
          chip.append(group.text === null ? el('span', 'muted-text', Kit.t('unmatchedGroup'))
            : visibleText('group-text', group.text, group.end - group.start));
          groups.append(chip);
        }
        item.append(groups);
      }
      fragment.append(item);
    });
    ui.matches.replaceChildren(fragment);
  }

  // 匹配文字的展示：换行、制表符换成可见符号；被截断时加省略号；空串显示「空匹配」。
  function visibleText(className, text, fullLength) {
    if (!text) return el('span', 'muted-text', Kit.t('emptyMatch'));
    const display = text.replace(/\n/g, '↵').replace(/\t/g, '⇥');
    return el('span', className, fullLength > text.length ? display + '…' : display);
  }

  // 背景层跟随输入框滚动。
  function syncScroll() {
    ui.backdrop.scrollTop = ui.text.scrollTop;
    ui.backdrop.scrollLeft = ui.text.scrollLeft;
  }

  // 高亮列表悬停对应的那一处匹配。
  function setActiveMark(index) {
    if (activeMark) activeMark.classList.remove('active');
    activeMark = index === null ? null : ui.backdrop.querySelector('mark[data-index="' + index + '"]');
    if (activeMark) activeMark.classList.add('active');
  }

  // 应用一个 /pattern/flags 或单独的正则。
  function setPattern(pattern, nextFlags) {
    ui.pattern.value = pattern;
    if (typeof nextFlags === 'string') {
      flags = Core.normalizeFlags(nextFlags);
      flagButtons.forEach((button) => button.setAttribute('aria-pressed', String(flags.includes(button.dataset.flag))));
    }
  }

  // 输入框里的文字若是 /…/flags 字面量就拆开，否则当成正则本身。
  function applyPatternText(text) {
    const literal = Core.splitLiteral(text);
    if (literal) setPattern(literal.pattern, literal.flags);
    else setPattern(text);
  }

  // MARK: - 事件

  ui.pattern.addEventListener('input', (event) => {
    // 粘贴 /…/gi 这种字面量时自动拆出标志；逐字输入时不拆，免得打到一半被改写。
    if (event.inputType === 'insertFromPaste' && Core.splitLiteral(ui.pattern.value)) {
      applyPatternText(ui.pattern.value);
    }
    scheduleRefresh();
  });
  ui.text.addEventListener('input', scheduleRefresh);
  ui.text.addEventListener('scroll', syncScroll);
  window.addEventListener('resize', syncScroll);

  flagButtons.forEach((button) => {
    button.addEventListener('click', () => {
      const flag = button.dataset.flag;
      setPattern(ui.pattern.value, flags.includes(flag) ? flags.replace(flag, '') : flags + flag);
      refresh();
    });
  });

  ui.matches.addEventListener('click', (event) => {
    const item = event.target.closest('.match');
    if (!item || !shown) return;
    const match = shown.result.matches[Number(item.dataset.index)];
    ui.text.focus({ preventScroll: true });
    ui.text.setSelectionRange(match.start, match.end);
    const mark = ui.backdrop.querySelector('mark[data-index="' + item.dataset.index + '"]');
    if (mark) ui.text.scrollTop = Math.max(0, mark.offsetTop - ui.text.clientHeight / 3);
    syncScroll();
  });
  ui.matches.addEventListener('mouseover', (event) => {
    const item = event.target.closest('.match');
    setActiveMark(item ? item.dataset.index : null);
  });
  ui.matches.addEventListener('mouseleave', () => setActiveMark(null));

  ui.copyRegex.addEventListener('click', () => {
    if (!ui.pattern.value) return;
    // 用 RegExp 自己生成字面量，正则里的 / 会被正确转义。
    Kit.copyText(String(new RegExp(ui.pattern.value, flags)));
  });
  ui.copyMatches.addEventListener('click', () => {
    if (!shown) return;
    const text = shown.result.matches
      .filter((match) => match.end > match.start)
      .map((match) => shown.job.text.slice(match.start, match.end))
      .join('\n');
    Kit.copyText(text);
  });
  ui.sample.addEventListener('click', () => {
    setPattern(SAMPLE.pattern, SAMPLE.flags);
    ui.text.value = SAMPLE.text;
    refresh();
    ui.pattern.focus();
  });

  Kit.onLocaleChange(refresh);
  Kit.start({
    // 传进来的内容是 /…/flags 字面量（单行）就当正则，否则当测试文本。
    onInput(text) {
      if (text) {
        if (!text.includes('\n') && Core.splitLiteral(text)) applyPatternText(text);
        else ui.text.value = text;
        refresh();
      }
      (ui.pattern.value ? ui.text : ui.pattern).focus({ preventScroll: true });
    },
    // 启动器搜索框继续输入时更新正则。
    onQuery(text) {
      applyPatternText(text);
      refresh();
    },
  });
  document.documentElement.dataset.regexEngine = engine.mode;
  refresh();
})();
