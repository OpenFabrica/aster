//! `aster-ssh known-hosts` 命令行的端到端测试：用临时 HOME 跑真实二进制，检查 JSON、退出码与文件内容。

use std::fs;
use std::io::Write as _;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use data_encoding::BASE64;
use hmac::{Hmac, KeyInit, Mac};
use serde_json::{json, Value};
use sha1::Sha1;

const K1: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOffa1HlqZqds7U1L8+NHdRjrwadOsihIDNOkKCcW19p";
const K1_FP: &str = "SHA256:6Sql5QxD07rxFJHonX+GHEEMxBa49FICAKGh05DgSaU";
const K2: &str = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBoX1VfllgZpgrnEtfwdp34AaQ264rEqtCyGqaf3MCJl";

/// 在指定 HOME 下运行 `aster-ssh known-hosts <sub>`，stdin 写入请求。
fn run(home: &Path, sub: &str, request: &Value) -> (Output, Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_aster-ssh"))
        .args(["known-hosts", sub])
        .env("HOME", home)
        .env_remove("ASTER_SSH_HOME")
        .env_remove("ASTER_SSH_KNOWN_HOSTS")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn aster-ssh");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(request.to_string().as_bytes())
        .unwrap();
    let out = child.wait_with_output().expect("wait");
    let value = serde_json::from_slice(&out.stdout).unwrap_or(Value::Null);
    (out, value)
}

/// 造一个带 `~/.ssh/known_hosts` 的临时 HOME。
fn home_with(known_hosts: &str) -> tempfile::TempDir {
    let home = tempfile::tempdir().expect("tempdir");
    fs::create_dir_all(home.path().join(".ssh")).expect("mkdir");
    fs::write(home.path().join(".ssh/known_hosts"), known_hosts).expect("write");
    home
}

/// OpenSSH hashed 主机模式 `|1|salt|hmac`。
fn hashed(token: &str) -> String {
    let salt = [7u8; 20];
    let mac = <Hmac<Sha1> as KeyInit>::new_from_slice(&salt)
        .unwrap()
        .chain_update(token.as_bytes())
        .finalize()
        .into_bytes();
    format!("|1|{}|{}", BASE64.encode(&salt), BASE64.encode(&mac))
}

/// 只列默认文件的请求。
fn list_request(matches: Value) -> Value {
    json!({"includeGlobal": false, "match": matches})
}

#[test]
fn list_reports_entries_markers_matches_and_skipped() {
    let text = format!(
        "# comment\n\
         plain.example {K1} me@laptop\n\
         [port.example]:2222,10.0.0.5 {K2}\n\
         {} {K1}\n\
         @revoked bad.example {K2}\n\
         @cert-authority *.corp {K1}\n\
         broken-line\n\
         h ssh-ed25519 notbase64!!\n\
         \n",
        hashed("[hidden.example]:2200")
    );
    let home = home_with(&text);
    let (out, v) = run(
        home.path(),
        "list",
        &list_request(json!([
            {"host": "port.example", "port": 2222},
            {"host": "hidden.example", "port": 2200},
            {"host": "a.corp", "port": 22},
            {"host": "plain.example", "port": 2222}
        ])),
    );
    assert_eq!(out.status.code(), Some(0), "{v}");
    let file = home.path().join(".ssh/known_hosts");
    assert_eq!(v["files"][0]["path"], file.to_string_lossy().as_ref());
    assert_eq!(v["files"][0]["exists"], true);
    assert_eq!(v["files"][0]["writable"], true);
    assert_eq!(v["files"][0]["global"], false);
    assert_eq!(v["files"].as_array().unwrap().len(), 1);

    let entries = v["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 5, "{v}");
    let plain = &entries[0];
    assert_eq!(plain["line"], 2);
    assert_eq!(plain["hosts"], json!(["plain.example"]));
    assert_eq!(plain["algorithm"], "ssh-ed25519");
    assert_eq!(plain["fingerprint"], K1_FP);
    assert_eq!(plain["comment"], "me@laptop");
    assert_eq!(plain["marker"], Value::Null);
    assert_eq!(plain["matches"], json!([]));
    assert_eq!(plain["lineDigest"].as_str().unwrap().len(), 64);

    assert_eq!(
        entries[1]["hosts"],
        json!(["[port.example]:2222", "10.0.0.5"])
    );
    assert_eq!(
        entries[1]["matches"],
        json!([{"host": "port.example", "port": 2222}])
    );
    assert_eq!(entries[1]["comment"], Value::Null);

    assert_eq!(entries[2]["hosts"], json!(["(hashed)"]));
    assert_eq!(entries[2]["hashed"], true);
    assert_eq!(
        entries[2]["matches"],
        json!([{"host": "hidden.example", "port": 2200}])
    );

    assert_eq!(entries[3]["marker"], "revoked");
    assert_eq!(entries[4]["marker"], "certAuthority");
    assert_eq!(
        entries[4]["matches"],
        json!([{"host": "a.corp", "port": 22}])
    );

    assert_eq!(
        v["skipped"],
        json!([
            {"file": file.to_string_lossy(), "line": 7, "reason": "malformed"},
            {"file": file.to_string_lossy(), "line": 8, "reason": "invalidKey"}
        ])
    );
}

#[test]
fn list_expands_and_dedupes_files_and_marks_missing() {
    let home = home_with(&format!("a {K1}\n"));
    let (out, v) = run(
        home.path(),
        "list",
        &json!({"files": ["~/.ssh/known_hosts", "~/missing", "none"], "includeGlobal": false}),
    );
    assert_eq!(out.status.code(), Some(0));
    let files = v["files"].as_array().unwrap();
    assert_eq!(files.len(), 2, "{v}");
    assert_eq!(files[1]["exists"], false);
    assert_eq!(files[1]["writable"], false);
    assert_eq!(v["entries"].as_array().unwrap().len(), 1);

    let (_, v) = run(home.path(), "list", &json!({}));
    assert!(v["files"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f["path"] == "/etc/ssh/ssh_known_hosts"
            && f["global"] == true
            && f["writable"] == false));
}

/// 先 list 拿到某行的摘要。
fn digest_of(home: &Path, line: usize) -> String {
    let (_, v) = run(home, "list", &list_request(json!([])));
    v["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["line"] == line)
        .expect("entry")["lineDigest"]
        .as_str()
        .unwrap()
        .to_string()
}

#[test]
fn remove_whole_line_keeps_other_lines_byte_identical() {
    let text = format!("# keep me\r\nfirst {K1}\r\nsecond {K2}\nthird {K1}");
    let home = home_with(&text);
    let file = home.path().join(".ssh/known_hosts");
    let digest = digest_of(home.path(), 3);
    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": file, "line": 3, "lineDigest": digest, "host": null}),
    );
    assert_eq!(out.status.code(), Some(0), "{v}");
    assert_eq!(v, json!({"removed": "line"}));
    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        format!("# keep me\r\nfirst {K1}\r\nthird {K1}")
    );
}

#[test]
fn remove_pattern_from_multi_host_line() {
    let text = format!("a.example,[b.example]:2200,c.example {K1} note\nz {K2}\n");
    let home = home_with(&text);
    let file = home.path().join(".ssh/known_hosts");
    let digest = digest_of(home.path(), 1);
    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": "~/.ssh/known_hosts", "line": 1, "lineDigest": digest,
                "host": {"host": "b.example", "port": 2200}}),
    );
    assert_eq!(out.status.code(), Some(0), "{v}");
    assert_eq!(v, json!({"removed": "pattern"}));
    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        format!("a.example,c.example {K1} note\nz {K2}\n")
    );

    // 只剩一个模式时按主机删除会删掉整行。
    let text = format!("{} {K1}\n", hashed("only.example"));
    let home = home_with(&text);
    let digest = digest_of(home.path(), 1);
    let (_, v) = run(
        home.path(),
        "remove",
        &json!({"file": "~/.ssh/known_hosts", "line": 1, "lineDigest": digest,
                "host": {"host": "only.example", "port": 22}}),
    );
    assert_eq!(v, json!({"removed": "line"}));
    assert_eq!(
        fs::read_to_string(home.path().join(".ssh/known_hosts")).unwrap(),
        ""
    );
}

#[test]
fn stale_digest_exits_3_and_leaves_file_alone() {
    let text = format!("a {K1}\n");
    let home = home_with(&text);
    let file = home.path().join(".ssh/known_hosts");
    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": file, "line": 1, "lineDigest": "0".repeat(64)}),
    );
    assert_eq!(out.status.code(), Some(3));
    assert_eq!(v, json!({"error": "stale"}));
    let (out, _) = run(
        home.path(),
        "remove",
        &json!({"file": file, "line": 9, "lineDigest": "0".repeat(64)}),
    );
    assert_eq!(out.status.code(), Some(3));
    assert_eq!(fs::read_to_string(&file).unwrap(), text);

    let digest = digest_of(home.path(), 1);
    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": file, "line": 1, "lineDigest": digest, "host": {"host": "zz", "port": 22}}),
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(v, json!({"error": "noMatch"}));
}

#[test]
fn remove_through_symlink_preserves_the_link() {
    let home = tempfile::tempdir().unwrap();
    fs::create_dir_all(home.path().join(".ssh")).unwrap();
    fs::create_dir_all(home.path().join("dotfiles")).unwrap();
    let real = home.path().join("dotfiles/known_hosts");
    fs::write(&real, format!("a {K1}\nb {K2}\n")).unwrap();
    let link = home.path().join(".ssh/known_hosts");
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let digest = digest_of(home.path(), 1);
    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": link, "line": 1, "lineDigest": digest}),
    );
    assert_eq!(out.status.code(), Some(0), "{v}");
    assert!(fs::symlink_metadata(&link)
        .unwrap()
        .file_type()
        .is_symlink());
    assert_eq!(fs::read_to_string(&real).unwrap(), format!("b {K2}\n"));
}

#[test]
fn global_missing_and_bad_requests_are_refused() {
    let home = home_with("");
    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": "/etc/ssh/ssh_known_hosts", "line": 1, "lineDigest": "00"}),
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(v, json!({"error": "global"}));

    let (out, v) = run(
        home.path(),
        "remove",
        &json!({"file": "~/nope", "line": 1, "lineDigest": "00"}),
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(v, json!({"error": "notFound"}));

    let (out, v) = run(home.path(), "remove", &json!({"line": "x"}));
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(v, json!({"error": "invalidRequest"}));

    let bogus = Command::new(env!("CARGO_BIN_EXE_aster-ssh"))
        .args(["known-hosts", "bogus"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(bogus.status.code(), Some(2));
}
