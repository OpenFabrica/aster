//! `aster-ssh keys`：保险库用的私钥解析与生成（协议见 `PROTOCOL.md` §6）。
//!
//! 请求从 stdin 读一个 JSON 对象，结果写到 stdout 一个 JSON 对象；私钥与 passphrase 从不进 argv，
//! stderr 只写固定的用法说明，不含任何密钥内容。成功时退出码 0，可预期的失败退出码 1 并在 stdout
//! 写 `{"error":"encrypted"|"wrongPassphrase"|"invalid"|"unsupported"}`，用法错误退出码 2。
//!
//! 输出的 `privateKey` 一律是未加密的 OpenSSH 私钥（LF 换行），由 App 存进钥匙串；stdin 缓冲与
//! 输出文本放在 `Zeroizing` 里，用完清零（serde_json 解析时的临时副本无法覆盖，进程随即退出）。

use std::io::{Read as _, Write as _};
use std::process::ExitCode;

use russh::keys::ssh_key::private::Ed25519Keypair;
use russh::keys::ssh_key::LineEnding;
use russh::keys::{Algorithm, HashAlg, PrivateKey};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// stdin 读取上限：最大的 RSA 16384 私钥文本也远小于此。
const MAX_INPUT: usize = 64 * 1024;

/// 用法说明（只写到 stderr）。
const USAGE: &str = "usage: aster-ssh keys (inspect|generate) < request.json";

/// 可预期的失败，序列化成 stdout 上的 `error` 字段。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyError {
    /// 私钥已加密，但请求里没有 passphrase。
    Encrypted,
    /// passphrase 无法解开私钥。
    WrongPassphrase,
    /// 不是可识别的私钥或请求 JSON 不合法。
    Invalid,
    /// 能识别但 broker 用不了的类型（DSA、安全密钥 sk-*、旧式 AES-256/DES PEM 加密等）。
    Unsupported,
}

impl KeyError {
    /// 协议里的错误码。
    pub fn code(self) -> &'static str {
        match self {
            KeyError::Encrypted => "encrypted",
            KeyError::WrongPassphrase => "wrongPassphrase",
            KeyError::Invalid => "invalid",
            KeyError::Unsupported => "unsupported",
        }
    }
}

/// `keys inspect` 的请求。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InspectRequest {
    private_key: String,
    #[serde(default)]
    passphrase: Option<String>,
    #[serde(default)]
    comment: Option<String>,
}

/// `keys generate` 的请求。
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GenerateRequest {
    #[serde(default = "default_algorithm")]
    algorithm: String,
    #[serde(default)]
    comment: Option<String>,
}

/// generate 缺省算法。
fn default_algorithm() -> String {
    "ed25519".into()
}

/// 成功输出；字段都借用自 `Zeroizing` 缓冲，不另留副本。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct KeyOutput<'a> {
    private_key: &'a str,
    public_key: &'a str,
    algorithm: &'a str,
    fingerprint: &'a str,
    comment: &'a str,
}

/// 子命令入口。
pub fn run_cli(args: &[String]) -> ExitCode {
    let command = match args {
        [c] if c == "inspect" || c == "generate" => c.as_str(),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    let input = match read_stdin() {
        Some(text) => text,
        None => return fail(KeyError::Invalid),
    };
    let result = match command {
        "inspect" => inspect(&input),
        _ => generate(&input),
    };
    match result.and_then(|key| render(&key)) {
        Ok(json) => {
            let mut out = std::io::stdout().lock();
            match writeln!(out, "{}", json.as_str()).and_then(|_| out.flush()) {
                Ok(()) => ExitCode::SUCCESS,
                Err(_) => ExitCode::from(1),
            }
        }
        Err(e) => fail(e),
    }
}

/// 写错误 JSON，退出码 1。
fn fail(error: KeyError) -> ExitCode {
    println!("{{\"error\":\"{}\"}}", error.code());
    ExitCode::from(1)
}

/// 读整个 stdin（超过上限或不是 UTF-8 返回 None）。预留容量避免扩容时留下未清零的旧缓冲。
fn read_stdin() -> Option<Zeroizing<String>> {
    let mut buf = Zeroizing::new(Vec::with_capacity(MAX_INPUT + 1));
    std::io::stdin()
        .take(MAX_INPUT as u64 + 1)
        .read_to_end(&mut buf)
        .ok()?;
    if buf.len() > MAX_INPUT {
        return None;
    }
    let text = std::str::from_utf8(&buf).ok()?;
    Some(Zeroizing::new(text.to_owned()))
}

/// 解析请求里的私钥：必要时用 passphrase 解密，再按注释覆盖规则整理。
pub fn inspect(input: &str) -> Result<PrivateKey, KeyError> {
    let request: InspectRequest = serde_json::from_str(input).map_err(|_| KeyError::Invalid)?;
    let pem = Zeroizing::new(request.private_key);
    let passphrase = request.passphrase.map(Zeroizing::new);
    let passphrase = passphrase.as_ref().filter(|p| !p.is_empty());
    let mut key = decode(&pem, passphrase.map(|p| p.as_str()))?;
    ensure_supported(key.algorithm())?;
    apply_comment(&mut key, request.comment.as_deref())?;
    Ok(key)
}

/// 用 getentropy 种子生成一把新的 ed25519 私钥。
pub fn generate(input: &str) -> Result<PrivateKey, KeyError> {
    let request: GenerateRequest = serde_json::from_str(input).map_err(|_| KeyError::Invalid)?;
    if !matches!(request.algorithm.as_str(), "ed25519" | "ssh-ed25519") {
        return Err(KeyError::Unsupported);
    }
    let mut seed = Zeroizing::new([0u8; 32]);
    // SAFETY：缓冲区为 32 字节，在 getentropy 单次上限 256 字节之内；指针与长度来自同一个数组。
    let rc = unsafe { libc::getentropy(seed.as_mut_ptr().cast(), seed.len()) };
    if rc != 0 {
        return Err(KeyError::Invalid);
    }
    let mut key = PrivateKey::from(Ed25519Keypair::from_seed(&seed));
    apply_comment(&mut key, request.comment.as_deref())?;
    Ok(key)
}

/// 识别并解开私钥文本。先不带 passphrase 试，判断是否加密，再决定错误码。
fn decode(pem: &str, passphrase: Option<&str>) -> Result<PrivateKey, KeyError> {
    // 旧式 PEM 加密只支持 AES-128-CBC；其它（DES-EDE3、AES-256）russh 解不了或会误判成明文。
    if pem.contains("Proc-Type: 4,ENCRYPTED") && !pem.contains("DEK-Info: AES-128-CBC,") {
        return Err(KeyError::Unsupported);
    }
    // 加密的 PKCS#8 与 PuTTY 文件不带 passphrase 时 russh 报的不是 KeyIsEncrypted，这里先认出来。
    let looks_encrypted = pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
        || pem.contains("Proc-Type: 4,ENCRYPTED")
        || (pem.trim_start().starts_with("PuTTY-User-Key-File-")
            && !pem.contains("Encryption: none"));
    let first = if looks_encrypted {
        Err(russh::keys::Error::KeyIsEncrypted)
    } else {
        russh::keys::decode_secret_key(pem, None)
    };
    match first {
        Ok(key) => Ok(key),
        Err(russh::keys::Error::KeyIsEncrypted) => {
            let passphrase = passphrase.ok_or(KeyError::Encrypted)?;
            russh::keys::decode_secret_key(pem, Some(passphrase))
                .map_err(|_| KeyError::WrongPassphrase)
        }
        Err(russh::keys::Error::UnsupportedKeyType { .. }) => Err(KeyError::Unsupported),
        Err(_) => Err(KeyError::Invalid),
    }
}

/// broker 能用来签名的算法：ed25519、ECDSA、RSA。
fn ensure_supported(algorithm: Algorithm) -> Result<(), KeyError> {
    match algorithm {
        Algorithm::Ed25519 | Algorithm::Ecdsa { .. } | Algorithm::Rsa { .. } => Ok(()),
        _ => Err(KeyError::Unsupported),
    }
}

/// 非空的请求注释覆盖密钥自带注释；注释里不能有换行等控制字符（会弄坏公钥行）。
fn apply_comment(key: &mut PrivateKey, comment: Option<&str>) -> Result<(), KeyError> {
    let Some(comment) = comment.map(str::trim).filter(|c| !c.is_empty()) else {
        return Ok(());
    };
    if comment.chars().any(char::is_control) {
        return Err(KeyError::Invalid);
    }
    key.set_comment(comment);
    Ok(())
}

/// 把私钥渲染成输出 JSON。
fn render(key: &PrivateKey) -> Result<Zeroizing<String>, KeyError> {
    let private_key = key
        .to_openssh(LineEnding::LF)
        .map_err(|_| KeyError::Invalid)?;
    let public_key = key
        .public_key()
        .to_openssh()
        .map_err(|_| KeyError::Invalid)?;
    let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
    let algorithm = key.algorithm();
    let output = KeyOutput {
        private_key: &private_key,
        public_key: &public_key,
        algorithm: algorithm.as_str(),
        fingerprint: &fingerprint,
        comment: key.comment().as_str_lossy(),
    };
    serde_json::to_string(&output)
        .map(Zeroizing::new)
        .map_err(|_| KeyError::Invalid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 测试用：确定种子的 OpenSSH 私钥文本。
    fn sample(seed: u8, comment: &str) -> String {
        let mut key = PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]));
        key.set_comment(comment);
        key.to_openssh(LineEnding::LF).unwrap().to_string()
    }

    #[test]
    fn inspect_keeps_own_comment_unless_overridden() {
        let pem = sample(3, "me@laptop");
        let own = inspect(&json!({"privateKey":pem}).to_string()).unwrap();
        assert_eq!(own.comment().as_str_lossy(), "me@laptop");
        let renamed = inspect(&json!({"privateKey":pem,"comment":" work "}).to_string()).unwrap();
        assert_eq!(renamed.comment().as_str_lossy(), "work");
        assert_eq!(
            own.fingerprint(HashAlg::Sha256),
            renamed.fingerprint(HashAlg::Sha256)
        );
    }

    #[test]
    fn control_characters_in_comment_are_invalid() {
        let pem = sample(4, "");
        let r = inspect(&json!({"privateKey":pem,"comment":"a\nb"}).to_string());
        assert_eq!(r.err(), Some(KeyError::Invalid));
    }

    #[test]
    fn garbage_and_bad_json_are_invalid() {
        assert_eq!(
            inspect(&json!({"privateKey":"nope"}).to_string()).err(),
            Some(KeyError::Invalid)
        );
        assert_eq!(inspect("{").err(), Some(KeyError::Invalid));
    }

    #[test]
    fn generate_rejects_other_algorithms() {
        assert_eq!(
            generate(r#"{"algorithm":"rsa"}"#).err(),
            Some(KeyError::Unsupported)
        );
        let a = generate(r#"{"algorithm":"ed25519","comment":"x"}"#).unwrap();
        let b = generate(r#"{}"#).unwrap();
        assert_ne!(
            a.fingerprint(HashAlg::Sha256),
            b.fingerprint(HashAlg::Sha256)
        );
        assert_eq!(a.algorithm(), Algorithm::Ed25519);
    }
}
