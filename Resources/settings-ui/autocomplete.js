// 自动补全设置的状态展示和选择性清理；数据变更仍通过原生设置桥处理。
(() => {
  "use strict";

  function relativeTime(value, now = Date.now()) {
    const time = Date.parse(value);
    if (!Number.isFinite(time)) return String(value);
    const seconds = Math.max(0, (now - time) / 1000);
    if (seconds < 60) return "just now";
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
    return `${Math.floor(seconds / 86400)}d ago`;
  }

  function statusDescription(status, t) {
    if (status.state === "running") return status.message || t("正在检查更新…");
    if (status.state === "failure") return status.message || t("更新失败");
    const parts = [];
    if (status.currentDate) parts.push(`v${status.currentDate}`);
    if (status.specCount) parts.push(t("{count} 条命令", { count: status.specCount }));
    if (status.lastCheckedAt) parts.push(t("上次检查于 {time}", { time: relativeTime(status.lastCheckedAt) }));
    return parts.join(" · ") || t("尚无数据");
  }

  // 快照和回调共用同一个绘制入口；运行中更新只替换本行，保留滚动位置与其他控件焦点。
  function updateStatus(host, status, t, send) {
    const detail = host.querySelector(".setting-detail");
    detail.textContent = statusDescription(status, t);
    detail.classList.toggle("autocomplete-error", status.state === "failure");
    detail.setAttribute("role", "status");
    const control = host.querySelector(".setting-control");
    if (status.state === "running") {
      const progress = document.createElement("div");
      progress.className = "autocomplete-progress";
      progress.setAttribute("role", "progressbar");
      progress.setAttribute("aria-label", t("更新中…"));
      progress.setAttribute("aria-valuemin", "0");
      progress.setAttribute("aria-valuemax", "1");
      const value = Math.min(1, Math.max(0, Number(status.progress) || 0));
      progress.setAttribute("aria-valuenow", String(value));
      const fill = document.createElement("div");
      fill.style.width = `${(value * 100).toFixed(1)}%`;
      progress.appendChild(fill);
      control.replaceChildren(progress);
    } else {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "action-button";
      button.textContent = t("立即更新");
      button.addEventListener("click", () => send("action", { action: "updateAutocomplete", payload: {} }));
      control.replaceChildren(button);
    }
  }

  function openClear({ t, send }) {
    const overlay = document.createElement("div");
    overlay.className = "settings-dialog-overlay autocomplete-clear-overlay";
    const dialog = document.createElement("div");
    dialog.className = "settings-dialog autocomplete-clear-dialog";
    dialog.setAttribute("role", "dialog");
    dialog.setAttribute("aria-modal", "true");
    dialog.setAttribute("aria-labelledby", "autocomplete-clear-title");
    const title = document.createElement("h2");
    title.id = "autocomplete-clear-title";
    title.textContent = t("清除自动补全数据");
    const description = document.createElement("p");
    description.textContent = t("选择要删除的内容。此操作无法撤销。");
    dialog.append(title, description);
    const choices = [
      ["history", t("命令历史"), t("你在输入时建立起来的参数频次。")],
      ["fullLines", t("完整命令行"), t("按目录记住的完整命令。")],
      ["helpProbe", t("自动识别的补全"), t("针对你用过的工具自动学到的选项和子命令。")],
      ["learnedFolder", t("目录级学习命令"), t("你用 `aster learn` 在各目录下保存的命令。")],
      ["learnedSpecs", t("学习到的命令覆盖"), t("本地提升、覆盖内置默认值的命令规格。")],
    ];
    // 每次打开都构造新选择，避免上次清理的勾选意外成为下一次的删除范围。
    const selection = Object.fromEntries(choices.map(([key]) => [key, false]));
    const confirm = document.createElement("button");
    for (const [key, label, detail] of choices) {
      const row = document.createElement("label");
      row.className = "autocomplete-clear-choice";
      const box = document.createElement("input");
      box.type = "checkbox";
      box.name = key;
      box.addEventListener("change", () => {
        selection[key] = box.checked;
        confirm.disabled = !Object.values(selection).some(Boolean);
      });
      const copy = document.createElement("span");
      const name = document.createElement("strong");
      name.textContent = label;
      const info = document.createElement("small");
      info.textContent = detail;
      copy.append(name, info);
      row.append(box, copy);
      dialog.appendChild(row);
    }
    const close = () => overlay.remove();
    const actions = document.createElement("div");
    actions.className = "settings-dialog-actions";
    const cancel = document.createElement("button");
    cancel.type = "button";
    cancel.className = "action-button";
    cancel.textContent = t("取消");
    cancel.addEventListener("click", close);
    confirm.type = "button";
    confirm.className = "action-button danger autocomplete-clear-confirm";
    confirm.textContent = t("清除");
    confirm.disabled = true;
    confirm.addEventListener("click", () => {
      if (!Object.values(selection).some(Boolean)) return;
      send("action", { action: "clearAutocomplete", payload: { ...selection } });
      close();
    });
    overlay.addEventListener("click", event => { if (event.target === overlay) close(); });
    actions.append(cancel, confirm);
    dialog.appendChild(actions);
    overlay.appendChild(dialog);
    document.body.appendChild(overlay);
  }

  function addHelp(row, text) {
    const label = row.querySelector(".setting-label");
    const host = document.createElement("span");
    host.className = "autocomplete-help";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "?";
    button.setAttribute("aria-label", text);
    const bubble = document.createElement("span");
    bubble.className = "autocomplete-help-text";
    bubble.setAttribute("role", "tooltip");
    bubble.textContent = text;
    bubble.hidden = true;
    host.addEventListener("mouseenter", () => { bubble.hidden = false; });
    host.addEventListener("mouseleave", () => { bubble.hidden = true; });
    button.addEventListener("focus", () => { bubble.hidden = false; });
    button.addEventListener("blur", () => { bubble.hidden = true; });
    button.addEventListener("click", () => { bubble.hidden = false; });
    host.append(button, bubble);
    label.appendChild(host);
  }

  function decorateGroup(host, { t, status, send, dataSync }) {
    host.classList.add("autocomplete-settings");
    const card = host.querySelector(".card");
    const rows = [...card.children];
    for (const [before, label] of [[rows[0], t("建议")], [rows[3], t("学习")]]) {
      const heading = document.createElement("h3");
      heading.className = "autocomplete-subheading";
      heading.textContent = label;
      card.insertBefore(heading, before);
    }
    addHelp(rows[0], t("候选面板中只剩一个匹配，或你已从面板里选中某个候选时，用这个键把它接受下来。选「右箭头键」时，Tab 始终交给 shell 自己的补全。"));
    addHelp(rows[3], t("既记各参数的使用频次，也记整条命令行，外加工具 --help 输出和项目 README。所有数据只保存在本机——不会上传到任何地方。"));
    addHelp(rows[4], t("只影响之后运行的命令；确实要留的，用 `aster learn '<命令>'` 显式记录。"));
    const database = card.querySelector('[data-setting-key="updateAutocomplete"]');
    updateStatus(database, status, t, send);
    const clear = card.querySelector('[data-setting-key="clearAutocomplete"]');
    if (dataSync) clear.remove();
  }

  window.AsterAutocompleteSettings = { decorateGroup, openClear, updateStatus, relativeTime };
})();
