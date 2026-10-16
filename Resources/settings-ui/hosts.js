(() => {
  "use strict";

  // 「主机」分类：现在只承载「Agent 访问」。主机列表、密钥与已知主机已移到侧栏原生「主机」页，
  // 这里只留一条指引和跳转按钮，下面交给 agent-access.js 渲染。

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(label, className, onClick) {
    const node = element("button", `action-button${className ? ` ${className}` : ""}`, label);
    node.type = "button";
    node.addEventListener("click", onClick);
    return node;
  }

  /// 渲染「主机」分类：顶部迁移指引（带「打开主机页」按钮）+ Agent 访问内容。ctx 由 settings.js 提供。
  function render(ctx) {
    const { t } = ctx;
    const page = element("div", "hosts-page");

    const note = element("div", "setting-row hosts-moved-note");
    const copy = element("div", "setting-copy");
    copy.appendChild(element("span", "setting-detail", t("主机、密钥与已知主机已移到侧栏「主机」页。")));
    const control = element("div", "setting-control");
    // 失败原因由原生 toast 说明；这里不关心结果，吞掉 reject 以免未处理的 rejection。
    control.appendChild(button(t("打开主机页"), "", () => {
      ctx.mutate("action", { action: "hosts.openHostsPage", payload: {} }).catch(() => {});
    }));
    note.append(copy, control);
    page.appendChild(element("div", "card")).appendChild(note);

    // 子页容器沿用 agent-access.js 的契约：render(container, hostsSnapshot, send, ui)。
    const container = element("div", "hosts-subpage");
    const send = (action, payload = {}) => ctx.mutate("action", { action, payload });
    const ui = { t, makeDialog: ctx.makeDialog, showToast: ctx.showToast, element, button };
    const module = window.AsterAgentAccess;
    if (module && typeof module.render === "function") module.render(container, ctx.data, send, ui);
    else container.appendChild(element("div", "card")).appendChild(element("div", "setting-row hosts-empty")).appendChild(element("span", "setting-detail", t("这一页暂不可用。")));
    page.appendChild(container);
    return page;
  }

  window.AsterHosts = { render };
})();
