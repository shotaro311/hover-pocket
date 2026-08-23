# HoverPocket AI-native AN5 credential broker mutual process identity

## 目的

AN5 credential brokerのproduction有効化前gateとして残っていた、接続先server identityの確認と、Hostが起動した特定helper PIDだけを許可するbindingを両OSへ追加する。secret、endpoint、capabilityを環境変数やprocess argumentへ置かず、Hostがhelper起動後にPIDを固定してから、専用stdin pipeへ一回限りのbootstrapを渡す。

## Git構成

- branch: `codex/ai-native-an5-credential-broker-mutual-identity`
- base branch: `codex/ai-native-an5-credential-broker-identity`
- base commit: `81cf0eee2a3ba85fd4b746b10b6d0e7584b35aa7`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5-credential-broker-mutual-identity`

## 共通起動順序

1. Hostはredirect済みstdin / stdout / stderrを持つHoverPocket helper processを先に起動する。helperはstdin bootstrapを待ち、brokerへまだ接続しない。
2. Hostは取得したhelper PIDをimmutableな期待値としてbroker serverを作る。serverはそのPIDと実行体identityが一致するclientだけを許可する。
3. Hostはversion、endpoint、one-time capability、Host server PIDだけを含むbounded JSONをhelper stdinへ書き、pipeを閉じる。
4. helperは接続済みbroker serverのPIDとHoverPocket実行体identityを確認してからcapabilityを送る。
5. serverはclient PIDとidentityを再確認し、one-time leaseをredeemする。失敗時はcredentialを返さずleaseを消費する。

このbranchでは実credential storeとproduction Codex generatorをまだ接続せず、`supportsConfidentialGeneration`のfail-closedを維持する。

## macOS実装

- Unix socketの両端で`getpeereid`、`LOCAL_PEERPID`、Security.frameworkのdesignated requirementを確認する。
- serverは起動済みhelperのexact PIDを要求する。同じ署名・同じ実行体でも別PIDのprocessは拒否する。
- helper clientはbootstrapで受け取ったHost PIDを接続済みsocketへ照合し、別serverへの差し替えを拒否する。
- endpoint / capabilityの環境変数を削除し、2,048 byte上限のversion付きJSONをstdinから一度だけ読む。
- peerが先にsocketまたはpipeを閉じた場合もprocess全体を終了させないよう、broker socketの`SO_NOSIGPIPE`に加えHost startupで`SIGPIPE`をignoreし、通常の`EPIPE`としてfail closedにする。
- verifierは実helper child成功、同じHoverPocket binaryだが異なるPIDのchild拒否、誤ったserver PID拒否、Python foreign peer拒否を確認する。

## Windows実装

- serverは`GetNamedPipeClientProcessId`でclientのexact PIDを取得し、期待helper PIDと正規化済みHoverPocket executable pathの両方を照合する。
- helper clientは`GetNamedPipeServerProcessId`でserverのexact PIDを取得し、bootstrapのHost PIDと同じexecutable pathを照合してからcapabilityを送る。
- endpoint / capabilityの環境変数を削除し、2,048 character上限のversion付きJSONをstdinから一度だけ読む。
- verifierを同一processのhelper直呼びから実HoverPocket child processへ置換した。同じbinaryの誤PID、誤server PID、PowerShell foreign peer、注入authorizer拒否を独立caseで確認する。
- Windows正式配布binaryではpath一致に加えtimestamped Authenticode signer bindingを別のrelease gateで確認する。

## ローカル検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| `.build/debug/HoverPocket --verify-pocket-app` 3回 | 3回ともpackage / lifecycle / generation / migration / health / workspace backup成功。実helper、wrong PID、wrong server PID、foreign peerを含む |
| `python3 script/verify_voice_foundation.py` | 42件成功 |
| `.build/debug/HoverPocket --verify-voice-foundation` | default-off、root scope、bounded transcript、compact / expanded geometry成功 |
| `.build/debug/HoverPocket --verify-panel-layout` | 128件成功 |
| `.build/debug/HoverPocket --verify-capabilities` | 20 handler成功 |
| `.build/debug/HoverPocket --verify-broker` | 21 descriptor / 20 handler、Today Focus、retention成功 |
| `.build/debug/HoverPocket --verify-pocket-surface` | 6 node、negative 15件成功 |
| `.build/debug/HoverPocket --verify-timer` | lifecycle、storage isolation、concurrency成功 |
| `python3 script/verify_pocket_contracts.py` | 15 schema / 71 fixture全一致 |
| Windows `app.js` / `settings.js`の`node --check` | 成功 |
| `git diff --check` | 成功 |

このMacには.NET SDKがないため、Windows Release buildと実Named Pipe child process verifierはstacked Draft PR CIを必須gateとする。

## セキュリティ差分レビュー

- exact range `81cf0eee2a3ba85fd4b746b10b6d0e7584b35aa7..12434877e821773f902a27d43799ceb60c787867`をCodex Security diff scan `1bdca291-89df-4e9c-87d4-b5be9de5dc2e`で完了・封印・再読込した。
- reportable findingは0件である。snapshot digestは`codex-security-snapshot/v1:sha256:c02e6a4b3d1f5c9d507872944faf096a0d982bd299ff26324022e9d0fccca152`。
- macOS mutual peer identity、stdin bootstrap、failure / denial処理は`no_issue_found`。Windows source traceとverifier定義も確認した。
- coverageはpartial。ローカルに.NET SDKがないためWindows exact-head dynamic validationをDraft PR CIへ、正式配布binaryのtimestamped Authenticode signer bindingをproduction有効化前gateへ残した。
- production credential store / confined generator E2Eはこの差分に含まれず、production confidential generationは引き続きOFFである。
- scan使用量はtotal 2,292,338 tokens、input 2,286,313、cached input 2,252,288、output 6,025でreadbackした。

## 未完了gate

- stacked Draft PRでWindows Release warning 0 / error 0、`helper`、`same-binary-wrong-pid`、`wrong-server-pid`、`foreign-peer`の全case終端をreadbackする。
- Windows正式署名済みbinaryではexpected PIDに加えてAuthenticode signerを固定する。
- AN3-B3A credential store統合後に、実store → broker → confined generatorの値非露出E2Eを別gateで行う。

## Pro run状態

- 正本run: `20260824-051101-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`
- status: `inProgress`。completion signalは未着で、再送・未claim artifact先読みをしていない。
- 不一致だった旧`050727` deliveryは隔離し、receipt読取、適用、`mark-done`を行わない。
