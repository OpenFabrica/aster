// 端到端：保险库密钥认证（私钥由 App 经 auth.request kind=privateKey 提供）。

use super::*;
use crate::protocol::{AuthMode, VaultKeyRef};
use crate::test_support::{key_from_seed, FakeConfig, FakeSshd};

/// 由种子造一条保险库引用，公钥行带注释（注释不影响比对）。
fn vault_ref(id: &str, seed: u8) -> VaultKeyRef {
    let mut public = key_from_seed(seed).public_key().clone();
    public.set_comment("vault@aster");
    VaultKeyRef {
        id: id.into(),
        public_key: public.to_openssh().unwrap(),
    }
}

/// 只接受给定种子公钥的测试服务器。
async fn server_accepting(seeds: &[u8]) -> FakeSshd {
    FakeSshd::start(FakeConfig {
        authorized_keys: seeds
            .iter()
            .map(|s| key_from_seed(*s).public_key().clone())
            .collect(),
        ..Default::default()
    })
    .await
}

#[tokio::test]
async fn vault_key_authenticates_without_a_prompt() {
    let server = server_accepting(&[61]).await;
    let h = Harness::new().await;
    let mut s = spec(server.port);
    s.vault_keys = vec![vault_ref("K-1", 61)];
    h.sync(&[("h", &s)]).await;
    h.script
        .lock()
        .unwrap()
        .private_keys
        .push_back(Some(openssh_key(61, None)));

    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let requests = h.events_of("auth.request");
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0]["kind"], "privateKey");
    assert_eq!(requests[0]["vaultKeyID"], "K-1");
    assert_eq!(requests[0]["hostID"], "h");
    // 即使 OPEN 是交互式的，保险库请求也标成非交互，App 从钥匙串直接作答。
    assert_eq!(requests[0]["interactive"], false);
    assert!(requests[0].get("keyFile").is_none_or(Value::is_null));
    let results: Vec<bool> = h
        .events_of("auth.result")
        .iter()
        .map(|e| e["accepted"].as_bool().unwrap())
        .collect();
    assert_eq!(results, vec![true]);
    assert_logs_free_of(&["PRIVATE KEY"]);
}

#[tokio::test]
async fn mismatched_private_key_is_never_offered() {
    // 服务器认 62，但 App 给 K-1（登记公钥是 61）回的是 62：公钥对不上，不能拿去认证。
    let server = server_accepting(&[62]).await;
    let h = Harness::new().await;
    let mut s = spec(server.port);
    s.auth = AuthMode::PublicKey;
    s.vault_keys = vec![vault_ref("K-1", 61)];
    h.sync(&[("h", &s)]).await;
    h.script
        .lock()
        .unwrap()
        .private_keys
        .push_back(Some(openssh_key(62, None)));

    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "authenticationRequired");
    assert!(server.stats.offered_keys.lock().unwrap().is_empty());
    let results: Vec<bool> = h
        .events_of("auth.result")
        .iter()
        .map(|e| e["accepted"].as_bool().unwrap())
        .collect();
    assert_eq!(results, vec![false]);
}

#[tokio::test]
async fn null_answer_falls_through_to_the_next_key_and_method() {
    let server = server_accepting(&[64]).await;
    let h = Harness::new().await;
    let path = h.write("id_file", &openssh_key(64, None));
    let mut s = spec(server.port);
    s.vault_keys = vec![vault_ref("K-gone", 63), vault_ref("K-ok", 64)];
    s.identity_files = vec![path_str(&path)];
    h.sync(&[("h", &s)]).await;
    // 第一把钥匙串里没有（null）：只跳过这一把，不取消整个认证。
    h.script
        .lock()
        .unwrap()
        .private_keys
        .extend([None, Some(openssh_key(64, None))]);

    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let ids: Vec<Value> = h
        .events_of("auth.request")
        .iter()
        .map(|e| e["vaultKeyID"].clone())
        .collect();
    assert_eq!(ids, vec![json!("K-gone"), json!("K-ok")]);
}

#[tokio::test]
async fn null_answer_for_every_vault_key_continues_with_identity_files() {
    let server = server_accepting(&[66]).await;
    let h = Harness::new().await;
    let path = h.write("id_file", &openssh_key(66, None));
    let mut s = spec(server.port);
    s.auth = AuthMode::PublicKey;
    s.vault_keys = vec![vault_ref("K-1", 65)];
    s.identity_files = vec![path_str(&path)];
    h.sync(&[("h", &s)]).await;

    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert_eq!(h.events_of("auth.request").len(), 1);
}

#[tokio::test]
async fn default_keys_are_not_read_when_vault_keys_are_configured() {
    let server = server_accepting(&[67]).await;
    let h = Harness::new().await;
    // 主目录里有一把服务器认的默认密钥，但配置了保险库密钥后不该再去碰它。
    std::fs::create_dir_all(h.dir.path().join(".ssh")).unwrap();
    h.write(".ssh/id_ed25519", &openssh_key(67, None));
    let mut s = spec(server.port);
    s.auth = AuthMode::PublicKey;
    s.vault_keys = vec![vault_ref("K-1", 68)];
    let mut plain = spec(server.port);
    plain.auth = AuthMode::PublicKey;
    plain.user = "plain".into();
    h.sync(&[("vault", &s), ("plain", &plain)]).await;

    let run = h
        .run(open_host("vault", Some("exit 0"), false), vec![])
        .await;
    assert_eq!(failure_kind(&run.outcome), "authenticationRequired");
    assert!(server.stats.offered_keys.lock().unwrap().is_empty());

    // 对照：没有保险库密钥时默认密钥照常可用。
    let run = h
        .run(open_host("plain", Some("exit 0"), false), vec![])
        .await;
    assert_eq!(exit_status(&run.outcome), 0);
}

#[tokio::test]
async fn vault_keys_are_tried_before_the_agent() {
    let agent_key = key_from_seed(70);
    let server = server_accepting(&[69, 70]).await;
    let h = Harness::with_agent(std::slice::from_ref(&agent_key)).await;
    let mut s = spec(server.port);
    s.vault_keys = vec![vault_ref("K-1", 69)];
    h.sync(&[("h", &s)]).await;
    h.script
        .lock()
        .unwrap()
        .private_keys
        .push_back(Some(openssh_key(69, None)));

    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let offered = server.stats.offered_keys.lock().unwrap().clone();
    assert_eq!(offered.first(), Some(key_from_seed(69).public_key()));
    assert!(!offered.contains(agent_key.public_key()));
}

#[tokio::test]
async fn identities_only_lets_the_agent_sign_with_vault_public_keys_only() {
    let other = key_from_seed(71);
    let vault = key_from_seed(72);
    let server = server_accepting(&[72]).await;
    // agent 里先放一把无关的钥匙：没有过滤时它会先被递出去。
    let h = Harness::with_agent(&[other.clone(), vault.clone()]).await;
    let mut s = spec(server.port);
    s.identities_only = true;
    s.vault_keys = vec![vault_ref("K-1", 72)];
    h.sync(&[("h", &s)]).await;
    // 钥匙串里取不到（null），只能靠 agent 里同一把公钥签名。
    h.script.lock().unwrap().private_keys.push_back(None);

    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let offered = server.stats.offered_keys.lock().unwrap().clone();
    assert!(offered.contains(vault.public_key()));
    assert!(!offered.contains(other.public_key()));
}
