//! `aster-ssh keys` 命令行的端到端测试：跑真实二进制，请求走 stdin，结果从 stdout 读。
//! 加密密钥与 RSA PEM 用系统 `ssh-keygen` 现场生成（只用于测试，用完随临时目录删除）。

use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use serde_json::{json, Value};

/// 运行 `aster-ssh keys <sub>`，把 `input` 写进 stdin。
fn run(sub: &str, input: &str) -> Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_aster-ssh"))
        .args(["keys", sub])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn aster-ssh");
    // 子命令可能不读完 stdin 就退出（用法错误、超长输入），写入失败（EPIPE）不算测试失败。
    let _ = child.stdin.take().unwrap().write_all(input.as_bytes());
    let out = child.wait_with_output().expect("wait aster-ssh");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("PRIVATE KEY"),
        "stderr leaked key material: {stderr}"
    );
    out
}

/// 成功输出解析成 JSON。
fn ok_json(out: &Output) -> Value {
    assert_eq!(
        out.status.code(),
        Some(0),
        "stdout: {}",
        String::from_utf8_lossy(&out.stdout)
    );
    serde_json::from_slice(&out.stdout).expect("json")
}

/// 失败输出的错误码（退出码必须是 1）。
fn error_code(out: &Output) -> String {
    assert_eq!(out.status.code(), Some(1));
    let v: Value = serde_json::from_slice(&out.stdout).expect("error json");
    v["error"].as_str().unwrap().to_string()
}

/// 用 ssh-keygen 在 `dir/name` 生成私钥，返回私钥文本。
fn keygen(dir: &Path, name: &str, args: &[&str], passphrase: &str) -> String {
    let path = dir.join(name);
    let status = Command::new("ssh-keygen")
        .args(args)
        .args(["-q", "-N", passphrase, "-C", "fixture@test", "-f"])
        .arg(&path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .expect("ssh-keygen");
    assert!(status.success());
    std::fs::read_to_string(path).unwrap()
}

/// 用 ssh-keygen 算公钥文件的 SHA256 指纹。
fn keygen_fingerprint(dir: &Path, public_key: &str) -> String {
    let path = dir.join("check.pub");
    std::fs::write(&path, format!("{public_key}\n")).unwrap();
    let out = Command::new("ssh-keygen")
        .args(["-l", "-E", "sha256", "-f"])
        .arg(&path)
        .output()
        .expect("ssh-keygen -l");
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.split_whitespace().nth(1).unwrap().to_string()
}

#[test]
fn generate_then_inspect_round_trips() {
    let dir = tempfile::tempdir().unwrap();
    let generated = ok_json(&run(
        "generate",
        &json!({"algorithm":"ed25519","comment":"me@mac"}).to_string(),
    ));
    let private_key = generated["privateKey"].as_str().unwrap();
    assert!(private_key.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----\n"));
    assert!(!private_key.contains('\r'));
    assert_eq!(generated["algorithm"], "ssh-ed25519");
    assert_eq!(generated["comment"], "me@mac");
    let public_key = generated["publicKey"].as_str().unwrap();
    assert!(public_key.starts_with("ssh-ed25519 ") && public_key.ends_with(" me@mac"));
    let fingerprint = generated["fingerprint"].as_str().unwrap();
    assert!(fingerprint.starts_with("SHA256:"));
    assert_eq!(keygen_fingerprint(dir.path(), public_key), fingerprint);

    let inspected = ok_json(&run(
        "inspect",
        &json!({"privateKey":private_key,"passphrase":null,"comment":null}).to_string(),
    ));
    assert_eq!(inspected["fingerprint"], generated["fingerprint"]);
    assert_eq!(inspected["publicKey"], generated["publicKey"]);
}

#[test]
fn encrypted_key_needs_the_right_passphrase() {
    let dir = tempfile::tempdir().unwrap();
    let pem = keygen(dir.path(), "enc", &["-t", "ed25519"], "pp-correct");
    assert_eq!(
        error_code(&run("inspect", &json!({"privateKey":pem}).to_string())),
        "encrypted"
    );
    assert_eq!(
        error_code(&run(
            "inspect",
            &json!({"privateKey":pem,"passphrase":"pp-wrong"}).to_string()
        )),
        "wrongPassphrase"
    );
    let ok = ok_json(&run(
        "inspect",
        &json!({"privateKey":pem,"passphrase":"pp-correct"}).to_string(),
    ));
    // 输出是解密后的明文 OpenSSH 私钥：不带 passphrase 再 inspect 一次也能解开。
    let plain = ok["privateKey"].as_str().unwrap();
    assert_eq!(ok["comment"], "fixture@test");
    let again = ok_json(&run("inspect", &json!({"privateKey":plain}).to_string()));
    assert_eq!(again["fingerprint"], ok["fingerprint"]);
    let public = std::fs::read_to_string(dir.path().join("enc.pub")).unwrap();
    assert_eq!(
        keygen_fingerprint(dir.path(), public.trim()),
        ok["fingerprint"].as_str().unwrap()
    );
}

#[test]
fn rsa_pem_keys_are_normalized_to_openssh() {
    let dir = tempfile::tempdir().unwrap();
    let pem = keygen(
        dir.path(),
        "rsa",
        &["-t", "rsa", "-b", "2048", "-m", "PEM"],
        "",
    );
    assert!(pem.starts_with("-----BEGIN RSA PRIVATE KEY-----"));
    let ok = ok_json(&run(
        "inspect",
        &json!({"privateKey":pem,"comment":"imported"}).to_string(),
    ));
    assert_eq!(ok["algorithm"], "ssh-rsa");
    assert_eq!(ok["comment"], "imported");
    assert!(ok["privateKey"]
        .as_str()
        .unwrap()
        .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
    let public = std::fs::read_to_string(dir.path().join("rsa.pub")).unwrap();
    assert_eq!(
        keygen_fingerprint(dir.path(), public.trim()),
        ok["fingerprint"].as_str().unwrap()
    );

    // ssh-keygen 的旧式 PEM 加密用 AES-128-CBC，passphrase 对才能解开。
    let enc = keygen(
        dir.path(),
        "rsa-enc",
        &["-t", "rsa", "-b", "2048", "-m", "PEM"],
        "pp-rsa-5",
    );
    assert_eq!(
        error_code(&run("inspect", &json!({"privateKey":enc}).to_string())),
        "encrypted"
    );
    assert_eq!(
        error_code(&run(
            "inspect",
            &json!({"privateKey":enc,"passphrase":"nope-nope"}).to_string()
        )),
        "wrongPassphrase"
    );
    let ok = ok_json(&run(
        "inspect",
        &json!({"privateKey":enc,"passphrase":"pp-rsa-5"}).to_string(),
    ));
    assert_eq!(ok["algorithm"], "ssh-rsa");
}

#[test]
fn ecdsa_keys_are_supported() {
    let dir = tempfile::tempdir().unwrap();
    let pem = keygen(dir.path(), "ec", &["-t", "ecdsa", "-b", "256"], "");
    let ok = ok_json(&run("inspect", &json!({"privateKey":pem}).to_string()));
    assert_eq!(ok["algorithm"], "ecdsa-sha2-nistp256");
}

#[test]
fn bad_input_and_usage() {
    assert_eq!(
        error_code(&run("inspect", r#"{"privateKey":"not a key"}"#)),
        "invalid"
    );
    assert_eq!(error_code(&run("inspect", "not json")), "invalid");
    assert_eq!(
        error_code(&run("generate", r#"{"algorithm":"rsa"}"#)),
        "unsupported"
    );
    // 旧式 DES 加密 PEM：russh 解不了，明确报 unsupported 而不是 invalid。
    let des = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: DES-EDE3-CBC,0011223344556677\n\nAAAA\n-----END RSA PRIVATE KEY-----\n";
    assert_eq!(
        error_code(&run("inspect", &json!({"privateKey":des}).to_string())),
        "unsupported"
    );
    let big = "x".repeat(70 * 1024);
    assert_eq!(error_code(&run("inspect", &big)), "invalid");
    let usage = run("bogus", "{}");
    assert_eq!(usage.status.code(), Some(2));
    assert!(usage.stdout.is_empty());
}
