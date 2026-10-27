(() => {
  "use strict";

  // 「工具」分类的插件管理部分：已安装插件、扫描问题与开发目录。页顶「工具面板」一组
  // （打开按钮与全局快捷键）是 settings.js 的普通行，走普通 set 管线，不在这里画。
  // 网页只展示快照并提交意图；启用、授权、安装与卸载都在原生层（SettingsToolsBridge）。
  // 设置页每收到快照就整页重绘，本模块因此不保存任何状态。

  // MARK: - DOM 辅助

  /// 创建带类名与文本的元素。
  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  /// 创建操作按钮（沿用 action-button 样式）。
  function button(label, className, onClick) {
    const node = element("button", `action-button${className ? ` ${className}` : ""}`, label);
    node.type = "button";
    node.addEventListener("click", onClick);
    return node;
  }

  /// 一行：左侧标题与说明，右侧控件；entry.key 写进 data-setting-key，供搜索结果定位高亮。
  function settingRow(entry, control) {
    const row = element("div", "setting-row");
    row.dataset.settingKey = entry.key;
    const copy = element("div", "setting-copy");
    copy.appendChild(element("span", "setting-label", entry.label));
    copy.appendChild(element("span", "setting-detail", entry.detail));
    const box = element("div", "setting-control");
    box.appendChild(control);
    row.append(copy, box);
    return row;
  }

  /// 空状态行。
  function emptyRow(text) {
    const row = element("div", "setting-row tools-empty");
    row.appendChild(element("span", "setting-detail", text));
    return row;
  }

  /// 可选中复制的路径文本（等宽、长路径可断行）。
  function pathText(path, className = "") {
    const node = element("span", `tool-path${className ? ` ${className}` : ""}`, path);
    node.title = path;
    return node;
  }

  /// 带标题（与可选说明）的分组卡片；返回 [section, card]。
  function makeGroup(title, description) {
    const section = element("section", "group");
    section.appendChild(element("h2", "group-title", title));
    if (description) section.appendChild(element("p", "group-description", description));
    const card = element("div", "card");
    section.appendChild(card);
    return [section, card];
  }

  // MARK: - 搜索条目

  /// 本页由这里画出的可定位条目。settings.js 把它们并入全局搜索；key 与行上的 data-setting-key 一致。
  function searchEntries(t) {
    return [
      { key: "tools.plugins", label: t("已安装的插件"), detail: t("启用或停用插件，确认权限，在 Finder 中显示或卸载") },
      { key: "tools.openPluginsFolder", label: t("插件目录"), detail: t("安装的插件放在这里；也可以把含 aster-plugin.json 的文件夹直接拖进来，再点「重新扫描」") },
      { key: "tools.installFromFolder", label: t("从文件夹安装"), detail: t("选一个含 aster-plugin.json 的文件夹，确认权限后复制到插件目录") },
      { key: "tools.addDevelopmentFolder", label: t("开发目录"), detail: t("只登记路径、不复制文件；文件改动后自动重新加载，适合边写边试") },
      { key: "tools.reload", label: t("重新扫描"), detail: t("重新读取插件目录与开发目录") },
    ];
  }

  // MARK: - 文案映射

  /// 来源徽章文案。
  function sourceLabel(source, t) {
    const map = { builtin: t("内置"), user: t("已安装"), development: t("开发中") };
    return map[source] ?? source ?? "";
  }

  /// 运行状态文案。
  function statusLabel(status, t) {
    const map = { ready: t("可用"), disabled: t("已停用"), needsApproval: t("需要确认") };
    return map[status] ?? status ?? "";
  }

  /// 需要确认的原因文案；未知原因返回空串。
  function reasonLabel(reason, t) {
    const map = {
      firstRun: t("首次运行"), filesChanged: t("文件已变化"),
      permissionsAdded: t("新增权限"), networkDomainsAdded: t("新增网络域名"),
    };
    return map[reason] ?? "";
  }

  /// 权限风险等级文案。
  function riskLabel(risk, t) {
    const map = { high: t("高风险"), medium: t("中风险"), low: t("低风险") };
    return map[risk] ?? risk ?? "";
  }

  // MARK: - 插件卡片

  /// 启用开关；改动直接发给原生层，状态以下一次快照为准。
  function enableToggle(plugin, send, t) {
    const label = element("label", "toggle");
    const input = element("input");
    input.type = "checkbox";
    input.checked = Boolean(plugin.enabled);
    input.setAttribute("aria-label", t("启用「{name}」", { name: plugin.name }));
    input.addEventListener("change", () => send("tools.setEnabled", { id: plugin.id, enabled: input.checked }));
    label.append(input, element("span", "toggle-track"));
    const control = element("div", "setting-control");
    control.appendChild(label);
    return control;
  }

  /// 待确认提示：原因 + 「确认权限…」（原生弹出权限确认，同意后才能运行）。
  function approvalRow(plugin, send, t) {
    const row = element("div", "tool-approval");
    const reason = reasonLabel(plugin.statusReason, t);
    row.appendChild(element("span", "setting-warning", reason ? t("运行前需要确认：{reason}", { reason }) : t("运行前需要确认")));
    row.appendChild(button(t("确认权限…"), "primary", () => send("tools.approve", { id: plugin.id })));
    return row;
  }

  /// 一行「标签：内容」，用于权限与网络域名。
  function facet(label, content) {
    const row = element("div", "tool-facet");
    row.append(element("span", "tool-facet-label", label), content);
    return row;
  }

  /// 权限列表：按风险着色（高红、中橙、低灰），并标出是否已允许。快照里已按风险从高到低排好。
  function permissionList(permissions, t) {
    const list = element("ul", "tool-permissions");
    for (const permission of permissions) {
      const granted = permission.granted === true;
      const state = granted ? t("已允许") : t("未允许");
      const item = element("li", "tool-permission");
      item.dataset.risk = permission.risk;
      item.dataset.granted = String(granted);
      // 颜色之外再给一份文字说明，色弱用户与读屏也能分辨风险等级。
      item.title = `${riskLabel(permission.risk, t)} · ${permission.id}`;
      item.setAttribute("aria-label", `${permission.title} · ${riskLabel(permission.risk, t)} · ${state}`);
      const dot = element("i", "tool-risk-dot");
      dot.setAttribute("aria-hidden", "true");
      item.append(dot, element("span", "", permission.title), element("span", "tool-permission-state", state));
      list.appendChild(item);
    }
    return list;
  }

  /// 网络域名：插件只能经原生代发访问这些主机。
  function domainList(domains) {
    const list = element("span", "tool-domains");
    for (const domain of domains) list.appendChild(element("span", "tool-domain", domain));
    return list;
  }

  /// 插件操作。内置原生工具没有目录，不显示「在 Finder 中显示」；用户安装的插件可以卸载（原生先确认）；
  /// 开发中的插件只能移除登记，源码目录不动——且只在路径与登记值完全一致时给出这个按钮。
  function pluginActions(plugin, info, send, t) {
    const actions = element("div", "tool-plugin-actions");
    if (plugin.directory) {
      actions.appendChild(button(t("在 Finder 中显示"), "", () => send("tools.reveal", { id: plugin.id })));
    }
    if (plugin.source === "user" && plugin.removable) {
      actions.appendChild(button(t("卸载…"), "danger", () => send("tools.uninstall", { id: plugin.id })));
    }
    const folders = Array.isArray(info.developmentFolders) ? info.developmentFolders : [];
    if (plugin.source === "development" && folders.includes(plugin.directory)) {
      actions.appendChild(button(t("移除开发目录"), "", () => send("tools.removeDevelopmentFolder", { path: plugin.directory })));
    }
    return actions;
  }

  /// 一个插件：标题行（名称、版本、来源、启用开关）、说明、状态、待确认原因、权限、网络域名与操作。
  function pluginCard(plugin, info, send, t) {
    const card = element("div", "tool-plugin");
    card.dataset.pluginId = plugin.id;
    card.dataset.status = plugin.status;

    const head = element("div", "tool-plugin-head");
    const copy = element("div", "tool-plugin-copy");
    const title = element("div", "tool-plugin-title");
    const badge = element("span", "tool-badge", sourceLabel(plugin.source, t));
    badge.dataset.source = plugin.source;
    title.append(element("span", "tool-plugin-name", plugin.name), element("span", "tool-plugin-version", plugin.version), badge);
    copy.appendChild(title);
    if (plugin.description) copy.appendChild(element("span", "setting-detail", plugin.description));
    const meta = element("span", "tool-plugin-meta", `${plugin.id} · ${t("{count} 个功能", { count: plugin.featureCount ?? 0 })} · `);
    const status = element("span", "tool-status", statusLabel(plugin.status, t));
    status.dataset.status = plugin.status;
    meta.appendChild(status);
    copy.appendChild(meta);
    head.append(copy, enableToggle(plugin, send, t));
    card.appendChild(head);

    if (plugin.status === "needsApproval") card.appendChild(approvalRow(plugin, send, t));
    const permissions = Array.isArray(plugin.permissions) ? plugin.permissions : [];
    if (permissions.length) card.appendChild(facet(t("权限"), permissionList(permissions, t)));
    const domains = Array.isArray(plugin.networkDomains) ? plugin.networkDomains : [];
    if (domains.length) card.appendChild(facet(t("网络域名"), domainList(domains)));
    const actions = pluginActions(plugin, info, send, t);
    if (actions.childNodes.length) card.appendChild(actions);
    return card;
  }

  // MARK: - 分组

  /// 「已安装」：每个插件一张卡；除内置外没有插件时，在最前面给一句引导。
  function installedSection(info, entry, send, t) {
    const [section, card] = makeGroup(t("已安装"), entry.detail);
    section.dataset.settingKey = entry.key;
    const plugins = Array.isArray(info.plugins) ? info.plugins : [];
    if (!plugins.some(plugin => plugin.source !== "builtin")) {
      card.appendChild(emptyRow(t("还没有安装插件。把含 aster-plugin.json 的文件夹拖进插件目录，或在下方「开发」里点「从文件夹安装…」；写法见帮助文档「编写 Aster 工具插件」。")));
    }
    for (const plugin of plugins) card.appendChild(pluginCard(plugin, info, send, t));
    return section;
  }

  /// 「问题」：扫描时没能加载的文件夹（清单无效、id 冲突等）；没有问题时整组不显示。
  function issuesSection(info, t) {
    const issues = Array.isArray(info.issues) ? info.issues : [];
    if (!issues.length) return null;
    const [section, card] = makeGroup(t("问题"), t("这些文件夹没有加载；修好后点「重新扫描」。"));
    for (const issue of issues) {
      const row = element("div", "setting-row tool-issue");
      const copy = element("div", "setting-copy");
      copy.append(pathText(issue.path, "setting-label"), element("span", "setting-detail", issue.message));
      row.appendChild(copy);
      card.appendChild(row);
    }
    return section;
  }

  /// 「开发」：插件目录、从文件夹安装、开发目录列表（可移除）与重新扫描。
  function developmentSection(info, entries, send, t) {
    const [section, card] = makeGroup(t("开发"));
    const folderRow = settingRow(entries["tools.openPluginsFolder"], button(t("打开插件目录"), "", () => send("tools.openPluginsFolder")));
    if (info.pluginsDirectory) folderRow.querySelector(".setting-copy").appendChild(pathText(info.pluginsDirectory, "setting-detail"));
    card.appendChild(folderRow);
    card.appendChild(settingRow(entries["tools.installFromFolder"], button(t("从文件夹安装…"), "", () => send("tools.installFromFolder"))));
    card.appendChild(settingRow(entries["tools.addDevelopmentFolder"], button(t("添加开发目录…"), "", () => send("tools.addDevelopmentFolder"))));
    const folders = Array.isArray(info.developmentFolders) ? info.developmentFolders : [];
    if (!folders.length) card.appendChild(emptyRow(t("还没有登记开发目录")));
    for (const folder of folders) {
      const row = element("div", "setting-row tool-dev-folder");
      const copy = element("div", "setting-copy");
      copy.appendChild(pathText(folder));
      const control = element("div", "setting-control");
      control.appendChild(button(t("移除"), "", () => send("tools.removeDevelopmentFolder", { path: folder })));
      row.append(copy, control);
      card.appendChild(row);
    }
    card.appendChild(settingRow(entries["tools.reload"], button(t("重新扫描"), "", () => send("tools.reload"))));
    return section;
  }

  // MARK: - 入口

  /// 渲染「工具」分类的插件管理部分，返回 DocumentFragment。ctx 由 settings.js 提供：
  /// { t, data, mutate }，data 是快照里的 tools 对象（缺失时按空列表画）。
  function render(ctx) {
    const { t } = ctx;
    const info = ctx.data || {};
    // 宿主的 mutate 返回 Promise（原生失败或 5 秒没有回执会 reject）。这里不用结果：失败原因
    // 原生侧已经 toast 过，确认框也可能开很久，页面状态一律以下一次快照为准。
    const send = (action, payload = {}) => {
      const result = ctx.mutate("action", { action, payload });
      if (result && typeof result.catch === "function") result.catch(() => {});
      return result;
    };
    const entries = Object.fromEntries(searchEntries(t).map(entry => [entry.key, entry]));
    const page = document.createDocumentFragment();
    page.appendChild(installedSection(info, entries["tools.plugins"], send, t));
    const issues = issuesSection(info, t);
    if (issues) page.appendChild(issues);
    page.appendChild(developmentSection(info, entries, send, t));
    return page;
  }

  window.AsterTools = { render, searchEntries };
})();
