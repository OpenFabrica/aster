//! `aster-ssh known-hosts list|remove`：给设置页的 known_hosts 管理界面用。
//!
//! 请求是 stdin 上的一个 JSON 对象，结果是 stdout 上的一个 JSON 对象；协议见 `PROTOCOL.md` §6。
//! 解析与匹配复用 `known_hosts.rs`，保证界面看到的和连接时校验的是同一套规则。
//! 删除带 `lineDigest`（原行的 SHA-256），文件在列出后被改过就拒绝（退出码 3），不会删错行。
//! 系统级文件只读，永远不改。

use std::ffi::CString;
use std::io::{Read as _, Write as _};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use crate::env::{expand_tilde, Paths};
use crate::known_hosts::{fingerprint, host_token, pattern_hits, Entry, Marker};

/// stdin 的大小上限。请求只有路径与主机名，64 KiB 绰绰有余。
const MAX_INPUT: u64 = 64 * 1024;

const USAGE: &str = "usage: aster-ssh known-hosts (list|remove) < request.json";

/// 要匹配的主机与端口。
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct HostPort {
    pub host: String,
    pub port: u16,
}

/// `list` 请求。字段都可省略。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ListRequest {
    #[serde(default)]
    files: Vec<String>,
    #[serde(default = "yes")]
    include_default: bool,
    #[serde(default = "yes")]
    include_global: bool,
    #[serde(default, rename = "match")]
    matches: Vec<HostPort>,
}

/// serde 缺省值：true。
fn yes() -> bool {
    true
}

/// 一个被列出的文件。
#[derive(Debug, Serialize)]
struct FileInfo {
    path: String,
    exists: bool,
    writable: bool,
    global: bool,
    error: Option<String>,
}

/// 一条可识别的记录。
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EntryInfo {
    file: String,
    line: usize,
    marker: Option<&'static str>,
    hosts: Vec<String>,
    hashed: bool,
    algorithm: String,
    fingerprint: String,
    comment: Option<String>,
    matches: Vec<HostPort>,
    line_digest: String,
}

/// 无法识别、被跳过的行。
#[derive(Debug, Serialize)]
struct SkippedLine {
    file: String,
    line: usize,
    reason: &'static str,
}

/// `list` 结果。
#[derive(Debug, Serialize)]
struct ListResponse {
    files: Vec<FileInfo>,
    entries: Vec<EntryInfo>,
    skipped: Vec<SkippedLine>,
}

/// `remove` 请求：`host` 为空删整行，否则只删该行里命中这台主机的模式。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RemoveRequest {
    file: String,
    line: usize,
    line_digest: String,
    #[serde(default)]
    host: Option<HostPort>,
}

/// 子命令失败：退出码与写到 stdout 的错误名。
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct CliError {
    code: u8,
    error: &'static str,
}

impl CliError {
    /// 退出码 1 的一般失败。
    fn other(error: &'static str) -> Self {
        Self { code: 1, error }
    }
}

/// 子命令入口。
pub fn run_cli(args: &[String]) -> ExitCode {
    let sub = match args {
        [only] if only == "list" || only == "remove" => only.as_str(),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    let paths = Paths::from_process();
    let result = read_stdin().and_then(|input| match sub {
        "list" => parse(&input).map(|req| to_json(&list(&req, &paths))),
        _ => parse(&input)
            .and_then(|req| remove(&req, &paths))
            .map(|r| to_json(&r)),
    });
    let (text, code) = match result {
        Ok(text) => (text, 0),
        Err(e) => {
            eprintln!("aster-ssh known-hosts {sub}: {}", e.error);
            (to_json(&serde_json::json!({ "error": e.error })), e.code)
        }
    };
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{text}").and_then(|_| out.flush());
    ExitCode::from(code)
}

/// 读入 stdin，超过上限时报错。
fn read_stdin() -> Result<Vec<u8>, CliError> {
    let mut buf = Vec::new();
    std::io::stdin()
        .take(MAX_INPUT + 1)
        .read_to_end(&mut buf)
        .map_err(|_| CliError::other("io"))?;
    if buf.len() as u64 > MAX_INPUT {
        return Err(CliError::other("tooLarge"));
    }
    Ok(buf)
}

/// 解析请求 JSON。
fn parse<T: for<'de> Deserialize<'de>>(input: &[u8]) -> Result<T, CliError> {
    serde_json::from_slice(input).map_err(|_| CliError::other("invalidRequest"))
}

/// 序列化结果；这些类型序列化不会失败。
fn to_json<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".into())
}

/// 原行（不含 `\n`）的 SHA-256 十六进制。
fn line_digest(line: &[u8]) -> String {
    hex::encode(Sha256::digest(line))
}

/// 用 access(2) 判断当前进程能否写入该路径。
fn can_write(path: &Path) -> bool {
    CString::new(path.as_os_str().as_bytes())
        // SAFETY: c 是以 NUL 结尾的有效 C 字符串，access 只读它。
        .map(|c| unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0)
        .unwrap_or(false)
}

/// 比较用的身份：能解析符号链接就用真实路径，否则用原路径。
fn identity(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// 是否是系统级（只读）known_hosts 文件。
fn is_global(path: &Path, paths: &Paths) -> bool {
    let id = identity(path);
    paths
        .global_known_hosts
        .iter()
        .any(|g| g == path || identity(g) == id)
}

/// 按 `\n` 切行，每行保留结尾的 `\n`（最后一行可能没有）。
fn split_lines(bytes: &[u8]) -> Vec<&[u8]> {
    bytes.split_inclusive(|b| *b == b'\n').collect()
}

/// 去掉行尾的 `\n`，`\r` 保留（它是原行的一部分，参与摘要）。
fn strip_newline(line: &[u8]) -> &[u8] {
    line.strip_suffix(b"\n").unwrap_or(line)
}

/// 列出各文件里的记录，并标出哪些记录覆盖了请求里的主机。
fn list(req: &ListRequest, paths: &Paths) -> ListResponse {
    let mut candidates: Vec<(PathBuf, bool)> = Vec::new();
    if req.include_default {
        candidates.push((paths.known_hosts.clone(), false));
    }
    for file in &req.files {
        if !file.eq_ignore_ascii_case("none") && !file.trim().is_empty() {
            candidates.push((expand_tilde(file, &paths.home), false));
        }
    }
    if req.include_global {
        candidates.extend(paths.global_known_hosts.iter().map(|g| (g.clone(), true)));
    }
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut response = ListResponse {
        files: Vec::new(),
        entries: Vec::new(),
        skipped: Vec::new(),
    };
    for (path, listed_global) in candidates {
        let id = identity(&path);
        if seen.contains(&id) {
            continue;
        }
        seen.push(id);
        let global = listed_global || is_global(&path, paths);
        list_file(&path, global, &req.matches, &mut response);
    }
    response
}

/// 读一个文件，把文件信息、记录与跳过的行追加进结果。
fn list_file(path: &Path, global: bool, wanted: &[HostPort], out: &mut ListResponse) {
    let display = path.to_string_lossy().into_owned();
    let (exists, bytes, error) = match std::fs::read(path) {
        Ok(bytes) => (true, Some(bytes), None),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (false, None, None),
        Err(e) => (path.exists(), None, Some(e.to_string())),
    };
    let writable = exists && !global && error.is_none() && {
        let real = crate::atomic_file::resolve_symlinks(path).unwrap_or_else(|_| path.into());
        can_write(&real) && real.parent().is_some_and(can_write)
    };
    out.files.push(FileInfo {
        path: display.clone(),
        exists,
        writable,
        global,
        error,
    });
    let Some(bytes) = bytes else {
        return;
    };
    for (index, raw) in split_lines(&bytes).into_iter().enumerate() {
        let raw = strip_newline(raw);
        let number = index + 1;
        let Ok(text) = std::str::from_utf8(raw) else {
            out.skipped.push(SkippedLine {
                file: display.clone(),
                line: number,
                reason: "malformed",
            });
            continue;
        };
        let trimmed = text.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let parsed = Entry::parse(text);
        let (Some(entry), Some(key)) = (
            parsed.as_ref(),
            parsed.as_ref().and_then(|e| e.key.as_ref()),
        ) else {
            out.skipped.push(SkippedLine {
                file: display.clone(),
                line: number,
                reason: if parsed.is_some() {
                    "invalidKey"
                } else {
                    "malformed"
                },
            });
            continue;
        };
        out.entries.push(EntryInfo {
            file: display.clone(),
            line: number,
            marker: entry.marker.map(|m| match m {
                Marker::Revoked => "revoked",
                Marker::CertAuthority => "certAuthority",
            }),
            hosts: entry
                .hosts
                .split(',')
                .map(|p| {
                    if p.starts_with("|1|") {
                        "(hashed)".to_string()
                    } else {
                        p.to_string()
                    }
                })
                .collect(),
            hashed: entry.hosts.split(',').any(|p| p.starts_with("|1|")),
            algorithm: entry.algorithm.to_string(),
            fingerprint: fingerprint(key),
            comment: entry.comment.map(str::to_string),
            matches: wanted
                .iter()
                .filter(|w| entry.matches(&host_token(&w.host, w.port)))
                .cloned()
                .collect(),
            line_digest: line_digest(raw),
        });
    }
}

/// `remove` 结果。
#[derive(Debug, Serialize)]
struct RemoveResponse {
    removed: &'static str,
}

/// 删除一行，或只删行里命中某主机的模式。
fn remove(req: &RemoveRequest, paths: &Paths) -> Result<RemoveResponse, CliError> {
    let path = expand_tilde(&req.file, &paths.home);
    if is_global(&path, paths) {
        return Err(CliError::other("global"));
    }
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(CliError::other("notFound"))
        }
        Err(_) => return Err(CliError::other("io")),
    };
    let (rewritten, removed) = rewrite(&bytes, req)?;
    let real = crate::atomic_file::resolve_symlinks(&path).map_err(|_| CliError::other("io"))?;
    if !can_write(&real) || !real.parent().is_some_and(can_write) {
        return Err(CliError::other("notWritable"));
    }
    crate::atomic_file::write(&path, &rewritten).map_err(|_| CliError::other("io"))?;
    Ok(RemoveResponse { removed })
}

/// 在内存里算出删除后的文件内容。其它行逐字节保留。
fn rewrite(bytes: &[u8], req: &RemoveRequest) -> Result<(Vec<u8>, &'static str), CliError> {
    const STALE: CliError = CliError {
        code: 3,
        error: "stale",
    };
    let lines = split_lines(bytes);
    let index = req.line.checked_sub(1).ok_or(STALE)?;
    let target = *lines.get(index).ok_or(STALE)?;
    let raw = strip_newline(target);
    if !line_digest(raw).eq_ignore_ascii_case(&req.line_digest) {
        return Err(STALE);
    }
    let (replacement, removed): (Option<Vec<u8>>, &'static str) = match &req.host {
        None => (None, "line"),
        Some(host) => match strip_patterns(raw, &host_token(&host.host, host.port))? {
            Some(line) => (Some(line), "pattern"),
            None => (None, "line"),
        },
    };
    let mut out = Vec::with_capacity(bytes.len());
    for (i, line) in lines.iter().enumerate() {
        if i != index {
            out.extend_from_slice(line);
        } else if let Some(new) = &replacement {
            out.extend_from_slice(new);
            out.extend_from_slice(&line[raw.len()..]);
        }
    }
    Ok((out, removed))
}

/// 从一行的主机字段里去掉命中 token 的模式。
///
/// 返回 None 表示去掉后不剩任何非取反模式，整行应删除；只剩取反模式的行什么都不匹配，留着没有意义。
/// hashed 模式命中时同样去掉。没有任何模式命中返回 `noMatch`。
fn strip_patterns(raw: &[u8], token: &str) -> Result<Option<Vec<u8>>, CliError> {
    let text = std::str::from_utf8(raw).map_err(|_| CliError::other("malformed"))?;
    let entry = Entry::parse(text).ok_or(CliError::other("malformed"))?;
    let kept: Vec<&str> = entry
        .hosts
        .split(',')
        .filter(|p| !pattern_hits(p, token))
        .collect();
    if kept.len() == entry.hosts.split(',').count() {
        return Err(CliError::other("noMatch"));
    }
    if kept.iter().all(|p| p.starts_with('!')) {
        return Ok(None);
    }
    // hosts 是原行的子串，按它的字节位置只换主机字段，其余字节原样保留。
    let start = entry.hosts.as_ptr() as usize - text.as_ptr() as usize;
    let end = start + entry.hosts.len();
    let mut line = Vec::with_capacity(raw.len());
    line.extend_from_slice(&raw[..start]);
    line.extend_from_slice(kept.join(",").as_bytes());
    line.extend_from_slice(&raw[end..]);
    Ok(Some(line))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造删除请求，摘要按给定行计算。
    fn req(line: usize, raw: &str, host: Option<(&str, u16)>) -> RemoveRequest {
        RemoveRequest {
            file: String::new(),
            line,
            line_digest: line_digest(raw.as_bytes()),
            host: host.map(|(h, p)| HostPort {
                host: h.into(),
                port: p,
            }),
        }
    }

    const KEY: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBZ5j6ScV9rrWcZDmAwEUXoW3W8OHp4u7wv/ckmQ3lmF";

    #[test]
    fn pattern_removal_keeps_rest_of_line_and_crlf() {
        let line = format!("a,[b]:2222,c {KEY} note\r");
        let file = format!("x {KEY}\n{line}\ny {KEY}");
        let (out, removed) = rewrite(file.as_bytes(), &req(2, &line, Some(("b", 2222)))).unwrap();
        assert_eq!(removed, "pattern");
        assert_eq!(
            String::from_utf8(out).unwrap(),
            format!("x {KEY}\na,c {KEY} note\r\ny {KEY}")
        );
    }

    #[test]
    fn last_pattern_or_negations_only_removes_line() {
        let line = format!("a,!z {KEY}");
        let file = format!("{line}\nkeep {KEY}\n");
        let (out, removed) = rewrite(file.as_bytes(), &req(1, &line, Some(("a", 22)))).unwrap();
        assert_eq!(removed, "line");
        assert_eq!(String::from_utf8(out).unwrap(), format!("keep {KEY}\n"));
    }

    #[test]
    fn stale_and_no_match() {
        let line = format!("a {KEY}");
        let file = format!("{line}\n");
        let mut bad = req(1, &line, None);
        bad.line_digest = "00".into();
        assert_eq!(rewrite(file.as_bytes(), &bad).unwrap_err().code, 3);
        assert_eq!(
            rewrite(file.as_bytes(), &req(2, &line, None))
                .unwrap_err()
                .code,
            3
        );
        assert_eq!(
            rewrite(file.as_bytes(), &req(0, &line, None))
                .unwrap_err()
                .code,
            3
        );
        assert_eq!(
            rewrite(file.as_bytes(), &req(1, &line, Some(("zz", 22)))).unwrap_err(),
            CliError::other("noMatch")
        );
    }
}
