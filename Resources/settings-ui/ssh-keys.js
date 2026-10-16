(() => {
  "use strict";

  // 「主机 → 密钥」子页：私钥保险库的列表与行菜单。
  // 私钥只在原生层与钥匙串之间流动：导入用 NSOpenPanel 原生读取，生成、重命名、复制公钥、删除都只提交
  // `hosts.keys.*` 意图，网页从不接触私钥内容。由 hosts.js 以 `render(container, data, send, ui)` 调用。

  const state = { menu: null };

  /// 关闭当前行菜单。
  function closeMenu() {
    state.menu?.remove();
    state.menu = null;
  }
  document.addEventListener("click", event => { if (state.menu && !state.menu.contains(event.target)) closeMenu(); }, true);
  document.addEventListener("keydown", event => { if (event.key === "Escape" && state.menu) { event.stopPropagation(); closeMenu(); } }, true);
  window.addEventListener("resize", closeMenu);

  /// 短指纹：`SHA256:` 后取前 16 个字符，完整值放在 title 里。
  function shortFingerprint(fingerprint) {
    const text = String(fingerprint ?? "");
    if (!text.startsWith("SHA256:")) return text;
    const body = text.slice(7);
    return body.length > 16 ? `SHA256:${body.slice(0, 16)}…` : text;
  }

  /// 渲染整个子页。data 是 `snapshot.hosts`；send 返回 Promise（原生回执成功才 resolve）。
  function render(container, data, send, ui) {
    const { t, element, button } = ui;
    closeMenu();
    const keys = data.vaultKeys ?? [];
    if (data.sshEngine === "openssh") {
      container.appendChild(element("div", "message-banner", t("保险库密钥只在原生 SSH 引擎下生效；当前使用 OpenSSH 回退引擎，连接时不会用到这些密钥。")));
    }
    if (data.vaultKeysError) {
      container.appendChild(element("div", "message-banner", t("ssh-keys.json 无法读取，正在显示最后一次有效内容：{detail}", { detail: data.vaultKeysError })));
    }
    const group = element("section", "group");
    const toolbar = element("div", "hosts-toolbar");
    const importButton = button(t("导入私钥…"), "", () => runImport(importButton, send, t));
    toolbar.append(
      element("span", "hosts-toolbar-note", t("私钥只保存在钥匙串里，不能导出。")),
      importButton,
      button(t("生成新密钥…"), "primary", () => openNameDialog(ui, send, { mode: "generate" })),
    );
    const card = element("div", "card hosts-list");
    if (!keys.length) {
      const empty = element("div", "setting-row hosts-empty");
      empty.appendChild(element("span", "setting-detail", t("还没有保险库密钥。导入 ~/.ssh 里的私钥，或生成一把新的 Ed25519 密钥。")));
      card.appendChild(empty);
    }
    for (const key of keys) card.appendChild(keyRow(key, send, ui));
    group.append(toolbar, card);
    container.appendChild(group);
  }

  /// 一行密钥：名称、算法与短指纹、来源；右侧是使用情况、缺失标记与「⋯」菜单。
  function keyRow(key, send, ui) {
    const { t, element, button } = ui;
    const row = element("div", "setting-row ssh-key-row");
    row.dataset.keyId = key.id;
    const copy = element("div", "setting-copy");
    const origin = key.origin === "imported"
      ? (key.importedFrom ? t("导入自 {path}", { path: key.importedFrom }) : t("已导入"))
      : t("在 Aster 中生成");
    const detail = element("span", "setting-detail", [key.algorithm, shortFingerprint(key.fingerprint), origin].filter(Boolean).join(" · "));
    detail.title = key.fingerprint ?? "";
    copy.append(element("span", "setting-label", key.label), detail);
    const control = element("div", "setting-control");
    if (key.keychainMissing) {
      const missing = element("span", "hosts-badge danger", t("钥匙串中缺失"));
      missing.title = t("钥匙串里找不到这把私钥，连接时会跳过它。请删除后重新导入。");
      control.appendChild(missing);
    }
    const usedBy = key.usedBy ?? [];
    if (usedBy.length) {
      const badge = element("span", "hosts-badge", t("{count} 台主机使用", { count: usedBy.length }));
      badge.title = usedBy.join("、");
      control.appendChild(badge);
    }
    const more = button("⋯", "hosts-more", event => { event.stopPropagation(); openMenu(key, more, send, ui); });
    more.setAttribute("aria-label", t("更多操作"));
    more.setAttribute("aria-haspopup", "menu");
    control.appendChild(more);
    row.append(copy, control);
    return row;
  }

  // MARK: - 行菜单

  /// 打开某把密钥的「⋯」菜单；再点同一按钮关闭。
  function openMenu(key, anchor, send, ui) {
    const { t, element } = ui;
    const reopen = state.menu?.dataset.keyId === key.id;
    closeMenu();
    if (reopen) return;
    const menu = element("div", "hosts-menu");
    menu.setAttribute("role", "menu");
    menu.dataset.keyId = key.id;
    const item = (label, handler, danger = false) => {
      const entry = element("button", `hosts-menu-item${danger ? " danger" : ""}`, label);
      entry.type = "button";
      entry.setAttribute("role", "menuitem");
      entry.addEventListener("click", () => { closeMenu(); handler(); });
      menu.appendChild(entry);
    };
    const id = key.id;
    const quiet = promise => promise.catch(() => {});
    item(t("复制公钥"), () => quiet(send("hosts.keys.copyPublicKey", { id })));
    item(t("重命名…"), () => openNameDialog(ui, send, { mode: "rename", key }));
    const migratable = key.migratableHosts ?? [];
    if (migratable.length) item(t("改用保险库密钥（{count} 台主机）…", { count: migratable.length }), () => confirmMigrate(key, send, ui));
    // 原生侧会弹出自己的确认框，列出全部后果后才删除，这里不再重复确认。
    if (key.origin === "imported" && key.originalExists) item(t("删除原文件…"), () => quiet(send("hosts.keys.deleteOriginal", { id })), true);
    menu.appendChild(element("div", "hosts-menu-separator"));
    item(t("删除…"), () => confirmDelete(key, send, ui), true);
    document.body.appendChild(menu);
    const rect = anchor.getBoundingClientRect();
    const width = menu.offsetWidth;
    menu.style.left = `${Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8))}px`;
    const below = rect.bottom + 4;
    menu.style.top = `${below + menu.offsetHeight > window.innerHeight - 8 ? Math.max(8, rect.top - menu.offsetHeight - 4) : below}px`;
    state.menu = menu;
    menu.querySelector("button")?.focus();
  }

  /// 带名单的确认框；danger 决定确认按钮是否用危险样式。
  function confirmDialog(ui, { title, body, lists, button: confirmLabel, danger }, onConfirm) {
    const { t, element, button } = ui;
    const { dialog, close } = ui.makeDialog(title, body);
    for (const list of lists.filter(entry => entry.items.length)) {
      const section = element("div", "hosts-confirm-list");
      section.appendChild(element("strong", "", list.heading));
      const items = element("ul");
      for (const text of list.items) items.appendChild(element("li", "", text));
      section.appendChild(items);
      dialog.appendChild(section);
    }
    const actions = element("div", "settings-dialog-actions");
    const confirm = button(confirmLabel, danger ? "danger" : "primary", () => { onConfirm(); close(); });
    actions.append(button(t("取消"), "", close), confirm);
    dialog.appendChild(actions);
    confirm.focus();
  }

  /// 删除前列出仍在使用它的主机；删除会一并清掉这些引用和钥匙串条目。
  function confirmDelete(key, send, ui) {
    const { t } = ui;
    const usedBy = key.usedBy ?? [];
    confirmDialog(ui, {
      title: t("删除“{label}”？", { label: key.label }),
      body: t("私钥会从钥匙串删除，不能撤销。使用它的主机会去掉这把密钥。"),
      lists: [{ heading: t("使用它的主机（{count}）：", { count: usedBy.length }), items: usedBy }],
      button: t("删除"),
      danger: true,
    }, () => send("hosts.keys.delete", { id: key.id }).catch(() => {}));
  }

  /// 把仍指向原文件路径的主机改成引用这把保险库密钥。
  function confirmMigrate(key, send, ui) {
    const { t } = ui;
    const hosts = key.migratableHosts ?? [];
    confirmDialog(ui, {
      title: t("改用保险库密钥？"),
      body: t("以下主机的私钥文件 {path} 会换成保险库密钥“{label}”。", { path: key.importedFrom ?? "", label: key.label }),
      lists: [{ heading: t("将要修改的主机（{count}）：", { count: hosts.length }), items: hosts }],
      button: t("改用保险库密钥"),
      danger: false,
    }, () => send("hosts.keys.migrateReferences", { id: key.id }).catch(() => {}));
  }

  // MARK: - 导入、生成、重命名

  /// 导入走原生文件选择与 passphrase 询问；按钮在回执（或超时）前保持禁用，避免连点。
  function runImport(importButton, send, t) {
    const label = importButton.textContent;
    importButton.disabled = true;
    importButton.textContent = t("正在导入…");
    send("hosts.keys.import", {}).catch(() => {}).finally(() => {
      importButton.disabled = false;
      importButton.textContent = label;
    });
  }

  /// 名称对话框：生成新密钥（名称 + 注释）或重命名（只有名称）。提交成功后才关闭。
  function openNameDialog(ui, send, { mode, key }) {
    const { t, element, button } = ui;
    const generating = mode === "generate";
    const { dialog, close } = ui.makeDialog(
      generating ? t("生成新密钥") : t("重命名密钥"),
      generating ? t("生成一把 Ed25519 密钥，私钥只保存在钥匙串里。把公钥加到服务器的 authorized_keys 后即可使用。") : "",
    );
    const form = element("div", "hosts-form-grid");
    /// 一行「标签 + 输入框」。
    const field = (labelText, value, placeholder) => {
      const row = element("label", "hosts-field");
      row.appendChild(element("span", "hosts-field-label", labelText));
      const body = element("span", "hosts-field-body");
      const node = element("input", "control");
      node.type = "text";
      node.value = value ?? "";
      node.placeholder = placeholder;
      node.spellcheck = false;
      node.autocomplete = "off";
      body.appendChild(node);
      row.appendChild(body);
      form.appendChild(row);
      return node;
    };
    const labelInput = field(t("名称"), generating ? "" : key.label, t("例如：工作笔记本"));
    const commentInput = generating ? field(t("注释"), "", t("可选，写进公钥末尾")) : null;
    dialog.appendChild(form);
    const status = element("p", "hosts-form-error");
    status.setAttribute("role", "status");
    status.setAttribute("aria-live", "polite");
    dialog.appendChild(status);
    const actions = element("div", "settings-dialog-actions");
    const submit = button(generating ? t("生成") : t("保存"), "primary", async () => {
      const label = labelInput.value.trim();
      if (!label) { status.textContent = t("名称不能为空"); return; }
      if (submit.disabled) return;
      submit.disabled = true;
      try {
        if (generating) await send("hosts.keys.generate", { label, comment: commentInput.value.trim() });
        else await send("hosts.keys.rename", { id: key.id, label });
        close();
      } catch {
        // 原生侧已用 toast 说明原因；保留输入让用户修改。
        submit.disabled = false;
      }
    });
    for (const input of [labelInput, commentInput].filter(Boolean)) {
      input.addEventListener("keydown", event => { if (event.key === "Enter") { event.preventDefault(); submit.click(); } });
    }
    actions.append(button(t("取消"), "", close), submit);
    dialog.appendChild(actions);
    labelInput.focus();
  }

  window.AsterSSHKeys = { render, shortFingerprint };
})();
