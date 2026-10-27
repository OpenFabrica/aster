// 颜色转换工具的界面逻辑：解析输入的颜色，显示色块、HEX / RGB / HSL / 0–1 格式与 WCAG 对比度，可单项复制。
(function () {
  'use strict';

  const Kit = window.AsterKit;
  const Core = window.ColorCore;
  const WHITE = { r: 255, g: 255, b: 255, a: 1 };
  const BLACK = { r: 0, g: 0, b: 0, a: 1 };
  const FORMAT_LABELS = { hex: 'HEX', rgb: 'RGB', hsl: 'HSL', unit: '0–1' };
  // 这些关键字在画布里会被解析成「当前颜色」或沿用上一次的值，不是真正的颜色。
  const NOT_COLORS = /^(inherit|initial|unset|revert|revert-layer|currentcolor)$/i;

  const byId = (id) => document.getElementById(id);
  const ui = {
    input: byId('color'),
    error: byId('error'),
    empty: byId('empty'),
    result: byId('result'),
    swatch: byId('swatch'),
    alpha: byId('alpha'),
    compositeNote: byId('composite-note'),
    values: { hex: byId('value-hex'), rgb: byId('value-rgb'), hsl: byId('value-hsl'), unit: byId('value-unit') },
    ratio: { white: byId('ratio-white'), black: byId('ratio-black') },
    level: { white: byId('level-white'), black: byId('level-black') },
    sample: { white: byId('sample-white'), black: byId('sample-black') },
  };
  const copyButtons = Array.from(document.querySelectorAll('[data-copy]'));
  const probe = createProbe();
  // 当前颜色的各种格式文字；输入为空或无效时为 null。
  let formats = null;

  // 浏览器解析用的 1×1 画布；拿不到 2D 上下文时为 null。
  function createProbe() {
    const canvas = document.createElement('canvas');
    canvas.width = 1;
    canvas.height = 1;
    return canvas.getContext('2d', { willReadFrequently: true });
  }

  // 其余 CSS 颜色写法（red、rebeccapurple、hwb()、oklch() 等）交给浏览器解析：画到 1×1 画布上再读回像素。
  function parseWithBrowser(text) {
    if (!probe || NOT_COLORS.test(text) || typeof CSS === 'undefined' || !CSS.supports('color', text)) return null;
    probe.clearRect(0, 0, 1, 1);
    probe.fillStyle = '#000000';
    probe.fillStyle = text;
    probe.fillRect(0, 0, 1, 1);
    const data = probe.getImageData(0, 0, 1, 1).data;
    return { r: data[0], g: data[1], b: data[2], a: data[3] / 255 };
  }

  // 解析输入框内容并刷新界面。
  function update() {
    const text = ui.input.value.trim();
    ui.input.classList.remove('invalid');
    if (!text) {
      showState('empty');
      return;
    }
    const color = Core.parse(text) || parseWithBrowser(text);
    if (!color) {
      ui.input.classList.add('invalid');
      showState('error');
      return;
    }
    showColor(color);
  }

  // 只显示空状态、错误或结果三者之一；没有结果时禁用复制。
  function showState(state) {
    ui.empty.hidden = state !== 'empty';
    ui.error.hidden = state !== 'error';
    ui.result.hidden = state !== 'result';
    if (state !== 'result') formats = null;
    copyButtons.forEach((button) => Kit.setEnabled(button, state === 'result'));
  }

  // 显示一个颜色：色块、各格式、透明度与对比度。
  function showColor(color) {
    formats = Core.formats(color);
    showState('result');
    ui.swatch.style.backgroundColor = formats.rgb;
    for (const key of Object.keys(FORMAT_LABELS)) ui.values[key].textContent = formats[key];
    ui.alpha.textContent = color.a < 1 ? Kit.t('alpha', { value: Kit.formatNumber(Math.round(color.a * 100)) }) : '';
    ui.compositeNote.hidden = color.a >= 1;
    renderContrast('white', color, WHITE);
    renderContrast('black', color, BLACK);
  }

  // 一组对比度：比值、WCAG 等级与示例文字。
  function renderContrast(which, color, background) {
    const ratio = Core.contrast(color, background);
    const level = Core.contrastLevel(ratio);
    // 显示时向下取整到两位小数，避免 4.499 显示成 4.50 却判为不达标。
    const shown = Math.floor(ratio * 100) / 100;
    ui.ratio[which].textContent = Kit.formatNumber(shown, { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ':1';
    ui.level[which].textContent = Kit.t('level.' + level);
    ui.level[which].className = 'badge ' + (level === 'fail' ? 'danger' : level === 'aaLarge' ? 'warn' : 'ok');
    ui.level[which].title = Kit.t('levelTitle');
    ui.sample[which].style.color = formats.rgb;
  }

  // 复制按钮的提示带上格式名；没有桥接时保留「需要在 Aster 里打开」的提示。
  function applyCopyTitles() {
    if (!Kit.bridge) return;
    copyButtons.forEach((button) => {
      button.title = Kit.t('copyTitle', { format: FORMAT_LABELS[button.dataset.copy] });
    });
  }

  ui.input.addEventListener('input', update);
  copyButtons.forEach((button) => {
    button.addEventListener('click', () => {
      if (formats) Kit.copyText(formats[button.dataset.copy]);
    });
  });
  document.querySelectorAll('.example').forEach((button) => {
    button.addEventListener('click', () => {
      ui.input.value = button.textContent;
      update();
      ui.input.focus();
    });
  });

  Kit.onLocaleChange(() => {
    applyCopyTitles();
    update();
  });
  Kit.start({
    onInput(text) {
      if (text) {
        ui.input.value = text.trim();
        update();
      }
      ui.input.focus({ preventScroll: true });
    },
    onQuery(text) {
      ui.input.value = text;
      update();
    },
  });
  applyCopyTitles();
  update();
})();
