(() => {
  "use strict";

  // 「主机 → 已知主机」：按文件分组列出 known_hosts 记录，可删除整行或行里的单个主机。
  // 由「主机」页的子标签调用 `window.AsterKnownHosts.render(container, hostsSnapshot, send)`，
  // `send(action, payload)` 提交一个桥接动作。解析与改写都在 aster-ssh（经 SettingsKnownHostsBridge），
  // 这里只展示并提交结构化意图；删除只针对原生列表里标了 `removable` 的记录。

  const uiLanguage = window.AsterUILanguage || "zh-Hans";
  const dictionary = (window.AsterI18n && window.AsterI18n[uiLanguage]) || {};
  // 与 settings.js 相同的查表规则：缺译回退原文，`{name}` 由 params 填充。
  const t = (text, params) => { let s = dictionary[text] ?? text; if (params) for (const [k, v] of Object.entries(params)) s = s.split(`{${k}}`).join(String(v)); return s; };

  // 跨快照保留的页面状态：搜索词、展开确认的记录、是否已自动请求过首次加载。
  const state = { query: "", confirm: null, requested: false };

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

  /// `{host, port}` 的显示文本：22 端口省略，其它端口写成 `[host]:port`。
  function endpointText(endpoint) {
    return endpoint.port === 22 ? endpoint.host : `[${endpoint.host}]:${endpoint.port}`;
  }

  /// 记录的唯一键；行号与摘要一起用，列表刷新后旧的确认面板自然失效。
  function entryKey(entry) {
    return `${entry.file}:${entry.line}:${entry.lineDigest}`;
  }

  /// 一条记录覆盖的主机说明：明文模式原样列出，hashed 记录只能靠匹配到的已保存主机显示名称。
  function coveredText(entry) {
    const described = entry.matches.map((endpoint, index) => {
      const names = entry.names?.[index] ?? [];
      return names.length ? `${names.join("、")}（${endpointText(endpoint)}）` : endpointText(endpoint);
    });
    if (entry.hashed) {
      const plain = entry.hosts.filter(host => host !== "(hashed)");
      const text = [t("（已哈希）"), ...plain].join(", ");
      return described.length ? `${text} — ${t("匹配：{hosts}", { hosts: described.join("、") })}` : text;
    }
    // 明文模式本身就写出了主机，只在有已保存主机名可补充时追加。
    const named = described.filter((_, index) => entry.names?.[index]?.length);
    return named.length ? `${entry.hosts.join(", ")} — ${named.join("、")}` : entry.hosts.join(", ");
  }

  /// 搜索按主机模式、匹配到的主机名、算法与指纹过滤（不区分大小写）。
  function matches(entry, query) {
    if (!query) return true;
    const names = (entry.names ?? []).flat();
    return [...entry.hosts, ...names, ...entry.matches.map(endpointText), entry.algorithm, entry.fingerprint, entry.comment ?? ""]
      .some(value => String(value).toLocaleLowerCase().includes(query));
  }

  // MARK: - 页面

  /// 渲染「已知主机」页。首次显示且尚未加载时自动请求一次列表。
  function render(container, hostsSnapshot, send) {
    const data = hostsSnapshot?.knownHosts ?? { state: "idle" };
    if (data.state === "idle" && !state.requested) {
      state.requested = true;
      send("hosts.knownHosts.refresh", {});
    }
    const loading = data.state === "loading" || (data.state === "idle" && state.requested);

    const toolbar = element("div", "hosts-toolbar");
    const search = element("input", "control hosts-search known-hosts-search");
    search.type = "search";
    search.placeholder = t("按主机、指纹或算法搜索");
    search.setAttribute("aria-label", t("搜索已知主机"));
    search.value = state.query;
    const reload = button(loading ? t("正在读取…") : t("重新加载"), "", () => send("hosts.knownHosts.refresh", {}));
    reload.disabled = loading;
    toolbar.append(search, reload);

    const list = element("div", "known-hosts-list");
    const renderList = () => list.replaceChildren(...fileSections(data, send, renderList));
    search.addEventListener("input", () => { state.query = search.value; renderList(); });
    renderList();

    // 快照重绘会换掉搜索框；替换之前记下用户是否正在输入，之后把焦点还给新的输入框。
    const typing = document.activeElement?.classList.contains("known-hosts-search");
    const nodes = [toolbar];
    if (data.state === "error") nodes.push(element("div", "message-banner", t("无法读取 known_hosts：{detail}", { detail: data.error ?? "" })));
    nodes.push(element("p", "hosts-field-hint", t("连接时校验主机密钥用的记录。删除后，下次连接会重新询问是否信任这台主机。")));
    nodes.push(list);
    container.replaceChildren(...nodes);
    if (typing) {
      const caret = search.value.length;
      window.requestAnimationFrame(() => { search.focus(); search.setSelectionRange(caret, caret); });
    }
  }

  /// 按文件分组的列表；文件顺序与 aster-ssh 输出一致（默认文件在前，系统级在后）。
  function fileSections(data, send, renderList) {
    const files = data.files ?? [];
    if (!files.length) return data.state === "loaded" ? [emptyCard(t("没有可列出的 known_hosts 文件。"))] : [];
    const query = state.query.trim().toLocaleLowerCase();
    const entries = data.entries ?? [];
    return files.map(file => {
      const own = entries.filter(entry => entry.file === file.rawPath);
      const visible = own.filter(entry => matches(entry, query));
      const skipped = (data.skipped ?? []).filter(item => item.file === file.rawPath);
      const section = element("section", "group known-hosts-file");
      section.appendChild(fileHeader(file, own.length));
      const card = element("div", "card hosts-list");
      if (file.error) card.appendChild(emptyRow(t("无法读取：{detail}", { detail: file.error })));
      else if (!file.exists) card.appendChild(emptyRow(t("文件不存在")));
      else if (!own.length) card.appendChild(emptyRow(t("没有记录")));
      else if (!visible.length) card.appendChild(emptyRow(t("没有匹配“{query}”的记录", { query: state.query.trim() })));
      for (const entry of visible) card.appendChild(entryRow(entry, send, renderList));
      if (skipped.length) {
        const note = emptyRow(t("{count} 行无法解析，已跳过（第 {lines} 行）", { count: skipped.length, lines: skipped.map(item => item.line).join("、") }));
        note.classList.add("known-hosts-skipped");
        card.appendChild(note);
      }
      section.appendChild(card);
      return section;
    });
  }

  /// 文件标题：路径、记录数与只读 / 系统级徽章。
  function fileHeader(file, count) {
    const header = element("div", "known-hosts-file-header");
    header.append(element("span", "known-hosts-path", file.path), element("span", "hosts-group-count", `· ${count}`));
    if (file.global) header.appendChild(element("span", "hosts-badge", t("系统级 · 只读")));
    else if (file.exists && !file.writable) header.appendChild(element("span", "hosts-badge", t("只读")));
    return header;
  }

  function emptyCard(text) {
    const card = element("div", "card hosts-list");
    card.appendChild(emptyRow(text));
    return card;
  }

  function emptyRow(text) {
    const row = element("div", "setting-row hosts-empty");
    row.appendChild(element("span", "setting-detail", text));
    return row;
  }

  /// 一条记录：覆盖的主机、算法与指纹、标记徽章；可写文件里的记录带删除入口。
  function entryRow(entry, send, renderList) {
    const wrapper = element("div", "known-hosts-entry");
    const row = element("div", "setting-row hosts-row known-hosts-row");
    const copy = element("div", "setting-copy");
    const label = element("span", "setting-label", coveredText(entry));
    label.title = label.textContent;
    const detail = [entry.algorithm, entry.fingerprint, t("第 {line} 行", { line: entry.line })];
    if (entry.comment) detail.push(entry.comment);
    copy.append(label, element("span", "setting-detail known-hosts-fingerprint", detail.join(" · ")));
    const control = element("div", "setting-control");
    if (entry.marker === "revoked") control.appendChild(element("span", "hosts-badge known-hosts-revoked", t("已吊销")));
    if (entry.marker === "certAuthority") control.appendChild(element("span", "hosts-badge", t("证书颁发机构")));
    if (entry.removable) {
      const open = state.confirm === entryKey(entry);
      const remove = button(t("删除…"), "", () => { state.confirm = open ? null : entryKey(entry); renderList(); });
      remove.setAttribute("aria-expanded", String(open));
      control.appendChild(remove);
    }
    row.append(copy, control);
    wrapper.appendChild(row);
    if (entry.removable && state.confirm === entryKey(entry)) wrapper.appendChild(confirmPanel(entry, send, renderList));
    return wrapper;
  }

  /// 行内删除确认：列出这一行覆盖的全部主机；多主机行还可以只删其中一台。
  function confirmPanel(entry, send, renderList) {
    const panel = element("div", "known-hosts-confirm");
    const plain = entry.hosts.filter(host => host !== "(hashed)" && !host.startsWith("!"));
    const covered = entry.hashed ? entry.matches.map(endpointText) : plain;
    const multiple = entry.hosts.length > 1;
    panel.appendChild(element("p", "", multiple
      ? t("这一行同时覆盖多台主机。删除整行后，它们下次连接都要重新确认主机密钥。")
      : t("删除后，下次连接这台主机时会重新询问是否信任它的密钥。")));
    if (covered.length) {
      const list = element("ul");
      for (const host of covered) list.appendChild(element("li", "", host));
      panel.appendChild(list);
    }
    const actions = element("div", "settings-dialog-actions");
    actions.appendChild(button(t("取消"), "", () => { state.confirm = null; renderList(); }));
    // 只删单个主机只对多模式行有意义；单模式行删掉唯一模式等于删整行。
    if (multiple) {
      for (const endpoint of entry.matches) {
        actions.appendChild(button(t("只删除 {host}", { host: endpointText(endpoint) }), "", () => submit(entry, endpoint, send)));
      }
    }
    const removeLine = button(t("删除整行"), "danger", () => submit(entry, null, send));
    actions.appendChild(removeLine);
    panel.appendChild(actions);
    window.requestAnimationFrame(() => removeLine.focus());
    return panel;
  }

  /// 提交删除。结果由原生 toast 说明，列表随后由原生重新加载并推送。
  function submit(entry, host, send) {
    state.confirm = null;
    const payload = { file: entry.file, line: entry.line, lineDigest: entry.lineDigest };
    if (host) payload.host = { host: host.host, port: host.port };
    send("hosts.knownHosts.remove", payload);
  }

  window.AsterKnownHosts = { render };
})();
