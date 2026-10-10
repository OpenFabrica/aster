import Testing

@testable import AsterCore

private func history(_ command: String, score: Double, kind: AutocompleteCandidateKind = .learnedCommand) -> AutocompleteCandidate {
  AutocompleteCandidate(insertText: command, kind: kind, score: score, replacement: .fullLine)
}

@Test("多条同样可能的历史整行只预览共同的下一个词")
func sharedPrefixPreviewsCommonNextWord() {
  let candidates = [history("git commit -m", score: 300), history("git commit --amend", score: 295)]
  #expect(AutocompleteSharedPrefix.ghost(candidates: candidates, line: "git ") == "commit ")
  #expect(AutocompleteSharedPrefix.ghost(candidates: candidates, line: "git co") == "mmit ")
  // 两条都以 `checkout` 开头、后面不同：补完这个词连同空格。
  let branches = [history("git checkout main", score: 300), history("git checkout dev", score: 300)]
  #expect(AutocompleteSharedPrefix.ghost(candidates: branches, line: "git ch") == "eckout ")
  // 槽位学习把 `commit` 这个词排在整行之前：它正好是共同词，照样预览。
  let tokenFirst = [
    AutocompleteCandidate(insertText: "commit", kind: .argument, score: 700, replacement: .currentToken(start: 4)),
    history("git commit -m", score: 588), history("git commit --amend", score: 586),
  ]
  #expect(AutocompleteSharedPrefix.ghost(candidates: tokenFirst, line: "git ") == "commit ")
}

@Test("分数差距大、首项不是历史、或公共前缀停在半个词时不预览")
func sharedPrefixStaysConservative() {
  let farApart = [history("git commit -m", score: 300), history("git commit --amend", score: 200)]
  #expect(AutocompleteSharedPrefix.ghost(candidates: farApart, line: "git ") == nil)
  let specFirst = [
    AutocompleteCandidate(insertText: "checkout", kind: .subcommand, score: 300, replacement: .currentToken(start: 4)),
    history("git checkout main", score: 299),
  ]
  #expect(AutocompleteSharedPrefix.ghost(candidates: specFirst, line: "git ") == nil)
  // 首项 token 与历史的共同词不一致（push vs commit）：不预览。
  let disagreeing = [
    AutocompleteCandidate(insertText: "push", kind: .argument, score: 400, replacement: .currentToken(start: 4)),
    history("git commit -m", score: 300), history("git commit --amend", score: 300),
  ]
  #expect(AutocompleteSharedPrefix.ghost(candidates: disagreeing, line: "git ") == nil)
  let halfWord = [history("npm install", score: 300), history("npm init", score: 300)]
  #expect(AutocompleteSharedPrefix.ghost(candidates: halfWord, line: "npm ") == nil)
  #expect(AutocompleteSharedPrefix.ghost(candidates: [history("ls -la", score: 300)], line: "ls") == nil)
  #expect(AutocompleteSharedPrefix.ghost(candidates: [], line: "") == nil)
}

@Test("公共续写修剪到完整词，整条正好结束的候选也算词完整")
func sharedContinuationTrimsToWholeWords() {
  #expect(AutocompleteSharedPrefix.sharedContinuation(of: ["commit -m x", "commit --amend"]) == "commit ")
  #expect(AutocompleteSharedPrefix.sharedContinuation(of: ["commit", "commit --amend"]) == "commit ")
  #expect(AutocompleteSharedPrefix.sharedContinuation(of: ["run build", "run dev"]) == "run ")
  #expect(AutocompleteSharedPrefix.sharedContinuation(of: ["install", "init"]) == nil)
  #expect(AutocompleteSharedPrefix.sharedContinuation(of: ["a b", "c d"]) == nil)
  #expect(AutocompleteSharedPrefix.sharedContinuation(of: ["", "x"]) == nil)
}
