import Testing

@testable import AsterCore

@Test("带凭据的命令被识别：选项值、环境变量、头、密钥形态、URL 密码")
func secretDetectorFlagsCredentials() {
  let positives = [
    "curl --token abc123 https://example.test",
    "curl --api-key=abc123 https://example.test",
    "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG",
    "DATABASE_PASSWORD=hunter2 ./run.sh",
    "curl -H \"Authorization: Bearer eyJhbGciOi\" https://api.test",
    "mysql -uroot -phunter2 shop",
    "aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE",
    "gh auth login --with-token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "echo github_pat_11AAAAAAA0abcdefghijklmnopqrstuvwxyz > f",
    "OPENAI_KEY=1 python x.py sk-abcdefghijklmnopqrstuvwxyz",
    "git clone https://user:s3cret@github.com/org/repo.git",
    "ssh-add - <<< '-----BEGIN OPENSSH PRIVATE KEY-----'",
  ]
  for command in positives {
    #expect(AutocompleteSecretDetector.containsSecret(command), "\(command)")
  }
}

@Test("普通命令不误判：提到 token 的提交信息、变量引用、路径、仅选项名")
func secretDetectorIgnoresOrdinaryCommands() {
  let negatives = [
    "",
    "git commit -m \"token refresh\"",
    "echo $AWS_SECRET_ACCESS_KEY",
    "TOKEN=$TOKEN ./deploy.sh",
    "export PATH=/usr/local/bin:$PATH",
    "grep -r password src/",
    "curl --token",
    "mysql -u root -p shop",
    "git clone https://github.com/org/repo.git",
    "open https://user@example.test/path",
    "ls -la ~/projects",
  ]
  for command in negatives {
    #expect(!AutocompleteSecretDetector.containsSecret(command), "\(command)")
  }
}
