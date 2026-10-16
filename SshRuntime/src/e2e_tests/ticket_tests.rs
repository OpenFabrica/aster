// 端到端：启动票据。没有 App 签发的有效票据，OPEN 在解析目标之前就被拒绝，服务器不会被连接。

use std::sync::atomic::Ordering;

use super::*;
use crate::test_support::{FakeConfig, FakeSshd};

/// accept_none 服务器 + 已同步为 "h" 的规格。
async fn open_server() -> (FakeSshd, Harness) {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    (server, h)
}

/// 断言一次运行被票据校验拒绝。
fn assert_ticket_rejected(run: &Run) {
    match &run.outcome {
        Outcome::Failed(f) => assert_eq!(
            (failure_kind(&run.outcome).as_str(), f.detail.as_str()),
            ("authenticationRequired", "invalid launch ticket")
        ),
        Outcome::Exit(e) => panic!("expected ticket rejection, got exit {e:?}"),
    }
}

/// 合法票据放行；同一张票再用一次被拒（一次性）。
#[tokio::test]
async fn a_ticket_opens_once_and_a_replay_is_refused() {
    let (server, h) = open_server().await;
    let mut open = open_host("h", Some("exit 7"), false);
    open.ticket = Some(fresh_ticket());
    let run = h.run(open.clone(), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 7);
    let replay = h.run(open, vec![]).await;
    assert_ticket_rejected(&replay);
    assert_eq!(server.stats.execs.lock().unwrap().len(), 1);
}

/// 缺票据、伪造、过期都在连接服务器之前被拒。
#[tokio::test]
async fn missing_forged_and_expired_tickets_never_reach_the_server() {
    let (server, h) = open_server().await;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;
    let nonce = "abcdefabcdefabcdefabcdefabcdef01";
    let cases = [
        // 空字符串等同缺失（夹具只在 None 时自动签票）。
        String::new(),
        crate::tickets::mint_now(&[1u8; 32], nonce),
        crate::tickets::mint(&TICKET_KEY, nonce, now - 1_000),
    ];
    for ticket in cases {
        let mut open = open_host("h", Some("exit 0"), false);
        open.ticket = Some(ticket);
        assert_ticket_rejected(&h.run(open, vec![]).await);
    }
    // 未知主机 ID 也一样：先验票，不透露主机是否存在。
    let mut open = open_host("nope", Some("exit 0"), false);
    open.ticket = Some(String::new());
    assert_ticket_rejected(&h.run(open, vec![]).await);
    assert_eq!(server.stats.connections.load(Ordering::SeqCst), 0);
}

/// 调试开关关掉校验后，不带票据也能连接。
#[tokio::test]
async fn the_debug_switch_turns_checks_off() {
    let (_server, h) = open_server().await;
    h.broker.tickets().disable();
    let mut open = open_host("h", Some("exit 3"), false);
    open.ticket = Some(String::new());
    assert_eq!(exit_status(&h.run(open, vec![]).await.outcome), 3);
}
