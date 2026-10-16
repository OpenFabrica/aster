//! 保险库密钥认证。
//!
//! 私钥只存在 App 的登录钥匙串里，`profiles.sync` 只带 `{id, publicKey}`。轮到某把密钥时 broker 发
//! `auth.request kind=privateKey`（`interactive:false`，App 可直接从钥匙串作答），拿到未加密的
//! OpenSSH 私钥文本后先核对公钥再认证；私钥全程放在 `Zeroizing` 里，用完即清零。
//! App 回 null（钥匙串里没有、读取失败）只跳过这一把，不取消整个认证；服务器拒绝也不影响保险库。

use std::sync::Arc;

use russh::client::{AuthResult, Handle};
use russh::keys::{PrivateKeyWithHashAlg, PublicKey};

use crate::auth::{ask, rsa_hash, transport, AuthContext, Outcome};
use crate::handler::ClientHandler;
use crate::protocol::{AuthRequestKind, SshFailure, VaultKeyRef};
use crate::{log_debug, log_info};

/// 解析一行 OpenSSH 公钥（`算法 base64 [注释]`）；只取密钥本身，忽略注释。
pub(crate) fn parse_public_key(line: &str) -> Option<PublicKey> {
    let b64 = line.split_whitespace().nth(1)?;
    russh::keys::parse_public_key_base64(b64).ok()
}

/// 依次尝试这一跳的全部保险库密钥。
pub(crate) async fn try_vault_keys(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
) -> Result<Outcome, SshFailure> {
    let mut outcome = Outcome::Skipped;
    for vault in &ctx.spec.vault_keys {
        match try_vault_key(handle, ctx, vault).await? {
            Outcome::Authenticated => return Ok(Outcome::Authenticated),
            r @ Outcome::Rejected(_) => outcome = r,
            Outcome::Cancelled | Outcome::Skipped => {}
        }
    }
    Ok(outcome)
}

/// 向 App 要一把保险库私钥，核对公钥后用它认证；`auth.result` 只是告知结果，App 不据此删除密钥。
async fn try_vault_key(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
    vault: &VaultKeyRef,
) -> Result<Outcome, SshFailure> {
    let Some(expected) = parse_public_key(&vault.public_key) else {
        log_info!("vault key {} has an unparsable public key", vault.id);
        return Ok(Outcome::Skipped);
    };
    let (id, answer) = ask(ctx, AuthRequestKind::PrivateKey, 1, |r| {
        r.vault_key_id = Some(vault.id.clone());
        // 保险库私钥由 App 从钥匙串直接作答，不弹表单；没有就回 null。
        r.interactive = false;
    })
    .await;
    let Some(secret) = answer.secret else {
        log_debug!("vault key {} unavailable", vault.id);
        return Ok(Outcome::Skipped);
    };
    let decoded = russh::keys::decode_secret_key(&secret, None);
    drop(secret);
    let key = match decoded {
        Ok(k) => k,
        Err(e) => {
            log_info!("vault key {} is not a usable private key: {e}", vault.id);
            ctx.env.control.auth_result(&id, false);
            return Ok(Outcome::Skipped);
        }
    };
    // App 回来的私钥必须与 profiles.sync 里登记的公钥一致，否则不拿去认证。
    if key.public_key().key_data() != expected.key_data() {
        log_info!("vault key {} does not match its public key", vault.id);
        ctx.env.control.auth_result(&id, false);
        return Ok(Outcome::Skipped);
    }
    let hash = rsa_hash(handle, key.algorithm().is_rsa()).await;
    let key = PrivateKeyWithHashAlg::new(Arc::new(key), hash);
    match handle
        .authenticate_publickey(ctx.spec.user.clone(), key)
        .await
        .map_err(transport)?
    {
        AuthResult::Success => {
            ctx.env.control.auth_result(&id, true);
            Ok(Outcome::Authenticated)
        }
        AuthResult::Failure {
            remaining_methods, ..
        } => {
            log_debug!("server rejected vault key {}", vault.id);
            ctx.env.control.auth_result(&id, false);
            Ok(Outcome::Rejected(Some(remaining_methods)))
        }
    }
}
