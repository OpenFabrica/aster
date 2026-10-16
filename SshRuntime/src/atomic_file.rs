//! 原子改写一个用户文件（known_hosts 用）。
//!
//! 先顺着符号链接找到真正的文件，再在它所在目录写临时文件并 rename 过去：
//! 用户把 `~/.ssh/known_hosts` 链到 dotfiles 仓库时，链接本身保持不变，改的是链接目标。
//! 已有文件保留原权限，新文件用 0600。

use std::io::Write as _;
use std::os::unix::fs::{OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};

/// 符号链接最多跟随的层数，防止链接成环。
const MAX_LINK_DEPTH: usize = 40;

/// 临时文件名的进程内序号：broker 里多个连接可能同时改写同一个文件，只靠 pid 会撞名。
static TEMP_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 顺着符号链接找到最终路径；悬空链接返回它指向的（还不存在的）路径。
pub(crate) fn resolve_symlinks(path: &Path) -> std::io::Result<PathBuf> {
    let mut current = path.to_path_buf();
    for _ in 0..MAX_LINK_DEPTH {
        match std::fs::symlink_metadata(&current) {
            Ok(meta) if meta.file_type().is_symlink() => {
                let target = std::fs::read_link(&current)?;
                // 相对链接相对于链接所在目录。
                current = match current.parent() {
                    Some(dir) if target.is_relative() => dir.join(target),
                    _ => target,
                };
            }
            _ => return Ok(current),
        }
    }
    Err(std::io::Error::other("too many levels of symbolic links"))
}

/// 用 `bytes` 原子替换 `path` 指向的文件内容。
pub(crate) fn write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let target = resolve_symlinks(path)?;
    crate::known_hosts::ensure_parent(&target)?;
    let mode = std::fs::metadata(&target)
        .map(|m| m.permissions().mode() & 0o7777)
        .unwrap_or(0o600);
    let dir = target.parent().unwrap_or(Path::new("."));
    let name = target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "known_hosts".into());
    let sequence = TEMP_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = dir.join(format!(
        ".{name}.aster-tmp-{}-{sequence}",
        std::process::id()
    ));
    let result = (|| {
        // create_new：临时路径上已有文件或链接时直接失败，不会顺着别人放的链接写出去。
        let mut file = std::fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        // open 的 mode 受 umask 影响，这里显式设回原权限。
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode))?;
        std::fs::rename(&tmp, &target)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_through_relative_symlink_and_keeps_mode() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("dotfiles")).unwrap();
        let real = dir.path().join("dotfiles/kh");
        std::fs::write(&real, "old\n").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o644)).unwrap();
        let link = dir.path().join("known_hosts");
        std::os::unix::fs::symlink("dotfiles/kh", &link).unwrap();

        write(&link, b"new\n").unwrap();

        assert!(std::fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(std::fs::read_to_string(&real).unwrap(), "new\n");
        let mode = std::fs::metadata(&real).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o644);
        // 目录里不留临时文件。
        assert_eq!(
            std::fs::read_dir(dir.path().join("dotfiles"))
                .unwrap()
                .count(),
            1
        );
    }

    #[test]
    fn new_file_gets_0600_and_link_loops_fail() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/known_hosts");
        write(&path, b"x\n").unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);

        let a = dir.path().join("a");
        let b = dir.path().join("b");
        std::os::unix::fs::symlink(&b, &a).unwrap();
        std::os::unix::fs::symlink(&a, &b).unwrap();
        assert!(write(&a, b"x").is_err());
    }
}
