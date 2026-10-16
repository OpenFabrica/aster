(() => {
  "use strict";

  // 「主机 → Agent 访问」子页：开关、授权、agent 终端、MCP 接入与活动记录。
  // 网页只展示快照并提交意图；授权、审计与安装都在原生层（SettingsAgentAccessBridge）。
  // 设置页每收到快照就整页重绘，所以活动记录的分页状态放在模块级，重绘不会重新请求或闪烁。

  const PAGE_SIZE = 20;
  const CONFIRM_MS = 3000;
  const AUDIT_TIMEOUT_MS = 10000;
  const CREATED = "（新建）";
  const DELETED = "（已删除）";

  const state = {
    // 活动记录：已加载的记录、下一页游标、请求状态。
    records: [],
    nextBefore: null,
    requested: false,
    loading: false,
    failed: false,
    // 当前在途请求的游标（null 表示第一页）与回复时是否替换整个列表。
    pendingBefore: null,
    replaceOnReply: false,
    timeout: null,
    // 「全部撤销」的二次确认状态。
    confirmAll: false,
    confirmTimer: null,
    // 最近一次渲染使用的上下文，供异步回复回写。
    send: null,
    t: null,
    auditCard: null,
    revokeAllButton: null,
  };

  /// 没有传入翻译函数时，按 settings.js 的同一方式自建。
  function fallbackTranslator() {
    const language = window.AsterUILanguage || "zh-Hans";
    const dictionary = (window.AsterI18n && window.AsterI18n[language]) || {};
    return (text, params) => {
      let s = dictionary[text] ?? text;
      if (params) for (const [k, v] of Object.entries(params)) s = s.split(`{${k}}`).join(String(v));
      return s;
    };
  }

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

  /// 创建一行：左侧标题与说明，右侧控件。
  function settingRow(label, detail, control) {
    const row = element("div", "setting-row");
    const copy = element("div", "setting-copy");
    copy.appendChild(element("span", "setting-label", label));
    if (detail) copy.appendChild(element("span", "setting-detail", detail));
    row.appendChild(copy);
    if (control) {
      const box = element("div", "setting-control");
      box.append(...(Array.isArray(control) ? control : [control]));
      row.appendChild(box);
    }
    return row;
  }

  /// 空状态行。
  function emptyRow(text) {
    const row = element("div", "setting-row hosts-empty");
    row.appendChild(element("span", "setting-detail", text));
    return row;
  }

  /// 创建一个带标题的分组卡片；返回 [section, card]。
  function makeGroup(title) {
    const section = element("section", "group");
    section.appendChild(element("h2", "group-title", title));
    const card = element("div", "card");
    section.appendChild(card);
    return [section, card];
  }

  // MARK: - 文案映射

  /// 授权范围的显示文案。
  function scopeLabel(scope, t) {
    const map = { always: t("一直允许"), session: t("本会话"), once: t("一次") };
    return map[scope] ?? scope ?? "";
  }

  /// agent 终端状态的显示文案。
  function stateLabel(value, t) {
    const map = { connecting: t("连接中"), ready: t("空闲"), busy: t("运行中"), needs_input: t("等待输入"), ended: t("已结束") };
    return map[value] ?? value ?? "";
  }

  /// 审计动作的显示文案。
  function actionLabel(action, t) {
    const map = {
      "exec.started": t("开始执行"), "exec.finished": t("执行完成"), "exec.pending": t("仍在运行"),
      "grant.created": t("授予授权"), "grant.revoked": t("撤销授权"), "grant.denied": t("拒绝"),
      "grant.expired": t("授权过期"), "grant.invalidated": t("授权作废"), "setting.changed": t("修改设置"),
    };
    return map[action] ?? action ?? "";
  }

  /// 命令结果状态的显示文案。
  function statusLabel(status, t) {
    const map = { completed: t("已完成"), running: t("运行中"), needs_input: t("等待输入"), interrupted: t("已中断"), ended: t("已结束") };
    return map[status] ?? status ?? "";
  }

  /// 变更字段名的显示文案；未知字段回退原名。
  function fieldLabel(field, t) {
    const map = {
      grantID: t("授权 ID"), scope: t("范围"), hostID: t("主机 ID"), hostName: t("主机"),
      targetFingerprint: t("目标指纹"), grantedAt: t("授予时间"), grantedBy: t("授予人"),
      session: t("会话"), deniedUntil: t("冷却到"), agentHostAccessEnabled: t("允许 agent 申请主机访问"),
    };
    return map[field] ?? field;
  }

  /// 变更值的显示：范围值与布尔值翻译，时间转本地格式，其余原样。
  function valueLabel(field, value, t) {
    if (field === "scope") return scopeLabel(value, t);
    if (value === "true") return t("开启");
    if (value === "false") return t("关闭");
    if (field === "grantedAt" || field === "deniedUntil") return formatTime(value);
    return value;
  }

  /// ISO 时间转本地时间文本；无法解析时原样返回。
  function formatTime(iso) {
    const date = new Date(iso);
    return Number.isNaN(date.getTime()) ? String(iso ?? "") : date.toLocaleString();
  }

  /// 毫秒时长转简短文本。
  function formatDuration(ms) {
    const value = Number(ms);
    if (!Number.isFinite(value)) return "";
    return value < 1000 ? `${Math.round(value)} ms` : `${(value / 1000).toFixed(1)} s`;
  }

  /// 过长的会话标识截断显示。
  function shortSession(value) {
    const text = String(value ?? "");
    return text.length > 12 ? `${text.slice(0, 12)}…` : text;
  }

  // MARK: - 各卡片

  /// 总开关卡片。
  function accessSection(info, send, t) {
    const [section, card] = makeGroup(t("编程 agent 访问"));
    if (!info.available) section.insertBefore(element("div", "message-banner", t("agent 主机访问尚未启动")), card);
    const label = element("label", "toggle");
    const input = element("input");
    input.type = "checkbox";
    input.checked = Boolean(info.enabled);
    input.disabled = !info.available;
    input.setAttribute("aria-label", t("允许编程 agent 申请主机访问"));
    input.addEventListener("change", () => send("hosts.setAgentAccessEnabled", { enabled: input.checked }));
    label.append(input, element("span", "toggle-track"));
    card.appendChild(settingRow(
      t("允许编程 agent 申请主机访问"),
      t("打开后，Claude Code、Codex 等 agent 可以申请在已保存的主机上执行命令。每台主机都要你批准；命令在浮动终端里执行，你能看到并随时接手。agent 拿不到口令或私钥。"),
      label,
    ));
    return section;
  }

  /// 「全部撤销」按钮：第一次点击进入确认态，3 秒内再点才执行。
  function revokeAllButton(send, t) {
    const node = button(state.confirmAll ? t("确认全部撤销") : t("全部撤销"), "danger", () => {
      if (state.confirmAll) {
        resetConfirm();
        send("hosts.revokeAllAgentGrants", {});
        return;
      }
      state.confirmAll = true;
      node.textContent = t("确认全部撤销");
      clearTimeout(state.confirmTimer);
      state.confirmTimer = setTimeout(() => {
        resetConfirm();
        if (state.revokeAllButton?.isConnected) state.revokeAllButton.textContent = t("全部撤销");
      }, CONFIRM_MS);
    });
    state.revokeAllButton = node;
    return node;
  }

  /// 清除「全部撤销」的确认态。
  function resetConfirm() {
    state.confirmAll = false;
    clearTimeout(state.confirmTimer);
    state.confirmTimer = null;
  }

  /// 已授权卡片：授权列表、逐条撤销与全部撤销。
  function grantsSection(info, send, t) {
    const [section, card] = makeGroup(t("已授权"));
    const grants = info.grants || [];
    if (grants.length) {
      const header = element("div", "agent-card-actions");
      header.appendChild(revokeAllButton(send, t));
      section.insertBefore(header, card);
    } else {
      resetConfirm();
      card.appendChild(emptyRow(t("还没有授权")));
    }
    for (const grant of grants) {
      const row = settingRow(grant.hostName, null, button(t("撤销"), "danger", () => send("hosts.revokeAgentGrant", { grantID: grant.grantID })));
      const detail = element("span", "setting-detail");
      detail.append(`${scopeLabel(grant.scope, t)} · ${formatTime(grant.grantedAt)} · ${grant.grantedBy ?? ""}`);
      if (grant.session) {
        const session = element("span", "agent-mono", ` · ${shortSession(grant.session)}`);
        session.title = grant.session;
        detail.appendChild(session);
      }
      row.querySelector(".setting-copy").appendChild(detail);
      card.appendChild(row);
    }
    return section;
  }

  /// Agent 终端卡片：每个浮动终端的状态。
  function terminalsSection(info, t) {
    const [section, card] = makeGroup(t("Agent 终端"));
    const terminals = info.terminals || [];
    if (!terminals.length) card.appendChild(emptyRow(t("没有 agent 终端")));
    for (const terminal of terminals) {
      const badges = [element("span", "hosts-badge", stateLabel(terminal.state, t))];
      if (terminal.paused) badges.push(element("span", "hosts-badge", t("已暂停")));
      const row = settingRow(`${terminal.hostName} · ${terminal.agent}`, terminal.target, badges);
      card.appendChild(row);
    }
    return section;
  }

  /// 接入 agent 卡片：把 aster mcp 注册到 Claude Code / Codex，并显示命令行工具路径。
  /// 已登记的命令会失效（App 包内路径、已不存在）时提示，按钮改成「修复」。
  function installSection(info, send, t) {
    const [section, card] = makeGroup(t("接入 agent"));
    const registrations = info.registrations || {};
    const clients = [["claude", "Claude Code"], ["codex", "Codex"]];
    const buttons = clients.map(([client, name]) => {
      const repair = registrations[client]?.status === "needsRepair";
      const label = repair ? t("修复 {name}", { name }) : t("安装到 {name}", { name });
      return button(label, repair ? "primary" : "", () => send("hosts.installAgentMCP", { client }));
    });
    const row = settingRow(t("MCP 服务"), t("把 aster mcp 注册为 Claude Code / Codex 的 MCP server（用户级）。"), buttons);
    const copy = row.querySelector(".setting-copy");
    if (info.cliPath) {
      const path = element("span", "setting-detail agent-mono", info.cliPath);
      path.title = info.cliPath;
      copy.appendChild(path);
    } else {
      copy.appendChild(element("span", "setting-warning", t("尚未安装 aster 命令；点「安装」时会一并安装，MCP 配置只写这个稳定路径")));
    }
    for (const [client, name] of clients) {
      const entry = registrations[client];
      if (entry?.status !== "needsRepair") continue;
      const warning = element("span", "setting-warning",
        t("{name} 里登记的命令会失效：{command}。点「修复」改成稳定路径，否则启动时会报错。", { name, command: entry.command || "" }));
      warning.title = entry.command || "";
      copy.appendChild(warning);
    }
    card.appendChild(row);
    return section;
  }

  // MARK: - 活动记录

  /// 请求一页审计记录；before 为空表示第一页，replace 表示回复后替换整个列表。
  function requestAudit(before, replace) {
    if (!state.send) return;
    state.requested = true;
    state.loading = true;
    state.failed = false;
    state.pendingBefore = before ?? null;
    state.replaceOnReply = replace;
    clearTimeout(state.timeout);
    // 原生层读取失败时不会回复；超时后恢复按钮，避免一直停在加载中。
    state.timeout = setTimeout(() => {
      if (!state.loading) return;
      state.loading = false;
      state.failed = true;
      refreshAudit();
    }, AUDIT_TIMEOUT_MS);
    const payload = { limit: PAGE_SIZE };
    if (before) payload.before = before;
    state.send("hosts.agentAuditPage", payload);
    refreshAudit();
  }

  /// 接收原生层返回的审计页；过期的回复（游标不匹配）直接忽略。
  function receive(message) {
    if (!message || message.type !== "agentAccessAuditPage") return;
    if ((message.before ?? null) !== state.pendingBefore || !state.loading) return;
    clearTimeout(state.timeout);
    const incoming = Array.isArray(message.records) ? message.records : [];
    state.records = state.replaceOnReply ? incoming : state.records.concat(incoming);
    state.nextBefore = message.nextBefore ?? null;
    state.loading = false;
    state.failed = false;
    refreshAudit();
  }

  /// 原地重绘活动记录卡片内容（卡片已脱离页面时只更新状态）。
  function refreshAudit() {
    if (state.auditCard?.isConnected && state.t) state.auditCard.replaceChildren(...auditRows(state.t));
  }

  /// 活动记录卡片的全部行。
  function auditRows(t) {
    const rows = state.records.map(record => recordRow(record, t));
    if (!rows.length) rows.push(emptyRow(state.loading ? t("正在载入…") : state.failed ? t("活动记录加载失败") : t("还没有活动记录")));
    const footer = element("div", "agent-audit-footer");
    if (state.nextBefore) {
      const more = button(t("加载更多"), "", () => requestAudit(state.nextBefore, false));
      more.disabled = state.loading;
      footer.appendChild(more);
    }
    if (state.failed && rows.length > 1) footer.appendChild(element("span", "setting-detail", t("活动记录加载失败")));
    if (footer.childNodes.length) rows.push(footer);
    return rows;
  }

  /// 活动记录卡片：标题行带刷新按钮，下方是分页记录与日志目录说明。
  function auditSection(info, t) {
    const [section, card] = makeGroup(t("活动记录"));
    const header = element("div", "agent-card-actions");
    const refresh = button(t("刷新"), "", () => requestAudit(null, true));
    header.appendChild(refresh);
    section.insertBefore(header, card);
    if (info.auditDirectory) {
      section.insertBefore(element("p", "group-description", t("审计日志保存在 {path}，保留 13 个月", { path: info.auditDirectory })), header);
    }
    state.auditCard = card;
    card.replaceChildren(...auditRows(t));
    return section;
  }

  /// 执行者展示：[主文本, 小字]。
  function actorParts(actor, t) {
    if (!actor) return ["", ""];
    if (actor.kind === "agent") {
      const name = actor.provider || actor.client || "agent";
      return [name, actor.session || actor.agentSessionID || ""];
    }
    if (actor.kind === "user") {
      const name = actor.name || actor.account || t("用户");
      return [name, actor.name && actor.account ? actor.account : ""];
    }
    return [t("系统"), ""];
  }

  /// 批准者展示文本。
  function approverText(approver, t) {
    if (!approver) return "";
    const base = approver.kind === "grant" ? t("授权") : t("用户批准");
    return approver.scope ? `${base} · ${scopeLabel(approver.scope, t)}` : base;
  }

  /// 结果展示文本：状态 · 退出码 · 耗时。
  function resultText(result, t) {
    if (!result) return "";
    const parts = [statusLabel(result.status, t)];
    if (result.exitCode !== undefined && result.exitCode !== null && result.exitCode !== "") parts.push(t("退出码 {code}", { code: result.exitCode }));
    const duration = formatDuration(result.durationMs);
    if (duration) parts.push(duration);
    return parts.join(" · ");
  }

  /// 单条记录行：时间、动作、详情。
  function recordRow(record, t) {
    const row = element("div", "agent-audit-row");
    row.appendChild(element("span", "agent-audit-time", formatTime(record.time)));
    row.appendChild(element("span", "agent-audit-action", actionLabel(record.action, t)));
    const body = element("div", "agent-audit-body");
    const [actor, actorSub] = actorParts(record.actor, t);
    const who = element("div", "agent-audit-line", actor);
    if (actorSub) {
      const sub = element("span", "agent-sub agent-mono", ` ${record.actor.kind === "agent" ? shortSession(actorSub) : actorSub}`);
      sub.title = actorSub;
      who.appendChild(sub);
    }
    body.appendChild(who);
    if (record.host) {
      const host = element("div", "agent-audit-line", record.host.name || "");
      if (record.host.target) host.appendChild(element("span", "agent-sub", ` ${record.host.target}`));
      body.appendChild(host);
    }
    if (record.command) {
      const line = element("div", "agent-audit-line");
      const command = element("span", "agent-command agent-mono", record.command);
      command.title = record.command;
      line.appendChild(command);
      if (record.commandRedacted === "true") line.appendChild(element("span", "hosts-badge", t("(已脱敏)")));
      body.appendChild(line);
    }
    const outcome = [resultText(record.result, t), approverText(record.approver, t)].filter(Boolean).join(" · ");
    if (outcome) body.appendChild(element("div", "agent-sub", outcome));
    if (record.reason) body.appendChild(element("div", "agent-sub", record.reason));
    if (record.changes?.length) body.appendChild(changesView(record.changes, t));
    row.appendChild(body);
    return row;
  }

  /// 变更展示：修改为「字段 原值 → 新值」，新建与删除为属性列表（删除置灰加删除线）。
  function changesView(changes, t) {
    const box = element("div", "agent-changes");
    const created = changes.filter(change => change.before === CREATED);
    const deleted = changes.filter(change => change.after === DELETED);
    const modified = changes.filter(change => change.before !== CREATED && change.after !== DELETED);
    for (const change of modified) {
      const line = element("div", "agent-change");
      line.append(
        element("span", "agent-change-field", fieldLabel(change.field, t)),
        element("span", "agent-mono", valueLabel(change.field, change.before, t)),
        element("span", "agent-change-arrow", "→"),
        element("span", "agent-mono", valueLabel(change.field, change.after, t)),
      );
      box.appendChild(line);
    }
    for (const [list, key, className] of [[created, "after", "agent-props"], [deleted, "before", "agent-props is-deleted"]]) {
      if (!list.length) continue;
      const props = element("dl", className);
      for (const change of list) {
        props.append(element("dt", "", fieldLabel(change.field, t)), element("dd", "agent-mono", valueLabel(change.field, change[key], t)));
      }
      box.appendChild(props);
    }
    return box;
  }

  // MARK: - 入口

  /// 渲染整个「Agent 访问」页到 container；ui 是宿主子标签给的 { t, … }（兼容直接传 t），缺省时自建翻译函数。
  function render(container, hostsSnapshot, rawSend, ui) {
    const translate = (typeof ui === "function" ? ui : ui?.t) || fallbackTranslator();
    const info = hostsSnapshot?.agentAccess || { available: false, enabled: false, grants: [], terminals: [] };
    // 宿主的 send 返回 Promise（原生失败或 5 s 超时会 reject）；这里不用结果，吞掉以免未处理的 rejection。
    // 失败后的状态以下一次快照为准。
    const send = (action, payload = {}) => {
      const result = rawSend(action, payload);
      if (result && typeof result.catch === "function") result.catch(() => {});
      return result;
    };
    state.send = send;
    state.t = translate;
    container.replaceChildren(
      accessSection(info, send, translate),
      grantsSection(info, send, translate),
      terminalsSection(info, translate),
      installSection(info, send, translate),
      auditSection(info, translate),
    );
    // 只在运行时可用且从未请求过时拉第一页；后续快照重绘复用已加载的记录。
    if (info.available && !state.requested) requestAudit(null, true);
  }

  window.AsterAgentAccess = { render, receive };
})();
