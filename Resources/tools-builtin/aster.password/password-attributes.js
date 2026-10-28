// 密码生成工具的用途属性：默认属性（不可删）加用户自定义属性，全部选填；定义存 aster.storage，值只随历史加密保存。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.PasswordCore;
  const Store = window.PasswordStore;
  const History = window.PasswordHistory;
  const MAX_USER_ATTRIBUTES = 12;

  const byId = (id) => document.getElementById(id);
  const ui = {
    add: byId('add-attribute'),
    form: byId('attribute-form'),
    name: byId('attribute-name'),
    cancel: byId('attribute-cancel'),
    error: byId('attribute-error'),
    fields: byId('attribute-fields'),
  };
  // 用户属性定义 [{id, name}] 与当前输入值 {id: 值}；值只在内存里。
  let userAttributes = [];
  const values = {};
  // 由生成页注入：等待一次设置写入并在失败时提示。
  let persist = (promise) => promise;

  // 当前所有属性定义：默认属性在前，用户属性在后。
  function all() {
    return Core.DEFAULT_ATTRIBUTES.concat(userAttributes);
  }

  // 属性的显示名：默认属性按 id 本地化。
  function label(attribute) {
    return attribute.builtin ? Kit.t('attr.' + attribute.id) : attribute.name;
  }

  // 当前所有属性的 id 与显示名，供历史页的编辑表单使用。
  function definitions() {
    return all().map((attribute) => ({ id: attribute.id, name: label(attribute) }));
  }

  // 历史条目里属性应显示的名字：默认属性按当前语言，用户属性用现在的名字，已删除的用当时的快照。
  function entryName(id, snapshot) {
    const found = all().find((item) => item.id === id);
    return found ? label(found) : snapshot || id;
  }

  // 收集非空的属性值与名字快照，供复制时写入历史。
  function collect() {
    const attributes = {};
    const attributeNames = {};
    for (const attribute of all()) {
      const value = (values[attribute.id] || '').trim();
      if (!value) continue;
      attributes[attribute.id] = value;
      attributeNames[attribute.id] = label(attribute);
    }
    return { attributes, attributeNames };
  }

  // 重建属性输入框；保留已输入的值，用户属性带删除按钮。
  function render() {
    const fields = all().map((attribute) => {
      const field = History.el('label', 'attr-field');
      const name = label(attribute);
      const input = History.el('input', 'field');
      input.type = 'text';
      input.autocomplete = 'off';
      input.spellcheck = false;
      input.maxLength = 512;
      input.value = values[attribute.id] || '';
      input.placeholder = attribute.builtin ? Kit.t('attrPlaceholder.' + attribute.id) : '';
      input.addEventListener('input', () => { values[attribute.id] = input.value; });
      const caption = History.el('span', 'attr-label', name);
      caption.title = name;
      field.append(caption, input);
      if (!attribute.builtin) {
        field.classList.add('removable');
        const remove = History.iconButton('close', Kit.t('removeAttribute', { name }));
        remove.addEventListener('click', (event) => {
          event.preventDefault();
          removeAttribute(attribute.id);
        });
        field.appendChild(remove);
      }
      return field;
    });
    ui.fields.replaceChildren(...fields);
    Kit.setEnabled(ui.add, userAttributes.length < MAX_USER_ATTRIBUTES);
    ui.add.title = userAttributes.length >= MAX_USER_ATTRIBUTES ? Kit.t('tooManyAttributes', { max: MAX_USER_ATTRIBUTES }) : '';
  }

  // 打开「添加属性」表单。
  function openForm() {
    ui.add.hidden = true;
    ui.form.hidden = false;
    ui.name.value = '';
    ui.error.hidden = true;
    ui.name.focus();
  }

  // 收起「添加属性」表单。
  function closeForm() {
    ui.form.hidden = true;
    ui.add.hidden = false;
    ui.error.hidden = true;
  }

  // 新增一个用户属性（只要名字），不能和已有属性重名。
  function addAttribute() {
    let name;
    try {
      name = Core.checkName(ui.name.value, all().map(label));
    } catch (error) {
      ui.error.textContent = Kit.t('nameError.' + error.code, { max: Core.NAME_LIMIT });
      ui.error.hidden = false;
      ui.name.focus();
      return;
    }
    userAttributes = userAttributes.concat({ id: 'c' + Core.makeId(), name });
    closeForm();
    render();
    persist(Store.saveAttributes(userAttributes));
  }

  // 删除一个用户属性定义；历史里的旧值仍按当时的名字显示。
  function removeAttribute(id) {
    userAttributes = userAttributes.filter((item) => item.id !== id);
    delete values[id];
    render();
    persist(Store.saveAttributes(userAttributes));
  }

  // 换上从存储读到的用户属性定义并重绘。
  function setUserAttributes(list) {
    userAttributes = list.slice();
    render();
  }

  // 接上按钮与表单事件。
  function init(options) {
    if (options && options.persist) persist = options.persist;
    ui.add.addEventListener('click', openForm);
    ui.cancel.addEventListener('click', closeForm);
    ui.form.addEventListener('submit', (event) => {
      event.preventDefault();
      addAttribute();
    });
    render();
  }

  window.PasswordAttributes = Object.freeze({ init, render, setUserAttributes, collect, entryName, definitions, closeForm });
})();
