//! broker 启动票据（PROTOCOL §3 OPEN.ticket、§4.2 `tickets.key`）：确认 OPEN 来自 App 拉起的 client。
//!
//! App 每拉起一个 broker 实例就生成一把 32 字节 HMAC 密钥，只经私有 stdin 发来；之后每拉起一个
//! `aster-ssh client` 就签一张票，经环境变量 `ASTER_SSH_TICKET` 交给它。票据格式
//! `v1.<nonce>.<expiryMs>.<hmac>`，`hmac = HMAC-SHA256(key, "v1|<nonce>|<expiryMs>")`，全部小写 hex。
//! 一次性：nonce 用过即记下，过期后清掉。
//!
//! 威胁模型：只约束「配合的」同用户进程（例如 coding agent 直接连 socket 绕过批准），
//! 挡不住能读 App 内存、ptrace 或抢先读取进程环境的恶意软件。

use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hmac::{Hmac, KeyInit, Mac};
use sha2_v011::Sha256;
use tokio::sync::watch;
use zeroize::Zeroizing;

/// client 读取票据的环境变量。
pub const TICKET_ENV: &str = "ASTER_SSH_TICKET";
/// 调试开关：debug 构建的 broker 环境里 `ASTER_SSH_TICKETS=off` 时不校验票据；发行版（`--release`）忽略它。
#[cfg_attr(not(debug_assertions), allow(dead_code))]
pub const SWITCH_ENV: &str = "ASTER_SSH_TICKETS";
/// 票据版本前缀。
const VERSION: &str = "v1";
/// 密钥字节数。
const KEY_BYTES: usize = 32;
/// nonce 的 hex 长度（16 字节）。
const NONCE_HEX: usize = 32;
/// OPEN 先于 `tickets.key` 到达时最多等这么久（broker 先 bind 再读 stdin）。
const KEY_WAIT: Duration = Duration::from_secs(2);
/// 到期时间离现在的上限。App 签 120 秒；放宽到 5 分钟容忍时钟抖动，同时限制已用集合的保留时长。
const MAX_LIFETIME_MS: u64 = 300_000;

/// 票据被拒的原因。只进日志，不回给 client（client 只看到统一的 "invalid launch ticket"）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rejection {
    /// OPEN 没带票据。
    Missing,
    /// App 还没发 `tickets.key`。
    NoKey,
    /// 格式不对，或到期时间超出上限。
    Malformed,
    /// HMAC 不匹配。
    BadSignature,
    /// 已过期。
    Expired,
    /// nonce 已用过。
    Replayed,
}

impl fmt::Display for Rejection {
    /// 日志用的短描述。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Rejection::Missing => "missing",
            Rejection::NoKey => "no key",
            Rejection::Malformed => "malformed",
            Rejection::BadSignature => "bad signature",
            Rejection::Expired => "expired",
            Rejection::Replayed => "replayed",
        })
    }
}

/// 共享的密钥；Zeroizing 保证替换或丢弃时清零。
type Key = Arc<Zeroizing<Vec<u8>>>;

/// 一个 broker 实例的票据校验器。
pub struct LaunchTickets {
    enforced: AtomicBool,
    key: watch::Sender<Option<Key>>,
    /// 已用 nonce → 到期时间（毫秒）。
    used: Mutex<HashMap<String, u64>>,
}

impl Default for LaunchTickets {
    /// 等同 `new`。
    fn default() -> Self {
        Self::new()
    }
}

impl LaunchTickets {
    /// 新建校验器：默认强制校验、尚无密钥。
    pub fn new() -> Self {
        let (key, _) = watch::channel(None);
        Self {
            enforced: AtomicBool::new(true),
            key,
            used: Mutex::new(HashMap::new()),
        }
    }

    /// 关闭校验（仅 debug 构建的 `ASTER_SSH_TICKETS=off` 与测试使用；发行版不编译调用方）。
    #[cfg_attr(not(debug_assertions), allow(dead_code))]
    pub fn disable(&self) {
        self.enforced.store(false, Ordering::SeqCst);
    }

    /// 是否强制校验。
    pub fn is_enforced(&self) -> bool {
        self.enforced.load(Ordering::SeqCst)
    }

    /// 装入 `tickets.key` 的 hex 密钥；长度不对时拒绝并保留旧密钥。
    pub fn set_key_hex(&self, hex_key: &str) -> Result<(), &'static str> {
        let bytes = Zeroizing::new(hex::decode(hex_key).map_err(|_| "key is not hex")?);
        if bytes.len() != KEY_BYTES {
            return Err("key must be 32 bytes");
        }
        self.key.send_replace(Some(Arc::new(bytes)));
        Ok(())
    }

    /// 校验 OPEN 带来的票据；通过即作废它。还没收到密钥时最多等 2 秒。
    pub async fn check(&self, ticket: Option<&str>) -> Result<(), Rejection> {
        if !self.is_enforced() {
            return Ok(());
        }
        let ticket = ticket.filter(|t| !t.is_empty()).ok_or(Rejection::Missing)?;
        let key = self.wait_for_key().await.ok_or(Rejection::NoKey)?;
        self.verify(&key, ticket, now_ms())
    }

    /// 取当前密钥；没有就等它到达，超时返回 None。
    async fn wait_for_key(&self) -> Option<Key> {
        let mut rx = self.key.subscribe();
        let waited = tokio::time::timeout(KEY_WAIT, rx.wait_for(Option::is_some)).await;
        match waited {
            Ok(Ok(key)) => key.clone(),
            _ => None,
        }
    }

    /// 同步校验：先验 HMAC（伪造的票据不会进已用集合），再看到期，最后查重放并登记。
    fn verify(&self, key: &[u8], ticket: &str, now: u64) -> Result<(), Rejection> {
        let parts: Vec<&str> = ticket.split('.').collect();
        let [version, nonce, expiry, mac] = parts.as_slice() else {
            return Err(Rejection::Malformed);
        };
        let lower_hex = |s: &str| {
            s.bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        };
        if *version != VERSION || nonce.len() != NONCE_HEX || !lower_hex(nonce) {
            return Err(Rejection::Malformed);
        }
        if expiry.is_empty() || !expiry.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Rejection::Malformed);
        }
        let expiry_ms: u64 = expiry.parse().map_err(|_| Rejection::Malformed)?;
        let mac = hex::decode(mac).map_err(|_| Rejection::Malformed)?;
        let mut expected =
            <Hmac<Sha256> as KeyInit>::new_from_slice(key).map_err(|_| Rejection::NoKey)?;
        expected.update(signed_message(nonce, expiry_ms).as_bytes());
        // verify_slice 是常量时间比较。
        expected
            .verify_slice(&mac)
            .map_err(|_| Rejection::BadSignature)?;
        if expiry_ms < now {
            return Err(Rejection::Expired);
        }
        if expiry_ms > now.saturating_add(MAX_LIFETIME_MS) {
            return Err(Rejection::Malformed);
        }
        let mut used = self.used.lock().unwrap_or_else(|p| p.into_inner());
        used.retain(|_, until| *until >= now);
        if used.contains_key(*nonce) {
            return Err(Rejection::Replayed);
        }
        used.insert((*nonce).to_string(), expiry_ms);
        Ok(())
    }
}

/// HMAC 的输入：`v1|<nonce>|<expiryMs>`。
fn signed_message(nonce: &str, expiry_ms: u64) -> String {
    format!("{VERSION}|{nonce}|{expiry_ms}")
}

/// 当前 Unix 毫秒。系统时钟早于 1970 时按 0 处理（所有票据都会显得未过期，但仍要验签）。
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 按 App 的规则签一张票（测试夹具用；生产由 App 签发）。
#[cfg(test)]
pub fn mint(key: &[u8], nonce: &str, expiry_ms: u64) -> String {
    let mut mac = <Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("hmac key");
    mac.update(signed_message(nonce, expiry_ms).as_bytes());
    let tag = hex::encode(mac.finalize().into_bytes());
    format!("{VERSION}.{nonce}.{expiry_ms}.{tag}")
}

/// 测试用的票：当前时间起 120 秒有效。
#[cfg(test)]
pub fn mint_now(key: &[u8], nonce: &str) -> String {
    mint(key, nonce, now_ms() + 120_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 32] = [7u8; 32];
    const NONCE: &str = "0123456789abcdef0123456789abcdef";

    /// 装好测试密钥的校验器。
    fn tickets() -> LaunchTickets {
        let t = LaunchTickets::new();
        t.set_key_hex(&hex::encode(KEY)).unwrap();
        t
    }

    /// 与 Swift `NativeSSHTicketIssuer.ticket` 用同一组向量对照格式与 HMAC。
    #[test]
    fn the_ticket_format_matches_the_swift_issuer() {
        assert_eq!(
            mint(&KEY, NONCE, 1_700_000_000_000),
            "v1.0123456789abcdef0123456789abcdef.1700000000000.\
             530b76c7da3be207734f661ff80a1765a8ea03cf88e648547d6acd226a050a56"
        );
    }

    /// 合法票据只能用一次。
    #[tokio::test]
    async fn a_valid_ticket_passes_once_and_replay_is_rejected() {
        let t = tickets();
        let ticket = mint_now(&KEY, NONCE);
        assert_eq!(t.check(Some(&ticket)).await, Ok(()));
        assert_eq!(t.check(Some(&ticket)).await, Err(Rejection::Replayed));
    }

    /// 过期票据被拒。
    #[tokio::test]
    async fn expired_tickets_are_rejected() {
        let t = tickets();
        let ticket = mint(&KEY, NONCE, now_ms() - 1);
        assert_eq!(t.check(Some(&ticket)).await, Err(Rejection::Expired));
    }

    /// 到期时间超出上限的票据按格式错误拒绝。
    #[tokio::test]
    async fn far_future_expiry_is_rejected() {
        let t = tickets();
        let ticket = mint(&KEY, NONCE, now_ms() + MAX_LIFETIME_MS + 60_000);
        assert_eq!(t.check(Some(&ticket)).await, Err(Rejection::Malformed));
    }

    /// 错误密钥或被改动的字段都过不了 HMAC，且不占用 nonce。
    #[tokio::test]
    async fn a_wrong_key_or_tampered_field_fails_the_hmac() {
        let t = tickets();
        let forged = mint_now(&[9u8; 32], NONCE);
        assert_eq!(t.check(Some(&forged)).await, Err(Rejection::BadSignature));
        // 改到期时间：签名不再匹配。
        let good = mint(&KEY, NONCE, now_ms() + 60_000);
        let mut parts: Vec<String> = good.split('.').map(String::from).collect();
        parts[2] = (now_ms() + 90_000).to_string();
        assert_eq!(
            t.check(Some(&parts.join("."))).await,
            Err(Rejection::BadSignature)
        );
        // 伪造的票据不占用 nonce：真票随后仍可用。
        assert_eq!(t.check(Some(&good)).await, Ok(()));
    }

    /// 缺失与格式错误的票据被拒。
    #[tokio::test]
    async fn missing_and_malformed_tickets_are_rejected() {
        let t = tickets();
        assert_eq!(t.check(None).await, Err(Rejection::Missing));
        assert_eq!(t.check(Some("")).await, Err(Rejection::Missing));
        for bad in [
            "v1",
            "v2.0123456789abcdef0123456789abcdef.1.00",
            "v1.XYZ.1.00",
            "v1.0123456789ABCDEF0123456789ABCDEF.1.00",
            "v1.0123456789abcdef0123456789abcdef.-1.00",
            "v1.0123456789abcdef0123456789abcdef.1.zz",
            "v1.0123456789abcdef0123456789abcdef.1.00.extra",
        ] {
            assert_eq!(t.check(Some(bad)).await, Err(Rejection::Malformed), "{bad}");
        }
    }

    /// 没有密钥时 OPEN 最多等 2 秒后失败。
    #[tokio::test]
    async fn without_a_key_open_waits_briefly_then_fails() {
        let t = LaunchTickets::new();
        let started = std::time::Instant::now();
        let ticket = mint_now(&KEY, NONCE);
        assert_eq!(t.check(Some(&ticket)).await, Err(Rejection::NoKey));
        assert!(started.elapsed() >= KEY_WAIT - Duration::from_millis(50));
    }

    /// 密钥稍晚到达时，等待中的 OPEN 继续校验。
    #[tokio::test]
    async fn a_key_arriving_late_unblocks_the_waiting_open() {
        let t = Arc::new(LaunchTickets::new());
        let ticket = mint_now(&KEY, NONCE);
        let waiter = {
            let t = t.clone();
            tokio::spawn(async move { t.check(Some(&ticket)).await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        t.set_key_hex(&hex::encode(KEY)).unwrap();
        assert_eq!(waiter.await.unwrap(), Ok(()));
    }

    /// 非法密钥被拒；调试开关关掉校验。
    #[tokio::test]
    async fn bad_keys_are_refused_and_the_switch_disables_checks() {
        let t = LaunchTickets::new();
        assert!(t.set_key_hex("zz").is_err());
        assert!(t.set_key_hex(&hex::encode([1u8; 16])).is_err());
        t.disable();
        assert!(!t.is_enforced());
        assert_eq!(t.check(None).await, Ok(()));
    }

    /// 已用 nonce 过期后被清理。
    #[test]
    fn used_nonces_are_pruned_after_expiry() {
        let t = tickets();
        let now = 1_000_000;
        let ticket = mint(&KEY, NONCE, now + 10);
        assert_eq!(t.verify(&KEY, &ticket, now), Ok(()));
        let other = mint(&KEY, "ffffffffffffffffffffffffffffffff", now + 50_000);
        assert_eq!(t.verify(&KEY, &other, now + 20), Ok(()));
        assert_eq!(t.used.lock().unwrap().len(), 1);
    }
}
