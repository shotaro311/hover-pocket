# HoverPocket AI-native AN5 credential broker peer identity

## 目的

Host-owned credential brokerへ同じユーザーの別processが先着しても、正しいcapabilityだけでsecretを取得できないようにする。AN3-B3Aが追加するKeychain / Credential Manager storeとは分離し、brokerの接続元identityだけを先行して固定する。

## Git構成

- branch: `codex/ai-native-an5-credential-broker-identity`
- base branch: `codex/ai-native-an5-credential-broker-foundation`
- base commit: `7447e3294dadc6f454d78888571ef1b03cc01792`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5-credential-broker-identity`

## 実装

### macOS

- `getpeereid`でUnix socket peerのeffective UIDがHostと同じことを確認する。
- `getsockopt(SOL_LOCAL, LOCAL_PEERPID)`で接続元PIDを取得する。
- `SecCodeCopyGuestWithAttributes`へPIDを渡し、実行中peer codeを取得する。
- Host自身のdesignated requirementを`SecCodeCopyDesignatedRequirement`で取得し、`SecCodeCheckValidity`でpeerが同じrequirementを満たす場合だけrequestを読む。
- identity検証失敗時はcapabilityを読まず`ERR`を返し、leaseを消費してserverを終了する。
- `/usr/bin/python3`の別processへ正しいfixture endpoint / capabilityを渡し、先着接続してもsecretを取得できない実process canaryを追加した。
- 既存の同じHoverPocket executableを使うhelper subprocessは引き続き成功し、許可側も実経路で確認する。

Appleの一次資料では、`kSecGuestAttributePid`はprocess IDでguest codeを指定する属性であり、`SecCodeCopyGuestWithAttributes`はkernel code signing hostから該当guest codeを取得するAPIである。

- https://developer.apple.com/documentation/security/guest-attribute-dictionary-keys
- https://developer.apple.com/documentation/security/seccodecopyguestwithattributes%28_%3A_%3A_%3A_%3A%29

### Windows

- `GetNamedPipeClientProcessId`でNamed Pipe client PIDを取得する。
- client processの`MainModule.FileName`と`Environment.ProcessPath`をfull pathへ正規化し、同じHoverPocket executableの場合だけrequestを読む。
- identity検証失敗時はcapabilityを読まず`ERR`を返し、leaseを消費する。
- Windows PowerShellの別processへ正しいfixture endpoint / capabilityを渡すforeign-peer canaryと、注入authorizerを必ず拒否させる決定論的negative caseを追加した。
- Microsoftの一次資料では、`GetNamedPipeClientProcessId`はserver側pipe handleからclient process IDを取得するAPIである。

  - https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeclientprocessid

Windowsの正式releaseでは、path一致に加えてtimestamped Authenticode signerを固定する必要がある。このbranchは未署名CIと開発buildでも回帰検証できるprocess identity gateまでをscopeとし、signer bindingは未完了gateに残す。

## ローカル検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| `.build/debug/HoverPocket --verify-pocket-app` | package / lifecycle / generation / migration / health / workspace backup成功。same-binary helper成功、foreign-peerとinjected unauthorized peer拒否 |
| `.build/debug/HoverPocket --verify-pocket-surface` | 6 node、negative 15件成功 |
| `.build/debug/HoverPocket --verify-capabilities` | 20 handler成功 |
| `.build/debug/HoverPocket --verify-broker` | 21 descriptor / 20 handler、Today Focus、retention成功 |
| `.build/debug/HoverPocket --verify-voice-foundation` | default-off、root scope、bounded transcript、compact / expanded geometry成功 |
| `python3 script/verify_pocket_contracts.py` | 15 schema / 71 fixture全一致 |
| `python3 script/verify_voice_foundation.py` | 42件成功 |
| `git diff --check` | 成功 |

このMacには.NET SDKがないため、Windows C#のRelease build、warning 0 / error 0、Named Pipe foreign-peer / unauthorized-peer verifierはstacked Draft PR CIを必須gateとする。

初回PR #34 Windows CI `32670323133`はRelease build、Settings UI、Capability、Brokerまで成功したが、cold PowerShell起動を含むforeign-peer canaryが5秒上限に達し、`generation_credential_broker_contract:TimeoutException`でPocket Surface stepを停止した。server lifetimeを20秒、foreign process waitを15秒へ分離し、server自身の5秒expiryで誤って拒否成功と判定しないまま、CI cold startを許容するbounded timeoutへ修正した。

同じ修正後のmacOS回帰では、foreign peerが拒否応答より先にsocketを閉じた場合に`write`が`SIGPIPE`を発生させ、verifier processがexit 141になる非決定的失敗を1回再現した。server/client socketへ`SO_NOSIGPIPE`を設定し、相手が先に閉じてもprocess signal終了せず、通常のwrite失敗としてfail closedになるよう修正した。

## セキュリティ差分レビュー

- Codex Security diff scan `efe77173-169f-402b-a202-85475b321270`をworking tree base `7447e3294dadc6f454d78888571ef1b03cc01792`、snapshot digest `codex-security-snapshot/v1:sha256:4713f4e97da5de8e7131367be3663ef5544eb1c7e7118cc9c2c56416111b68d9`で完了・封印・再読込した。
- reportable findingは0件である。追加したmacOS designated requirementとWindows executable path gateは、Python / PowerShellなど別実行体へ正しいfixture capabilityを渡してもsecretを返さない。
- coverageはpartialで、production flagを有効化する前の必須gateを2件残した。
  1. macOS helperが接続済みUnix socketのserver PID / code identityを確認する相互認証。
  2. 両OS serverがHost自身の起動したexpected helper PIDへbindingし、そのPID設定前にacceptしない起動順序。
- unauthorized first connectionがleaseを消費する挙動は動的に確認した。credential漏えいはなく、同一ユーザー自身の単一ローカル生成失敗に限定されるため、security findingからは除外した。
- Windows timestamped Authenticode signer bindingは、この開発・CI向けprocess identity branchではなく正式release gateで確認する。

## Pro run状態

- 正本run: `20260824-051101-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`
- bridge thread: `01a0303f-cd84-7323-84c0-95e9fa266d67`
- latest cursor: `d3c754ad-6d85-4d91-b199-026c75a88cee:14`
- status: `inProgress`。ready / blocked signalは未着。
- 新規送信、同一prompt再送、origin heartbeat、未claim artifactの先読みは行っていない。

## 次のgate

1. コード差分をcommit / pushし、PR #33上のstacked Draft PRを作る。
2. Windows Release build、warning 0 / error 0、`foreign-peer` / `unauthorized-peer`のbegin / end、後続全verifierをCI logからreadbackする。
3. macOS CIでwarnings-as-errors、Pocket App generation、Voice / Capability / Broker回帰をreadbackする。
4. 正本AN3-B3A delivery到着後、state hashをclaimしてcredential store境界だけを統合する。
5. helper側server identity pinningとexpected helper PID bindingを別stack branchで実装し、same-user race canaryを再実行する。
6. Windows formal signer bindingと両OSの実配布binary canaryはproduction flag前の別gateとする。
