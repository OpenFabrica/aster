// 密码生成工具的生成页：按规则生成密码、编辑与保存规则、填写用途属性；复制时用 concealed 写剪贴板并记入加密历史。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.PasswordCore;
  const Store = window.PasswordStore;
  const History = window.PasswordHistory;
  const Attributes = window.PasswordAttributes;
  const CUSTOM = '__custom';
  const MAX_USER_RULES = 50;

  const byId = (id) => document.getElementById(id);
  const ui = {
    tabs: { generate: byId('tab-generate'), history: byId('tab-history') },
    panels: { generate: byId('panel-generate'), history: byId('panel-history') },
    password: byId('password'),
    paramError: byId('param-error'),
    strength: byId('strength'),
    bits: byId('bits'),
    regenerate: byId('regenerate'),
    copy: byId('copy'),
    rule: byId('rule'),
    ruleActions: byId('rule-actions'),
    saveRule: byId('save-rule'),
    deleteRule: byId('delete-rule'),
    saveForm: byId('save-form'),
    ruleName: byId('rule-name'),
    saveCancel: byId('save-cancel'),
    ruleError: byId('rule-error'),
    lengthRange: byId('length-range'),
    length: byId('length'),
    upper: byId('opt-upper'),
    lower: byId('opt-lower'),
    digits: byId('opt-digits'),
    symbols: byId('opt-symbols'),
    symbolSet: byId('symbol-set'),
    ambiguous: byId('opt-ambiguous'),
    requireEach: byId('opt-require'),
    exclude: byId('exclude'),
  };

  const state = {
    tab: 'generate',
    rules: [],
    baseRuleId: 'strong',
    params: Core.params(),
    password: '',
    // 设置读完之前启动器给的长度先记在这里，读完再套用，免得被上次的选择覆盖。
    settingsReady: false,
    pendingLength: null,
  };

  // MARK: - 名字

  // 当前所有规则：默认规则在前，用户规则在后。
  function allRules() {
    return Core.DEFAULT_RULES.concat(state.rules);
  }

  // 规则的显示名：默认规则按 id 本地化。
  function ruleLabel(rule) {
    return rule.builtin ? Kit.t('rule.' + rule.id) : rule.name;
  }

  // 当前选中的基础规则；找不到时退回强密码。
  function baseRule() {
    return allRules().find((rule) => rule.id === state.baseRuleId) || Core.DEFAULT_RULES[0];
  }

  // 当前参数是否和基础规则不同（即「自定义（未保存）」）。
  function isModified() {
    return !Core.sameParams(state.params, baseRule().params);
  }

  // 历史条目应显示的规则名：默认规则按当前语言，用户规则用现在的名字，已删除的用当时的快照。
  function entryRuleName(entry) {
    const rule = entry.rule || {};
    if (rule.id === CUSTOM) return Kit.t('customShort');
    const found = allRules().find((item) => item.id === rule.id);
    return found ? ruleLabel(found) : rule.name || Kit.t('customShort');
  }

  // MARK: - 生成

  // 按当前参数生成一个新密码；参数不合法时就地提示，不生成，也不能复制。
  function regenerate() {
    const error = Core.validate(state.params);
    ui.paramError.hidden = !error;
    ui.password.hidden = !!error;
    if (error) {
      state.password = '';
      ui.paramError.textContent = paramErrorText(error);
    } else {
      state.password = Core.generate(state.params);
      renderPassword();
    }
    renderStrength(error);
    Kit.setEnabled(ui.copy, !!state.password);
    Kit.setEnabled(ui.regenerate, !error);
  }

  // 把参数错误转成当前语言的提示。
  function paramErrorText(error) {
    const detail = error.code === 'emptyClass' ? Kit.t(error.detail) : error.detail;
    return Kit.t('paramError.' + error.code, { detail, min: Core.MIN_LENGTH, max: Core.MAX_LENGTH });
  }

  // 显示密码：数字与符号着色，便于肉眼核对。
  function renderPassword() {
    const parts = Array.from(state.password, (ch) => {
      const span = History.el('span', /[0-9]/.test(ch) ? 'ch-digit' : /[A-Za-z]/.test(ch) ? '' : 'ch-symbol', ch);
      return span.className ? span : ch;
    });
    ui.password.replaceChildren(...parts);
    ui.password.classList.toggle('long', state.password.length > 40);
  }

  // 强度徽标与熵：弱 / 中 / 强 / 很强。
  function renderStrength(error) {
    if (error) {
      ui.strength.hidden = true;
      ui.bits.textContent = '';
      return;
    }
    const bits = Core.entropyBits(state.params);
    const level = Core.strength(bits);
    const tone = { weak: 'danger', fair: 'warn', strong: 'ok', veryStrong: 'ok' }[level];
    ui.strength.hidden = false;
    ui.strength.className = 'badge ' + tone;
    ui.strength.textContent = Kit.t('strength.' + level);
    ui.bits.textContent = Kit.t('bits', { bits: Kit.formatNumber(Math.floor(bits)) });
    ui.bits.title = Kit.t('bitsTitle');
  }

  // MARK: - 规则

  // 重建规则下拉框：改过参数时顶部多一项「自定义（未保存）」并选中它。
  function renderRuleSelect() {
    const modified = isModified();
    const option = (value, text) => {
      const node = History.el('option', '', text);
      node.value = value;
      return node;
    };
    const groups = [];
    if (modified) groups.push(option(CUSTOM, Kit.t('customRule')));
    const defaults = History.el('optgroup');
    defaults.label = Kit.t('defaultRules');
    Core.DEFAULT_RULES.forEach((rule) => defaults.appendChild(option(rule.id, ruleLabel(rule))));
    groups.push(defaults);
    if (state.rules.length) {
      const mine = History.el('optgroup');
      mine.label = Kit.t('myRules');
      state.rules.forEach((rule) => mine.appendChild(option(rule.id, rule.name)));
      groups.push(mine);
    }
    ui.rule.replaceChildren(...groups);
    ui.rule.value = modified ? CUSTOM : baseRule().id;
    const valid = !Core.validate(state.params);
    Kit.setEnabled(ui.saveRule, modified && valid && state.rules.length < MAX_USER_RULES);
    ui.saveRule.title = state.rules.length >= MAX_USER_RULES ? Kit.t('tooManyRules', { max: MAX_USER_RULES }) : '';
    ui.deleteRule.hidden = modified || baseRule().builtin;
  }

  // 把参数写进表单控件。
  function renderParams() {
    const p = state.params;
    ui.lengthRange.value = String(p.length);
    ui.length.value = String(p.length);
    ui.length.classList.remove('invalid');
    ui.upper.checked = p.upper;
    ui.lower.checked = p.lower;
    ui.digits.checked = p.digits;
    ui.symbols.checked = p.symbols;
    ui.symbolSet.value = p.symbolSet;
    ui.symbolSet.disabled = !p.symbols;
    ui.ambiguous.checked = p.excludeAmbiguous;
    ui.requireEach.checked = p.requireEach;
    ui.exclude.value = p.exclude;
  }

  // 从表单读回参数；长度框不是 4–128 的整数时保留原样交给校验报错。
  function readParams() {
    const length = Number(ui.length.value);
    ui.length.classList.toggle('invalid', !Number.isInteger(length) || length < Core.MIN_LENGTH || length > Core.MAX_LENGTH);
    return {
      length: ui.length.value.trim() === '' ? NaN : length,
      upper: ui.upper.checked,
      lower: ui.lower.checked,
      digits: ui.digits.checked,
      symbols: ui.symbols.checked,
      symbolSet: ui.symbolSet.value,
      excludeAmbiguous: ui.ambiguous.checked,
      exclude: ui.exclude.value,
      requireEach: ui.requireEach.checked,
    };
  }

  // 表单改动后：更新参数、下拉框状态并重新生成；合法时记住这次选择。
  function onParamsChanged() {
    state.params = readParams();
    ui.symbolSet.disabled = !state.params.symbols;
    renderRuleSelect();
    regenerate();
    persistSelection();
  }

  // 切换到某条规则：参数换成规则的副本并重新生成。
  function selectRule(id) {
    const rule = allRules().find((item) => item.id === id);
    if (!rule) return;
    state.baseRuleId = rule.id;
    state.params = Core.normalizeParams(rule.params);
    closeSaveForm();
    renderParams();
    renderRuleSelect();
    regenerate();
    persistSelection();
  }

  // 记住当前规则与参数（含未保存的修改）。拖动滑块会连续触发，合并后再写，免得撞上桥接的每秒调用上限。
  const persistSelection = Kit.debounce(() => {
    if (Core.validate(state.params)) return;
    persist(Store.saveSelection(state.baseRuleId, state.params));
  }, 400);

  // 等待一次设置写入，失败时提示（设置不是机密，失败不影响生成）。
  function persist(promise) {
    promise.catch((error) => Kit.showStatus(Kit.t('settingsFailed', { detail: Kit.errorMessage(error) }), 'error'));
  }

  // 打开「保存为规则」的命名表单。
  function openSaveForm() {
    ui.ruleActions.hidden = true;
    ui.saveForm.hidden = false;
    ui.ruleName.value = '';
    ui.ruleError.hidden = true;
    ui.ruleName.focus();
  }

  // 收起命名表单。
  function closeSaveForm() {
    ui.saveForm.hidden = true;
    ui.ruleActions.hidden = false;
    ui.ruleError.hidden = true;
  }

  // 把当前参数存成用户规则；名字不能为空、不能和已有规则重名。
  function saveRule() {
    let name;
    try {
      name = Core.checkName(ui.ruleName.value, allRules().map(ruleLabel));
    } catch (error) {
      ui.ruleError.textContent = Kit.t('nameError.' + error.code, { max: Core.NAME_LIMIT });
      ui.ruleError.hidden = false;
      ui.ruleName.focus();
      return;
    }
    const rule = { id: Core.makeId(), name, params: Core.normalizeParams(state.params) };
    state.rules = state.rules.concat(rule);
    state.baseRuleId = rule.id;
    closeSaveForm();
    renderRuleSelect();
    persist(Store.saveRules(state.rules));
    persistSelection();
    Kit.showStatus(Kit.t('ruleSaved', { name }));
  }

  // 删除当前选中的用户规则，回到强密码。
  function deleteRule() {
    const rule = baseRule();
    if (rule.builtin) return;
    state.rules = state.rules.filter((item) => item.id !== rule.id);
    persist(Store.saveRules(state.rules));
    selectRule('strong');
    Kit.showStatus(Kit.t('ruleDeleted', { name: rule.name }));
  }

  // MARK: - 复制与历史

  // 复制当前密码（concealed），成功后记入加密历史；同一密码再次复制只更新属性与时间。
  async function copyPassword() {
    const password = state.password;
    if (!password) return;
    const copied = await Kit.callBridge((aster) => aster.clipboard.writeText(password, { concealed: true }));
    if (!copied) return;
    const { attributes, attributeNames } = Attributes.collect();
    const modified = isModified();
    const rule = {
      id: modified ? CUSTOM : baseRule().id,
      name: modified ? Kit.t('customShort') : ruleLabel(baseRule()),
      params: Core.normalizeParams(state.params),
    };
    try {
      await Store.updateHistory((list) => Core.recordCopy(list, { password, rule, attributes, attributeNames }));
      Kit.showStatus(Kit.t('copiedRecorded'));
    } catch (error) {
      const reason = error instanceof Store.SecureUnavailableError ? Kit.t('secureUnavailable') : Kit.errorMessage(error);
      Kit.showStatus(Kit.t('copiedNotRecorded', { detail: reason }), 'error');
    }
    History.render();
  }

  // MARK: - 页面

  // 切换「生成 / 历史」标签页；离开历史页时重新遮罩密码。
  function setTab(tab) {
    if (state.tab === 'history' && tab !== 'history') History.hideAll();
    state.tab = tab;
    for (const key of Object.keys(ui.tabs)) {
      const active = key === tab;
      ui.tabs[key].setAttribute('aria-pressed', String(active));
      ui.tabs[key].setAttribute('aria-selected', String(active));
      ui.panels[key].hidden = !active;
    }
    if (tab === 'history') History.render();
  }

  // 全局快捷键：⌘↩ 复制、焦点不在输入框时 ↩ 复制、⌘R 重新生成（同时挡住网页刷新）、Esc 收起表单。
  function onKeyDown(event) {
    if (event.isComposing) return;
    const target = event.target instanceof Element ? event.target : document.body;
    const inForm = !!target.closest('form');
    const plainKey = !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey;
    if (event.metaKey && !event.ctrlKey && !event.altKey && event.key.toLowerCase() === 'r') {
      event.preventDefault();
      if (state.tab === 'generate') regenerate();
      return;
    }
    if (event.key === 'Escape' && inForm) {
      event.preventDefault();
      closeSaveForm();
      Attributes.closeForm();
      return;
    }
    if (event.key !== 'Enter' || state.tab !== 'generate' || inForm) return;
    const typing = !!target.closest('input, textarea, select, button');
    if ((event.metaKey && !event.ctrlKey && !event.altKey) || (plainKey && !typing)) {
      event.preventDefault();
      copyPassword();
    }
  }

  // 语言变了：重绘所有动态文字。
  function rerender() {
    renderRuleSelect();
    Attributes.render();
    renderStrength(Core.validate(state.params));
    if (!ui.paramError.hidden) ui.paramError.textContent = paramErrorText(Core.validate(state.params));
    History.render();
  }

  // 启动器输入了长度：只改长度，其余参数沿用，并重新生成。
  function applyLength(length) {
    state.params = Object.assign({}, state.params, { length });
    renderParams();
    onParamsChanged();
  }

  // 接上事件、生成第一个密码，再读取设置恢复上次的规则与属性。
  async function init() {
    ui.tabs.generate.addEventListener('click', () => setTab('generate'));
    ui.tabs.history.addEventListener('click', () => setTab('history'));
    ui.regenerate.addEventListener('click', regenerate);
    ui.copy.addEventListener('click', copyPassword);
    ui.rule.addEventListener('change', () => { if (ui.rule.value !== CUSTOM) selectRule(ui.rule.value); });
    ui.saveRule.addEventListener('click', openSaveForm);
    ui.saveCancel.addEventListener('click', closeSaveForm);
    ui.saveForm.addEventListener('submit', (event) => { event.preventDefault(); saveRule(); });
    History.armConfirm(ui.deleteRule, {
      confirmKey: 'confirmDelete',
      restore: () => { ui.deleteRule.textContent = Kit.t('deleteRule'); },
      onConfirm: deleteRule,
    });
    ui.lengthRange.addEventListener('input', () => {
      ui.length.value = ui.lengthRange.value;
      onParamsChanged();
    });
    ui.length.addEventListener('input', () => {
      if (Core.parseLength(ui.length.value)) ui.lengthRange.value = ui.length.value;
      onParamsChanged();
    });
    // 离开长度框时把不合法的值收回范围内（空或非数字时退回滑块上的值），避免一直停在报错状态。
    ui.length.addEventListener('change', () => {
      const raw = ui.length.value.trim();
      const number = Math.round(Number(raw));
      const fixed = raw && Number.isFinite(number)
        ? Math.min(Core.MAX_LENGTH, Math.max(Core.MIN_LENGTH, number))
        : Number(ui.lengthRange.value);
      if (String(fixed) === raw) return;
      ui.length.value = String(fixed);
      ui.lengthRange.value = String(fixed);
      onParamsChanged();
    });
    [ui.upper, ui.lower, ui.digits, ui.symbols, ui.ambiguous, ui.requireEach].forEach((box) => box.addEventListener('change', onParamsChanged));
    [ui.symbolSet, ui.exclude].forEach((input) => input.addEventListener('input', onParamsChanged));
    document.addEventListener('keydown', onKeyDown);
    Kit.onLocaleChange(rerender);

    Attributes.init({ persist });
    History.init({ ruleName: entryRuleName, attributeName: Attributes.entryName });
    Kit.start({
      onInput(text) {
        setTab('generate');
        const length = Core.parseLength(text);
        if (!length) return;
        if (!state.settingsReady) state.pendingLength = length;
        else applyLength(length);
      },
      onQuery(text) {
        if (state.tab === 'history') History.setQuery(text);
      },
    });

    renderParams();
    renderRuleSelect();
    regenerate();

    const settings = await Store.loadSettings((error) => {
      Kit.showStatus(Kit.t('settingsLoadFailed', { detail: Kit.errorMessage(error) }), 'error');
    });
    state.rules = settings.rules;
    Attributes.setUserAttributes(settings.attributes);
    if (settings.selection) {
      state.baseRuleId = allRules().some((rule) => rule.id === settings.selection.ruleId) ? settings.selection.ruleId : 'strong';
      state.params = settings.selection.params;
    }
    state.settingsReady = true;
    renderParams();
    renderRuleSelect();
    if (state.pendingLength) applyLength(state.pendingLength);
    else regenerate();
  }

  init();
})();
