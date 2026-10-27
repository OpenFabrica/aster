// JWT 解析工具的界面逻辑：解码 header / payload，显示有效状态与时间声明，复制或预填 payload。不验证签名。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.JwtCore;
  const byId = (id) => document.getElementById(id);
  const ui = {
    token: byId('token'),
    state: byId('state'),
    stateDetail: byId('state-detail'),
    copy: byId('copy-payload'),
    insert: byId('insert-payload'),
    error: byId('error'),
    empty: byId('empty'),
    sample: byId('sample'),
    result: byId('result'),
    payload: byId('payload'),
    payloadNote: byId('payload-note'),
    times: byId('times'),
    header: byId('header'),
    meta: byId('meta'),
    signatureCard: byId('signature-card'),
    signature: byId('signature'),
  };
  // 相对时间的单位，从大到小；月和年按 30 天、365 天近似，足够表达「多久以后过期」。
  const UNITS = [['year', 31536e6], ['month', 2592e6], ['day', 864e5], ['hour', 36e5], ['minute', 6e4], ['second', 1e3]];
  // 最近一次成功解码的结果；输入为空或无效时为 null。
  let decoded = null;

  // 创建元素并设置类名与文字。
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // 输入框随内容在 2–5 行之间增高，短令牌不占地方，长令牌不用滚动太多。
  function fitTokenHeight() {
    ui.token.style.height = 'auto';
    ui.token.style.height = Math.min(Math.max(ui.token.scrollHeight + 1, 48), 104) + 'px';
  }

  // 按输入框内容重新解码并刷新界面。
  function update() {
    fitTokenHeight();
    decoded = null;
    ui.error.hidden = true;
    ui.token.classList.remove('invalid');
    if (!ui.token.value.trim()) {
      showEmpty();
      return;
    }
    try {
      decoded = Core.decodeJwt(ui.token.value);
    } catch (error) {
      showError(error);
      return;
    }
    showDecoded();
  }

  // 没有输入：显示提示与示例按钮。
  function showEmpty() {
    ui.empty.hidden = false;
    ui.result.hidden = true;
    ui.state.hidden = true;
    ui.stateDetail.textContent = '';
    setActionsEnabled(false);
  }

  // 解码失败：标红输入框并说明原因。
  function showError(error) {
    ui.empty.hidden = true;
    ui.result.hidden = true;
    ui.state.hidden = true;
    ui.stateDetail.textContent = '';
    ui.token.classList.add('invalid');
    ui.error.textContent = errorText(error);
    ui.error.hidden = false;
    setActionsEnabled(false);
  }

  // JwtError 转成当前语言的说明；其它异常（理论上不会出现）显示原文。
  function errorText(error) {
    if (!(error instanceof Core.JwtError)) return String((error && error.message) || error);
    const info = error.info || {};
    return Kit.t('err.' + error.reason, { count: info.count, part: info.part ? Kit.t('part.' + info.part) : '' });
  }

  // 解码成功：渲染 header、payload、签名与状态。
  function showDecoded() {
    ui.empty.hidden = true;
    ui.result.hidden = false;
    renderJson(ui.header, decoded.header);
    ui.meta.textContent = headerSummary(decoded.header);
    ui.payloadNote.textContent = '';
    if (decoded.kind === 'jwe') {
      ui.payload.classList.add('note');
      ui.payload.textContent = Kit.t('jweNote');
      ui.signatureCard.hidden = true;
    } else {
      ui.payload.classList.remove('note');
      if (decoded.payloadIsJson) {
        renderJson(ui.payload, decoded.payload);
      } else {
        ui.payload.textContent = decoded.payloadText;
        ui.payloadNote.textContent = Kit.t('payloadNotJson');
      }
      ui.signatureCard.hidden = false;
      ui.signature.textContent = decoded.signature || Kit.t('noSignature');
      ui.signature.classList.toggle('missing', !decoded.signature);
    }
    renderState();
    setActionsEnabled(decoded.kind === 'jws');
  }

  // header 里常看的几个字段，显示在 Header 标题旁。
  function headerSummary(header) {
    return ['alg', 'enc', 'typ', 'kid']
      .filter((key) => typeof header[key] === 'string' || typeof header[key] === 'number')
      .map((key) => key + ': ' + header[key])
      .join(' · ');
  }

  // 刷新状态徽标与时间列表；相对时间会随时间变化，所以也由定时器调用。
  function renderState() {
    if (!decoded) return;
    const now = Date.now();
    if (decoded.kind === 'jwe') {
      setBadge('state.jwe', 'accent');
      ui.stateDetail.textContent = '';
      renderTimes(null, now);
      return;
    }
    const payload = decoded.payloadIsJson ? decoded.payload : null;
    const state = Core.tokenState(payload, now);
    setBadge('state.' + state, { valid: 'ok', expired: 'danger', notYetValid: 'warn', noExpiry: '' }[state]);
    ui.stateDetail.textContent = stateDetail(state, payload, now);
    renderTimes(payload, now);
  }

  // 显示状态徽标。
  function setBadge(key, tone) {
    ui.state.hidden = false;
    ui.state.className = 'badge' + (tone ? ' ' + tone : '');
    ui.state.textContent = Kit.t(key);
  }

  // 徽标旁的一句话：多久后过期、过期多久了、多久后生效。
  function stateDetail(state, payload, now) {
    if (state === 'valid' || state === 'expired') {
      const exp = Core.timeClaim(payload, 'exp');
      return Kit.t(state === 'valid' ? 'expiresIn' : 'expiredAgo', { relative: relativeTime(exp.millis, now) });
    }
    if (state === 'notYetValid') {
      const nbf = Core.timeClaim(payload, 'nbf');
      return Kit.t('validFrom', { relative: relativeTime(nbf.millis, now) });
    }
    return '';
  }

  // 列出 exp / iat / nbf：本地时间（带时区）、相对时间与原始数值。
  function renderTimes(payload, now) {
    ui.times.textContent = '';
    const claims = ['exp', 'iat', 'nbf'].map((name) => Core.timeClaim(payload, name)).filter(Boolean);
    if (!claims.length) {
      ui.times.append(el('div', 'hint', Kit.t('noTimes')));
      return;
    }
    for (const claim of claims) {
      const label = el('div', 'time-label');
      label.append(el('code', '', claim.name), el('span', '', Kit.t('claim.' + claim.name)));
      const value = el('div', 'time-value');
      if (claim.valid) {
        const notes = [relativeTime(claim.millis, now), String(claim.raw)];
        if (claim.assumedMillis) notes.push(Kit.t('assumedMillis'));
        value.append(el('span', '', formatDate(claim.millis)), el('small', '', notes.join(' · ')));
      } else {
        value.append(el('span', 'invalid-text', Kit.t('claimInvalid')), el('small', '', JSON.stringify(claim.raw)));
      }
      ui.times.append(label, value);
    }
  }

  // 本地时间，24 小时制，时区缩写放在最后；超出 Date 范围时显示破折号。
  // 时区单独取：直接让 Intl 带上时区时，有些语言会把时区插在日期和时间之间。
  function formatDate(millis) {
    const date = new Date(millis);
    if (Number.isNaN(date.getTime())) return '—';
    const text = new Intl.DateTimeFormat(Kit.locale, {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    }).format(date);
    const zone = new Intl.DateTimeFormat(Kit.locale, { timeZoneName: 'short' })
      .formatToParts(date)
      .find((part) => part.type === 'timeZoneName');
    return zone ? text + ' ' + zone.value : text;
  }

  // 用 Intl.RelativeTimeFormat 生成「3 小时后 / 2 天前」，单位取不超过差值的最大一个。
  function relativeTime(millis, now) {
    const diff = millis - now;
    const [unit, size] = UNITS.find((entry) => Math.abs(diff) >= entry[1]) || UNITS[UNITS.length - 1];
    return new Intl.RelativeTimeFormat(Kit.locale, { numeric: 'auto' }).format(Math.round(diff / size), unit);
  }

  // 把缩进后的 JSON 切成键、字符串、数字、字面量逐段写入；只用 textContent，令牌内容不会被当成 HTML 解析。
  function renderJson(container, value) {
    const text = JSON.stringify(value, null, 2);
    const pattern = /("(?:\\u[0-9a-fA-F]{4}|\\[^u]|[^\\"])*")(\s*:)?|\b(?:true|false|null)\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
    const fragment = document.createDocumentFragment();
    let last = 0;
    for (const match of text.matchAll(pattern)) {
      fragment.append(text.slice(last, match.index));
      if (match[1]) {
        fragment.append(el('span', match[2] ? 'tok-key' : 'tok-str', match[1]));
        if (match[2]) fragment.append(match[2]);
      } else {
        fragment.append(el('span', /^[tfn]/.test(match[0]) ? 'tok-lit' : 'tok-num', match[0]));
      }
      last = match.index + match[0].length;
    }
    fragment.append(text.slice(last));
    container.replaceChildren(fragment);
  }

  // 复制用缩进的 JSON，预填到终端用单行；payload 不是 JSON 时原样给出。
  function payloadText(pretty) {
    if (!decoded.payloadIsJson) return decoded.payloadText;
    return pretty ? JSON.stringify(decoded.payload, null, 2) : JSON.stringify(decoded.payload);
  }

  // 只有能读出 payload 的令牌（JWS）才能复制或预填。
  function setActionsEnabled(enabled) {
    Kit.setEnabled(ui.copy, enabled);
    Kit.setEnabled(ui.insert, enabled);
  }

  // 生成一个一小时后过期的示例令牌（签名只是占位字节），第一次用时能马上看到效果。
  function sampleToken() {
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: 'HS256', typ: 'JWT' };
    const payload = { sub: '1234567890', name: Kit.t('sampleName'), admin: true, iat: now, exp: now + 3600 };
    const body = [header, payload].map((part) => Core.encodeSegment(JSON.stringify(part))).join('.');
    return body + '.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
  }

  ui.token.addEventListener('input', update);
  ui.sample.addEventListener('click', () => {
    ui.token.value = sampleToken();
    update();
    ui.token.focus();
  });
  ui.copy.addEventListener('click', () => {
    if (decoded && decoded.kind === 'jws') Kit.copyText(payloadText(true));
  });
  ui.insert.addEventListener('click', () => {
    if (decoded && decoded.kind === 'jws') Kit.insertText(payloadText(false));
  });

  Kit.onLocaleChange(update);
  Kit.start({
    onInput(text) {
      if (text) {
        ui.token.value = text;
        update();
      }
      ui.token.focus({ preventScroll: true });
    },
    onQuery(text) {
      ui.token.value = text;
      update();
    },
  });
  update();
  setInterval(renderState, 30000);
})();
