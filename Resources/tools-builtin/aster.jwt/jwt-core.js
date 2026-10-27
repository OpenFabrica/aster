// JWT 解码的纯函数：拆段、base64url 解码成 UTF-8 JSON、读取时间声明、判断状态。只解码，不校验签名。
(function (root) {
  'use strict';

  // 解码失败的原因；reason 对应界面文案的键，part 指出是哪一段（header / payload）。
  class JwtError extends Error {
    constructor(reason, info) {
      super(reason);
      this.name = 'JwtError';
      this.reason = reason;
      this.info = info || {};
    }
  }

  // 粘贴来的内容常带 "Authorization: Bearer " 前缀、引号或折行，先去掉再解析。
  function extractToken(text) {
    return String(text || '')
      .trim()
      .replace(/^authorization\s*:\s*/i, '')
      .replace(/^bearer\s+/i, '')
      .replace(/^["'`]+|["'`]+$/g, '')
      .replace(/\s+/g, '');
  }

  // base64url（RFC 4648 §5）转字节：JWT 去掉了 '=' 填充并用 '-' '_' 代替 '+' '/'，
  // 而 atob 只认标准字母表，所以先换回来、补齐填充；长度除以 4 余 1 不可能是合法编码。
  function base64UrlToBytes(segment, part) {
    if (!/^[A-Za-z0-9_-]*$/.test(segment)) throw new JwtError('badChars', { part });
    if (segment.length % 4 === 1) throw new JwtError('badLength', { part });
    const base64 = segment.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((segment.length + 3) % 4);
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // atob 得到的是「一个字符一个字节」的串，直接当文本会把中文等多字节字符解成乱码，所以用 TextDecoder 严格按 UTF-8 解码。
  function bytesToText(bytes, part) {
    try {
      return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch (error) {
      throw new JwtError('notUtf8', { part });
    }
  }

  // 文本按 UTF-8 编成 base64url（生成示例令牌用）。
  function encodeSegment(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = '';
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  // 是否为普通 JSON 对象（不是数组、不是 null）。
  function isPlainObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value);
  }

  // 解码并解析一段 JSON；part 用于出错时指出是哪一段。
  function decodeJsonSegment(segment, part) {
    const text = bytesToText(base64UrlToBytes(segment, part), part);
    try {
      return JSON.parse(text);
    } catch (error) {
      throw new JwtError('notJson', { part });
    }
  }

  // 解析整个令牌。三段是 JWS（可解出 payload）；五段是 JWE（payload 加密，只能看 header）。
  function decodeJwt(text) {
    const token = extractToken(text);
    if (!token) throw new JwtError('empty');
    const parts = token.split('.');
    if (parts.length === 5) {
      const header = decodeJsonSegment(parts[0], 'header');
      if (!isPlainObject(header)) throw new JwtError('headerNotObject', { part: 'header' });
      return { kind: 'jwe', token, header };
    }
    if (parts.length !== 3) throw new JwtError('segments', { count: parts.length });
    const header = decodeJsonSegment(parts[0], 'header');
    if (!isPlainObject(header)) throw new JwtError('headerNotObject', { part: 'header' });
    const payloadText = bytesToText(base64UrlToBytes(parts[1], 'payload'), 'payload');
    base64UrlToBytes(parts[2], 'signature');
    // JWS 允许任意 payload；不是 JSON 时按原文显示，不算错误。
    let payload = null;
    let payloadIsJson = false;
    try {
      payload = JSON.parse(payloadText);
      payloadIsJson = true;
    } catch (error) {
      payload = null;
    }
    return { kind: 'jws', token, header, payload, payloadText, payloadIsJson, signature: parts[2] };
  }

  // 读取 exp / iat / nbf。JWT 的 NumericDate 是秒；绝对值大于 1e11（公元 5000 年以后）的多半是误写成毫秒，按毫秒解释并标出来。
  function timeClaim(payload, name) {
    if (!isPlainObject(payload) || !Object.prototype.hasOwnProperty.call(payload, name)) return null;
    const raw = payload[name];
    if (typeof raw !== 'number' || !Number.isFinite(raw)) return { name, raw, valid: false };
    const assumedMillis = Math.abs(raw) > 1e11;
    return { name, raw, valid: true, assumedMillis, millis: assumedMillis ? raw : raw * 1000 };
  }

  // 按当前时间判断令牌状态：未生效（now < nbf）、已过期（now >= exp，RFC 7519 §4.1.4）、有效、没有过期时间。
  function tokenState(payload, now) {
    const nbf = timeClaim(payload, 'nbf');
    const exp = timeClaim(payload, 'exp');
    if (nbf && nbf.valid && now < nbf.millis) return 'notYetValid';
    if (exp && exp.valid) return now >= exp.millis ? 'expired' : 'valid';
    return 'noExpiry';
  }

  const api = { JwtError, extractToken, base64UrlToBytes, encodeSegment, decodeJwt, timeClaim, tokenState };
  root.JwtCore = api;
  if (typeof module === 'object' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
