import Foundation
import Testing

@testable import AsterCore

@Suite("agent 命令审计脱敏")
struct AgentHostCommandRedactorTests {
  /// 必须脱敏：原始秘密值不能出现在结果里。
  @Test(
    "凭据值被替换",
    arguments: [
      ("mysql -uroot -pS3cretPass db", "S3cretPass"),
      ("deploy --password=hunter2 --env prod", "hunter2"),
      ("deploy --token abcdef123456 --env prod", "abcdef123456"),
      ("cli --api-key='k-123 456'", "k-123 456"),
      ("DB_PASSWORD=hunter2 ./migrate", "hunter2"),
      ("export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI", "wJalrXUtnFEMI"),
      ("STRIPE_KEY=sk_live_value ./charge", "sk_live_value"),
      ("git clone https://bob:p4ss@github.com/x/y.git", "p4ss"),
      ("curl -H 'Authorization: Bearer eyJhbGciOi' https://x", "eyJhbGciOi"),
      ("echo ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
      ("cat <<'EOF'\n-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nEOF", "AAAA"),
    ])
  func redactsSecrets(command: String, secret: String) {
    let result = AgentHostCommandRedactor.redact(command)
    #expect(result.redacted, "\(command)")
    #expect(!result.text.contains(secret), "\(result.text)")
  }

  /// 不该脱敏：公开标识与普通命令原样保留，排查时需要它们。
  @Test(
    "公开标识与普通命令原样保留",
    arguments: [
      "AWS_ACCESS_KEY_ID=AKIDEXAMPLE ./sync",
      "GPG_KEY_ID=ABCD1234 make sign",
      "SSH_PUBLIC_KEY=ssh-ed25519 ./install",
      "PASSWORD=$DB_PASS ./migrate",
      "ssh -p2222 host uptime",
      "systemctl status nginx --no-pager",
      "KEYBOARD=us setup",
      "git log --oneline -5",
      // ASTER-A：含 `http://…${VAR}…` 的命令曾让正式包在脱敏时闪退。
      #"curl -s -w "%{http_code}\n" http://127.0.0.1:${XR_PORT:-8080}/healthz; echo ok"#,
    ])
  func keepsPublicValues(command: String) {
    let result = AgentHostCommandRedactor.redact(command)
    #expect(!result.redacted, "\(result.text)")
    #expect(result.text == command)
  }

  @Test("变量名判定：KEY 作为独立一段才算，公开后缀除外")
  func secretNames() {
    #expect(AgentHostCommandRedactor.isSecretName("STRIPE_KEY"))
    #expect(AgentHostCommandRedactor.isSecretName("github_token"))
    #expect(!AgentHostCommandRedactor.isSecretName("MONKEY"))
    #expect(!AgentHostCommandRedactor.isSecretName("DEPLOY_KEY_ID"))
    #expect(!AgentHostCommandRedactor.isSecretName("TOKEN_TYPE"))
  }
}
