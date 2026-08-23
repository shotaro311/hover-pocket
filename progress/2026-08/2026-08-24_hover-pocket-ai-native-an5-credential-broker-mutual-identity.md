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
- Windows stdin安定化まで含むfinal exact range `81cf0eee2a3ba85fd4b746b10b6d0e7584b35aa7..1d55dab31b8f7bf3255f5cd994b25ee88a05833e`を、Codex Security diff scan `210c26b0-0934-4e9d-875e-60e7fd663a63`で再走査し、完了・封印・再読込した。
- final scanは変更source 5 / 5件を確認し、reportable findingは0件である。snapshot digestは`codex-security-snapshot/v1:sha256:ca026630152d323ee57fbdf94f326bbb28cb195b7106cad365a8aa73d3211126`。
- macOS exact PID / uid / designated requirement、Windows exact PID / executable path、stdin bootstrap、one-shot lease、server差し替え拒否、bounded parser、generic errorの各surfaceは`no_issue_found`である。
- coverageはpartial。Windows exact-head dynamic validationはCIで完了したためdeferredから外し、正式配布binaryのtimestamped Authenticode publisher bindingと、production store → broker → confined generator E2Eだけをproduction有効化前gateとして残した。
- final scan使用量はtotal 6,322,371 tokens、input 6,310,908、cached input 6,165,504、output 11,463でreadbackした。

## 未完了gate

- Windows正式署名済みbinaryではexpected PIDに加えてAuthenticode signerを固定する。
- AN3-B3A credential store統合後に、実store → broker → confined generatorの値非露出E2Eを別gateで行う。

## Draft PR / Windows初回readback

- stacked Draft PR [#35](https://github.com/shotaro311/hover-pocket/pull/35)をbase `codex/ai-native-an5-credential-broker-identity`で作成した。
- 初回Windows run [32672078767](https://github.com/shotaro311/hover-pocket/actions/runs/32672078767)はRelease build、Settings、Capability、Brokerまで成功した。Pocket Surface内のcredential brokerは`helper`開始後に10秒でtimeoutし、同caseのENDへ到達しなかった。
- .NET公式契約を再確認し、child側は`Console.OpenStandardInput()`から標準入力streamを明示取得するよう変更した。Host側はOS依存の`WriteLine`を使わず、UTF-8 JSONとLFを明示的に書く。
- `Environment.ProcessPath`がapphostではなく`dotnet` hostを指す実行形態にも対応し、その場合だけentry assembly pathを先頭argumentへ追加する。launch modeはsecretを含まない固定markerだけをverification logへ残す。
- 修正後head `1d55dab31b8f7bf3255f5cd994b25ee88a05833e`で、Windows [32672304607](https://github.com/shotaro311/hover-pocket/actions/runs/32672304607)、macOS [32672304592](https://github.com/shotaro311/hover-pocket/actions/runs/32672304592)、PR Router [32672304100](https://github.com/shotaro311/hover-pocket/actions/runs/32672304100)がすべて成功した。
- Windows Release buildはwarning 0 / error 0で、`lease`、`named-pipe`、`wrong-capability`、`foreign-peer`、`unauthorized-peer`、`helper`、`same-binary-wrong-pid`、`wrong-server-pid`の全caseがBEGIN / ENDへ到達した。apphost launch markerだけが出力され、endpoint、capability、secretはlogへ出ていない。

## Pro run状態

- 正本run: `20260824-051101-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`
- status: `inProgress`。completion signalは未着で、再送・未claim artifact先読みをしていない。
- 不一致だった旧`050727` deliveryは隔離し、receipt読取、適用、`mark-done`を行わない。
