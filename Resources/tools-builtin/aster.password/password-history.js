// 密码生成工具的历史页：遮罩显示、按属性与规则名搜索、复制（不再新增记录）、修改密码与属性、删除与清空（页面内二次确认）。
// 也导出生成页共用的小工具：建元素、画图标、按钮二次确认。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.PasswordCore;
  const Store = window.PasswordStore;
  const SVG_NS = 'http://www.w3.org/2000/svg';
  // 16×16 线条图标的路径；用 DOM 生成，不需要内联脚本或外部字体。
  const ICONS = {
    eye: 'M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z M10 8a2 2 0 1 1-4 0a2 2 0 1 1 4 0z',
    eyeOff: 'M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8s-2.4 4.5-6.5 4.5S1.5 8 1.5 8z M10 8a2 2 0 1 1-4 0a2 2 0 1 1 4 0z M2.5 2.5l11 11',
    copy: 'M6 5.5h6a.5.5 0 0 1 .5.5v7a.5.5 0 0 1-.5.5H6a.5.5 0 0 1-.5-.5V6a.5.5 0 0 1 .5-.5z M3.5 10.5V3a.5.5 0 0 1 .5-.5h6',
    edit: 'M10.5 2.5l3 3-8 8H2.5v-3z M9 4l3 3',
    trash: 'M3 4.5h10 M6.5 4.5V3h3v1.5 M4.5 4.5l.6 8.5a1 1 0 0 0 1 .9h3.8a1 1 0 0 0 1-.9l.6-8.5',
    lock: 'M4.5 7.5h7a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1z M5.5 7.5V5.5a2.5 2.5 0 0 1 5 0v2',
    close: 'M4.5 4.5l7 7 M11.5 4.5l-7 7',
  };
  const MASK = '••••••••••••';
  // 二次确认按钮在这么久之后自动复原。
  const CONFIRM_TIMEOUT_MS = 4000;

  const byId = (id) => document.getElementById(id);
  const ui = {
    tab: byId('tab-history'),
    count: byId('history-count'),
    search: byId('search'),
    clear: byId('clear-history'),
    clearCancel: byId('clear-cancel'),
    error: byId('history-error'),
    list: byId('history-list'),
    empty: byId('history-empty'),
    emptyText: byId('history-empty-text'),
    lock: document.querySelector('.secure-note .lock'),
  };
  // 由生成页注入：条目当前应显示的规则名与属性名。
  let ctx = {
    ruleName: (entry) => (entry.rule && entry.rule.name) || '',
    attributeName: (id, snapshot) => snapshot || id,
    attributes: () => [],
  };
  // 本次会话里点开了眼睛的条目 id；切换页或关闭后都恢复遮罩。
  const revealed = new Set();
  // 正在编辑的条目与草稿 {id, password, values}；只在内存里，重绘时保留，切走或关闭即丢弃。
  let editing = null;
  let loadError = null;
  let disarmClear = () => {};

  // 创建元素并设置类名与文字。
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // 生成一个线条图标。
  function icon(name) {
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 16 16');
    svg.setAttribute('class', 'icon');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(SVG_NS, 'path');
    path.setAttribute('d', ICONS[name]);
    svg.appendChild(path);
    return svg;
  }

  // 生成一个只有图标的小按钮，title 与无障碍名称都用同一句文案。
  function iconButton(name, label) {
    const button = el('button', 'btn small icon-btn');
    button.type = 'button';
    button.title = label;
    button.setAttribute('aria-label', label);
    button.appendChild(icon(name));
    return button;
  }

  // 页面里没有 confirm()，危险操作改成点两次：第一次按钮变红并显示确认文案，几秒内再点才执行。
  // restore() 负责把按钮恢复成原来的内容；返回一个手动复原的函数。
  function armConfirm(button, options) {
    let timer = 0;
    const disarm = () => {
      clearTimeout(timer);
      if (!button.dataset.armed) return;
      delete button.dataset.armed;
      button.classList.remove('danger');
      options.restore();
      if (options.onDisarm) options.onDisarm();
    };
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      if (button.dataset.armed) {
        disarm();
        options.onConfirm();
        return;
      }
      button.dataset.armed = '1';
      button.classList.add('danger');
      button.replaceChildren(Kit.t(options.confirmKey));
      timer = setTimeout(disarm, CONFIRM_TIMEOUT_MS);
      if (options.onArm) options.onArm();
    });
    return disarm;
  }

  // 按当前语言格式化记录时间；无法解析时原样显示。
  function formatTime(iso) {
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return String(iso);
    return new Intl.DateTimeFormat(Kit.locale, { dateStyle: 'medium', timeStyle: 'short' }).format(date);
  }

  // 用 concealed 写剪贴板，剪贴板管理器不记录；历史页复制不再新增记录。
  function copyConcealed(password) {
    return Kit.callBridge((aster) => aster.clipboard.writeText(password, { concealed: true }), 'copied');
  }

  // 修改历史并重绘；失败时就地提示，原内容不变。onSuccess 在写入成功后、重绘前调用。
  async function mutate(mutator, okKey, onSuccess) {
    try {
      await Store.updateHistory(mutator);
      if (onSuccess) onSuccess();
      if (okKey) Kit.showStatus(Kit.t(okKey));
    } catch (error) {
      Kit.showStatus(errorText(error, 'historyWriteFailed'), 'error');
    }
    render();
  }

  // 把存储错误转成提示；secureStorage 缺失时给专门的说明。
  function errorText(error, key) {
    if (error instanceof Store.SecureUnavailableError) return Kit.t(Kit.bridge ? 'secureUnavailable' : 'needsAster');
    return Kit.t(key, { detail: Kit.errorMessage(error) });
  }

  // 编辑表单里要列出的属性：当前所有属性在前，条目里已删除属性的旧值在后（按当时的名字），都可以改或清空。
  function editableAttributes(entry) {
    const list = ctx.attributes();
    const known = new Set(list.map((item) => item.id));
    for (const id of Object.keys(entry.attributes || {})) {
      if (!known.has(id)) list.push({ id, name: ctx.attributeName(id, (entry.attributeNames || {})[id]) });
    }
    return list;
  }

  // 打开一条历史的编辑表单：草稿从条目复制，焦点放到密码框。
  function startEdit(entry) {
    editing = { id: entry.id, password: entry.password, values: Object.assign({}, entry.attributes) };
    render();
    const input = ui.list.querySelector('.entry-edit-password');
    if (input) input.focus();
  }

  // 收起编辑表单，丢弃草稿。
  function cancelEdit() {
    editing = null;
    render();
  }

  // 保存编辑：先在当前历史上校验，不合法就地提示且保留草稿；写入成功后才收起表单。
  function saveEdit(entry, names, errorNode, passwordInput) {
    const changes = { password: editing.password, attributes: editing.values, attributeNames: names };
    try {
      Core.editEntry(Store.history, entry.id, changes);
    } catch (error) {
      errorNode.textContent = Kit.t('editError.' + error.code);
      errorNode.hidden = false;
      passwordInput.focus();
      return;
    }
    mutate((list) => Core.editEntry(list, entry.id, changes), 'entrySaved', () => { editing = null; });
  }

  // 渲染编辑中的条目：明文密码框、各属性输入框、保存与取消；↩ 保存，Esc 取消。
  function renderEditor(entry) {
    const form = el('form', 'entry editing');
    const password = el('input', 'field mono entry-edit-password');
    password.type = 'text';
    password.autocomplete = 'off';
    password.spellcheck = false;
    password.maxLength = Core.VALUE_LIMIT;
    password.value = editing.password;
    password.setAttribute('aria-label', Kit.t('editPassword'));
    password.addEventListener('input', () => { editing.password = password.value; });

    const names = {};
    const grid = el('div', 'attribute-grid');
    for (const attribute of editableAttributes(entry)) {
      names[attribute.id] = attribute.name;
      const field = el('label', 'attr-field');
      const caption = el('span', 'attr-label', attribute.name);
      caption.title = attribute.name;
      const input = el('input', 'field');
      input.type = 'text';
      input.autocomplete = 'off';
      input.spellcheck = false;
      input.maxLength = Core.VALUE_LIMIT;
      input.value = editing.values[attribute.id] || '';
      input.addEventListener('input', () => { editing.values[attribute.id] = input.value; });
      field.append(caption, input);
      grid.appendChild(field);
    }

    const error = el('div', 'message error inline-error');
    error.setAttribute('role', 'alert');
    error.hidden = true;
    const cancel = el('button', 'btn small', Kit.t('cancel'));
    cancel.type = 'button';
    cancel.addEventListener('click', cancelEdit);
    const save = el('button', 'btn small primary', Kit.t('save'));
    save.type = 'submit';
    save.setAttribute('data-requires-bridge', '');
    Kit.setEnabled(save, true);
    const actions = el('div', 'row entry-actions');
    actions.append(el('span', 'spacer'), cancel, save);

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      saveEdit(entry, names, error, password);
    });
    form.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape' || event.isComposing) return;
      event.preventDefault();
      cancelEdit();
    });
    form.append(password, error, grid, actions);
    return form;
  }

  // 渲染一条历史：密码行（遮罩 / 显示、时间、复制、编辑、删除）与属性行；编辑中的条目换成表单。
  function renderEntry(entry) {
    if (editing && editing.id === entry.id) return renderEditor(entry);
    const item = el('div', 'entry');
    const main = el('div', 'entry-main');
    const shown = revealed.has(entry.id);
    const password = el('code', 'entry-password' + (shown ? '' : ' masked'), shown ? entry.password : MASK);
    const eye = iconButton(shown ? 'eyeOff' : 'eye', Kit.t(shown ? 'hide' : 'show'));
    eye.addEventListener('click', () => {
      if (shown) revealed.delete(entry.id);
      else revealed.add(entry.id);
      item.replaceWith(renderEntry(entry));
    });
    const time = el('time', 'hint entry-time', formatTime(entry.createdAt));
    time.dateTime = entry.createdAt;
    const copy = iconButton('copy', Kit.t('copy'));
    copy.setAttribute('data-requires-bridge', '');
    Kit.setEnabled(copy, true);
    copy.addEventListener('click', () => copyConcealed(entry.password));
    const edit = iconButton('edit', Kit.t('editEntry'));
    edit.setAttribute('data-requires-bridge', '');
    Kit.setEnabled(edit, true);
    edit.addEventListener('click', () => startEdit(entry));
    const remove = iconButton('trash', Kit.t('deleteEntry'));
    remove.setAttribute('data-requires-bridge', '');
    Kit.setEnabled(remove, true);
    armConfirm(remove, {
      confirmKey: 'confirmDelete',
      restore: () => remove.replaceChildren(icon('trash')),
      onConfirm: () => {
        revealed.delete(entry.id);
        mutate((list) => list.filter((other) => other.id !== entry.id), 'entryDeleted');
      },
    });
    main.append(password, eye, el('span', 'spacer'), time, copy, edit, remove);

    const meta = el('div', 'entry-meta');
    const rule = entry.rule || {};
    meta.appendChild(el('span', 'badge rule-badge', Kit.t('ruleSummary', { name: ctx.ruleName(entry), length: entry.password.length })));
    for (const [id, value] of Object.entries(entry.attributes || {})) {
      const attr = el('span', 'attr');
      attr.append(el('span', 'attr-name', ctx.attributeName(id, (entry.attributeNames || {})[id])), el('span', 'attr-value', value));
      attr.title = value;
      meta.appendChild(attr);
    }
    if (!rule.name && !Object.keys(entry.attributes || {}).length) meta.hidden = true;
    item.append(main, meta);
    return item;
  }

  // 按搜索词重绘列表、空状态与标签页上的条数。
  function render() {
    const all = Store.history;
    if (editing && !all.some((entry) => entry.id === editing.id)) editing = null;
    ui.count.textContent = all.length ? String(all.length) : '';
    ui.error.hidden = !loadError;
    if (loadError) ui.error.textContent = loadError;
    const shown = Core.filterHistory(all, ui.search.value, ctx.ruleName);
    ui.list.replaceChildren(...shown.map(renderEntry));
    ui.list.hidden = !shown.length;
    ui.empty.hidden = !!shown.length || !!loadError;
    ui.emptyText.textContent = Kit.t(all.length ? 'historyNoMatch' : 'historyEmpty');
    Kit.setEnabled(ui.clear, all.length > 0);
    if (!all.length) disarmClear();
  }

  // 读取加密历史后重绘；读失败时显示原因，不清空任何东西。
  async function load() {
    try {
      await Store.loadHistory();
      loadError = null;
    } catch (error) {
      loadError = errorText(error, 'historyLoadFailed');
    }
    render();
  }

  // 接上历史页事件；context 提供规则名与属性名的解析。
  function init(context) {
    ctx = Object.assign(ctx, context);
    ui.lock.appendChild(icon('lock'));
    ui.search.addEventListener('input', render);
    disarmClear = armConfirm(ui.clear, {
      confirmKey: 'clearConfirm',
      restore: () => { ui.clear.textContent = Kit.t('clearHistory'); },
      onArm: () => { ui.clearCancel.hidden = false; },
      onDisarm: () => { ui.clearCancel.hidden = true; },
      onConfirm: () => {
        revealed.clear();
        mutate(() => [], 'historyCleared');
      },
    });
    ui.clearCancel.addEventListener('click', () => disarmClear());
    load();
  }

  // 启动器在历史页继续输入时填进搜索框。
  function setQuery(text) {
    ui.search.value = text;
    render();
  }

  // 离开历史页时重新遮罩所有密码、丢弃未保存的编辑并复原未完成的确认。
  function hideAll() {
    revealed.clear();
    editing = null;
    disarmClear();
    render();
  }

  window.PasswordHistory = Object.freeze({ el, icon, iconButton, armConfirm, init, render, load, setQuery, hideAll, copyConcealed });
})();
