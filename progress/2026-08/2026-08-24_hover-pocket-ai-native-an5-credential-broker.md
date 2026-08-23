# HoverPocket AI-native AN5 Host-owned credential broker foundation

## 目的

Pocket App生成用Codex processへAPI keyを広い環境変数、引数、auth file、生成workspace経由で渡さず、Hostが所有する一度限りのローカルIPCで必要時だけ渡す土台をmacOS / Windowsへ追加する。

この変更では実Keychain / Credential Managerとproduction generatorを接続しない。AN3-B3AのBYOK store差分が確定するまで、両OSのreal Codex generationはfail-closedを維持する。

## Git構成

- branch: `codex/ai-native-an5-credential-broker-foundation`
- base branch: `codex/ai-native-an5-codex-confinement`
- base commit: `e6747898d0f1db357899c82c1fe5f8da28af6924`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an5-credential-broker`

## 実装した契約

### 共通

- 32 byteのOS CSPRNGからbase64url capabilityを生成する。
- leaseは1回だけredeemでき、最大60秒、既定30秒で失効する。
- wrong capability、malformed request、期限切れでもleaseを消費し、fail closedにする。
- secretは空文字を拒否し、UTF-8で8,192 byte以下、制御文字なしに限定する。
- requestは`HP-CODEX-BROKER/1 <capability>\n`、responseは`OK <base64>\n`または`ERR\n`に固定する。
- request 512 byte、response 12,000 byte、I/O 2秒で上限を設ける。
- helper引数と環境keyは両OSで共通にする。
  - `--codex-credential-helper`
  - `HOVERPOCKET_CODEX_BROKER_ENDPOINT`
  - `HOVERPOCKET_CODEX_BROKER_CAPABILITY`
- helperはsecretを成功時の標準出力だけへ返し、失敗時は有限な一般エラーだけを標準エラーへ返す。

### macOS

- randomな`/private/tmp/hoverpocket-codex-broker-*` directoryを`0700`、Unix socketを`0600`で作る。
- root directoryの種類、owner、group / other permissionを起動前に確認する。
- `DispatchSourceRead`とtimerを同一serial queueで管理する。
- cleanup handlerがdeinitializing serverを参照しない独立stateを所有し、FD close、socket unlink、directory removal、waiter通知を一度だけ行う。
- `main.swift`は通常アプリ初期化より前にhelper / deinit probeを処理する。

### Windows

- randomなNamed Pipeを`PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly`、1 instanceで作る。
- lifetimeとrequest timeoutを別CancellationTokenで管理する。
- client接続はCancellationTokenだけへ依存せず、`.NET 10`の明示`TimeSpan` timeout付き`ConnectAsync`で有限化する。
- WindowsのPocket Surface / Package / Generation縦断stepはCIでも2分上限にし、brokerのlease / pipe / wrong capability / helper各段階をverification logへ残す。
- `Program.Main`はVelopack / WPF初期化より前にhelperを処理する。
- helper、client、lease、serverを通常のPocket App generation verifierから検証する。

## セキュリティ監査

- scan ID: `cc22a511-9d5a-4052-a3ea-7097aa17dd3f`
- snapshot digest: `codex-security-snapshot/v1:sha256:3700546fc5c595ef37da3d30b0fc6c336123f6cefab005e2dd6a9ee1b05599de`
- target ID: `target_sha256_e5761d63f33a95daefd15ac5d8b4c5c2009ba9cfea2f22510923d06d8aaa1846`
- reportable finding: 0件
- coverage: partial
- manifest SHA-256: `090a54f6df21106c35ba76fd9cc96ae30a37010da2e954084503682c200f0e42`
- findings SHA-256: `88578e1d152c9574144720c14eddda3cc23f7400b2c136b9dce9b477a265b20c`
- coverage SHA-256: `51c91d007c678bafa30c136425568e0b2a3bc713418c02af09c41858d3789423`
- report SHA-256: `0ead7e94ffdfd15c0503762ebef56328878ec7aede36db58f8ef4330cd56e8b2`

監査は6変更fileを全件reviewし、6 candidateをvalidateした。現時点のproduction callerが存在しないため、次の5項目は本番接続前gateへdeferした。

1. Windows helperを意図したprocess / signatureへbindする。
2. macOS helperをpeer PID / audit token / code identityへbindする。
3. macOS clientがserver identityをpinし、pathname置換を拒否する。
4. Windowsでsame-user first-clientがleaseを消費できないことを実機canaryで確認する。
5. macOSでsame-user first-clientがleaseを消費できないことを実機canaryで確認する。

deinit-only cleanupは攻撃経路がないためsecurity findingからsuppressedされたが、exact source probeで3秒hangを再現した。独立cleanup stateへ修正後、専用child process probeはexit 0、標準出力 / 標準エラー0 byte、新規socket残留0件になった。再現時に残った既知の一時socket 1件も、process不在とpathを確認してから対象限定でunlink / rmdirし、残留0件をreadbackした。

## ローカル検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| `HoverPocket --verify-codex-credential-broker-deinit` | exit 0、開始前後の新規directory差分0 |
| `HoverPocket --verify-pocket-app` | package / lifecycle / generation / migration / health / workspace backup成功 |
| `HoverPocket --verify-pocket-surface` | 6 node、negative 15件成功 |
| `HoverPocket --verify-capabilities` | 20 handler成功 |
| `HoverPocket --verify-broker` | 21 descriptor / 20 handler、Today Focus、retention成功 |
| `HoverPocket --verify-voice-foundation` | default-off、root scope、bounded transcript、compact / expanded geometry成功 |
| `python3 script/verify_pocket_contracts.py` | 15 schema / 71 fixture全一致 |
| `python3 script/verify_voice_foundation.py` | 42件成功 |
| `git diff --check` | 成功 |

このMacには.NET SDKがないため、Windows C#のRelease build、warning 0 / error 0、credential broker verifierはDraft PR CIを必須gateとする。

## Pro回収状態

- 通知された旧AN3-B3A deliveryは`claim-synthesis`でstate hash不一致となった。
- receipt、artifact、回答本文を読まず、適用、`mark-done`、同run再利用をしていない。
- 正本run `20260824-051101-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`はrequired-return bridgeで`running`を維持している。
- bridgeの最新readbackは`signal 未着、claim-delivery未実行`であり、再送やorigin pollをしていない。

## 次のgate

1. このbranchをstacked Draft PRにし、Windows / macOS CIとnative verifierをreadbackする。
2. AN3-B3A正本deliveryをclaimし、credential storeとの境界をexact diffで確認する。
3. brokerを実credential storeとCodex command-backed bearer authへ接続する。
4. signed helper / process identity、same-user race、outside-root、network、cancel / timeout / crash cleanupを両OS実機canaryで確認する。
5. VoiceからPocket App生成、schema validation、preview、default-No approval、install、runtime / Surface readback、rollbackを両OSで通した後だけproduction flagを開く。
