// 颜色解析与换算的纯函数：HEX / RGB(A) / HSL(A) 互转与格式化，WCAG 2.x 相对亮度、对比度与等级。
(function (root) {
  'use strict';

  const NUMBER = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(%?)$/i;

  // 把数值限制在 [min, max]。
  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  // 解析一个数值记号；percentScale 是 100% 对应的值；不是数值返回 NaN。
  function parseNumber(token, percentScale) {
    const match = NUMBER.exec(token);
    if (!match) return NaN;
    const value = parseFloat(match[1]);
    return match[2] ? (value / 100) * percentScale : value;
  }

  // 饱和度与亮度：旧写法必须带 %，CSS Color 4 也允许纯数字，两种都按百分数（0–100）理解。
  function parsePercent(token) {
    const match = NUMBER.exec(token);
    return match ? parseFloat(match[1]) : NaN;
  }

  // 色相：默认单位是度，也认 deg / rad / grad / turn；结果归一到 [0, 360)。
  function parseHue(token) {
    const match = /^([+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?)(deg|rad|grad|turn)?$/i.exec(token);
    if (!match) return NaN;
    const value = parseFloat(match[1]);
    const unit = (match[2] || 'deg').toLowerCase();
    const factor = { deg: 1, rad: 180 / Math.PI, grad: 0.9, turn: 360 }[unit];
    return (((value * factor) % 360) + 360) % 360;
  }

  // 透明度：0–1 的数或百分数，缺省为 1。
  function parseAlpha(token) {
    if (token === null) return 1;
    const value = parseNumber(token, 1);
    return Number.isNaN(value) ? NaN : clamp(value, 0, 1);
  }

  // HEX：3 / 4 / 6 / 8 位，# 可省略；短写法每位重复一次。
  function parseHex(text) {
    const match = /^#?([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.exec(text);
    if (!match) return null;
    let hex = match[1];
    if (hex.length <= 4) hex = hex.split('').map((ch) => ch + ch).join('');
    const byte = (index) => parseInt(hex.slice(index, index + 2), 16);
    return { r: byte(0), g: byte(2), b: byte(4), a: hex.length === 8 ? byte(6) / 255 : 1 };
  }

  // 拆出 rgb() / hsl() 的参数：兼容逗号写法与 CSS Color 4 的「空格 + 斜杠」写法。
  function functionArgs(text) {
    const match = /^([a-z]+)\(\s*([^()]*?)\s*\)$/i.exec(text);
    if (!match) return null;
    const body = match[2];
    let parts;
    let alpha = null;
    if (body.includes(',')) {
      parts = body.split(/\s*,\s*/);
      if (parts.length === 4) alpha = parts.pop();
    } else {
      const pieces = body.split(/\s*\/\s*/);
      if (pieces.length > 2) return null;
      parts = pieces[0].split(/\s+/);
      if (pieces.length === 2) alpha = pieces[1];
    }
    if (parts.length !== 3) return null;
    return { name: match[1].toLowerCase(), parts, alpha };
  }

  // rgb() / rgba()；只有三个 0–255 的数时也按 RGB 理解（设计稿常复制出 "255, 87, 51"）。
  function parseRgb(text) {
    let args = functionArgs(text);
    if (!args && /^\d{1,3}(?:\s*,\s*|\s+)\d{1,3}(?:\s*,\s*|\s+)\d{1,3}$/.test(text)) args = functionArgs('rgb(' + text + ')');
    if (!args || (args.name !== 'rgb' && args.name !== 'rgba')) return null;
    const [r, g, b] = args.parts.map((part) => parseNumber(part, 255));
    const a = parseAlpha(args.alpha);
    if ([r, g, b, a].some(Number.isNaN)) return null;
    return { r: clamp(r, 0, 255), g: clamp(g, 0, 255), b: clamp(b, 0, 255), a };
  }

  // hsl() / hsla()。
  function parseHsl(text) {
    const args = functionArgs(text);
    if (!args || (args.name !== 'hsl' && args.name !== 'hsla')) return null;
    const h = parseHue(args.parts[0]);
    const s = parsePercent(args.parts[1]);
    const l = parsePercent(args.parts[2]);
    const a = parseAlpha(args.alpha);
    if ([h, s, l, a].some(Number.isNaN)) return null;
    return Object.assign(hslToRgb(h, clamp(s, 0, 100) / 100, clamp(l, 0, 100) / 100), { a });
  }

  // 解析颜色文本，返回 {r, g, b, a}（r/g/b 为 0–255 的实数，a 为 0–1）；无法识别返回 null。
  function parse(input) {
    const text = String(input || '').trim();
    if (!text) return null;
    return parseHex(text) || parseRgb(text) || parseHsl(text);
  }

  // HSL → RGB（CSS Color 4 给出的算法）：h 为角度，s、l 为 0–1，结果分量为 0–255。
  function hslToRgb(h, s, l) {
    const channel = (n) => {
      const k = (n + h / 30) % 12;
      const a = s * Math.min(l, 1 - l);
      return (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))) * 255;
    };
    return { r: channel(0), g: channel(8), b: channel(4) };
  }

  // RGB → HSL：返回 h（度，0–360）与 s、l（0–100）。
  function rgbToHsl(r, g, b) {
    const rn = r / 255;
    const gn = g / 255;
    const bn = b / 255;
    const max = Math.max(rn, gn, bn);
    const min = Math.min(rn, gn, bn);
    const l = (max + min) / 2;
    const d = max - min;
    let h = 0;
    let s = 0;
    if (d !== 0) {
      s = d / (1 - Math.abs(2 * l - 1));
      if (max === rn) h = ((gn - bn) / d) % 6;
      else if (max === gn) h = (bn - rn) / d + 2;
      else h = (rn - gn) / d + 4;
      h *= 60;
      if (h < 0) h += 360;
    }
    return { h, s: s * 100, l: l * 100 };
  }

  // 两位十六进制。
  function hex2(value) {
    return Math.round(clamp(value, 0, 255)).toString(16).padStart(2, '0').toUpperCase();
  }

  // 透明度文字，最多两位小数（0.5、0.25）。
  function alphaText(alpha) {
    return String(Math.round(alpha * 100) / 100);
  }

  // 各种格式的文字：HEX、rgb()、hsl() 与 0–1 小数分量；完全不透明时省略透明度。
  function formats(color) {
    const r = Math.round(color.r);
    const g = Math.round(color.g);
    const b = Math.round(color.b);
    const opaque = color.a >= 1;
    const hsl = rgbToHsl(color.r, color.g, color.b);
    const h = Math.round(hsl.h) % 360;
    const s = Math.round(hsl.s);
    const l = Math.round(hsl.l);
    const alpha = alphaText(color.a);
    return {
      hex: '#' + hex2(r) + hex2(g) + hex2(b) + (opaque ? '' : hex2(color.a * 255)),
      rgb: opaque ? `rgb(${r}, ${g}, ${b})` : `rgba(${r}, ${g}, ${b}, ${alpha})`,
      hsl: opaque ? `hsl(${h}, ${s}%, ${l}%)` : `hsla(${h}, ${s}%, ${l}%, ${alpha})`,
      unit: [color.r, color.g, color.b].map((value) => (value / 255).toFixed(3)).join(', ') + (opaque ? '' : ', ' + alpha),
    };
  }

  // WCAG 2.x 相对亮度：sRGB 分量先线性化，再按 0.2126 / 0.7152 / 0.0722 加权。
  function luminance(color) {
    const linear = (value) => {
      const c = value / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    };
    return 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
  }

  // 半透明颜色按透明度叠到背景上，得到它实际显示出来的颜色。
  function composite(color, background) {
    const a = color.a;
    return {
      r: color.r * a + background.r * (1 - a),
      g: color.g * a + background.g * (1 - a),
      b: color.b * a + background.b * (1 - a),
      a: 1,
    };
  }

  // 前景色放在背景色上的对比度（1–21）；前景半透明时先叠到背景上再算。
  function contrast(foreground, background) {
    const fg = foreground.a < 1 ? composite(foreground, background) : foreground;
    const l1 = luminance(fg);
    const l2 = luminance(background);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  }

  // WCAG 2 等级：≥ 7 为 AAA，≥ 4.5 为 AA，≥ 3 只适合大字，其余不达标。按未取整的比值判断，不能四舍五入后算通过。
  function contrastLevel(ratio) {
    if (ratio >= 7) return 'aaa';
    if (ratio >= 4.5) return 'aa';
    if (ratio >= 3) return 'aaLarge';
    return 'fail';
  }

  const api = { parse, hslToRgb, rgbToHsl, formats, luminance, composite, contrast, contrastLevel };
  root.ColorCore = api;
  if (typeof module === 'object' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
