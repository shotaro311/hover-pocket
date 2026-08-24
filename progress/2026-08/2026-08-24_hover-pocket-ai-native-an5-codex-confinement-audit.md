# HoverPocket AI-native AN5 Codex confinement audit

## 結論

- Codex CLI 0.145.0のnamed permission profileを使えば、macOSのmodel-requested toolをPocket App生成workspaceだけへread-onlyで閉じ込められる。
- `codex sandbox`と実`codex exec`の両方で、生成workspaceは読める一方、兄弟worktree、`~/.codex/auth.json`、Obsidian Vaultは読めないことを確認した。ファイル内容はcanaryへ出力していない。
- 現行adapterの`supportsConfidentialGeneration = false`とWindowsの`ResolveExecutable() = null`は維持する。ファイル隔離だけでは、認証情報を安全にCodexへ渡すHost-owned brokerとWindows実機canaryが不足する。
- API keyを環境変数、引数、生成workspace、Codex用auth fileへ置く方式は採用しない。

## 通知された旧Pro delivery

- run: `20260824-050727-hoverpocket-an3-b3aexact-base-b95ef168openai-realtime-byok-providerwindowswebview-webrtc-voice-lanehostrealtime-apiregistryhoverpocket-capabilityfunction-toolbrokermacosproviderkeychainadapter-seamfail-closedtransportan3-b3b`
- delivery ID / expected state hash付きで`claim-synthesis`を実行したが、`run state hash does not match the completion signal`で失敗した。
- receipt、成果物、Pro回答本文は読み込まず、適用、`mark-done`、同run再利用を行っていない。
- 正本AN3-B3A run `20260824-051101-hoverpocket-an3-b3a-realtime-byok-windows-vertical-slice-patch`のrequired-return bridgeは、同一runのready / blocked通知待ちを継続している。

## 実コード根拠

- Codex 0.145.0の`PermissionProfileToml`は、workspace roots、filesystem、networkを一つのnamed profileへ束ねる。
- filesystemは`:minimal`と生成workspaceだけを`read`にし、より具体的なpathを`deny`にできる。同じ具体度では`deny > write > read`で解決される。
- `shell_environment_policy`は`inherit = "none"`と固定`set`を持ち、model-requested toolへ親processの環境変数を継承させない。
- providerのcommand-backed bearer authは、固定commandをCodex process側から実行し、stdoutのtokenをprocess内でcacheする。model toolのsandboxとは別経路なので、Host-owned brokerとの接続点にできる。
- 現行macOS / Windows adapterは`--sandbox read-only`、ユーザーHOME、file-backed Codex authに依存するため、production generatorを意図的に切断している。この判断は正しい。

## macOS canary

### 直接sandbox

named permission profileへ次を設定した。

- `:minimal = read`
- current generation workspace = read
- network = disabled
- shell environment = inherit none、`PATH=/usr/bin:/bin`、`LANG=C`のみ

readback:

```text
workspace=readable vault=blocked auth=absent
```

Host側では`~/.codex/auth.json`とVault sentinelの実在を別経路で確認している。sandbox内の`auth=absent`は、存在確認自体が拒否された結果である。

### 実Codex tool

GPT-5.6 Solのephemeral `codex exec`を、user config / rules無効、approval never、同じnamed permission profileで一度だけ実行した。modelには`test -r`とstatus出力だけを許可し、内容読取りを指示していない。

```text
workspace=readable sibling=unreadable auth=unreadable vault=unreadable
```

process exit codeは0だった。models cacheの旧形式warningは出たが、canary結果と終了状態は成功している。production adapterはこのwarningを有効化根拠にせず、version pinと終了code、bounded output、schema decodeを引き続き必須にする。

## 採用するcredential broker

1. HoverPocketはAPI keyをKeychain / Windows Credential Managerだけに保存する。
2. 生成開始ごとにHostがrandom one-time capabilityとprivate Unix socket / named pipeを作る。API keyをprocess環境へ置かない。
3. isolated `CODEX_HOME`とisolated `HOME`を使い、auth file、user config、skills、hooks、rulesを生成processへ持ち込まない。
4. Codex providerはcommand-backed bearer authを使い、署名・digest・ownerを検証したcredential helperだけを固定commandとして起動する。
5. helperはmodel toolへ継承されないone-time capabilityでHost brokerへ接続し、受け取ったkeyをstdoutでCodex processだけへ渡す。
6. permission profileは生成workspaceだけをread、networkをdisabled、helper、broker endpoint、isolated home、ユーザーhomeをdenyにする。model toolからhelperを直接起動してもcapabilityがなく、brokerは拒否する。
7. Hostは生成終了、timeout、cancel、異常終了時にcapabilityを失効し、socket / pipeとisolated directoryを後始末する。

## 次の実装順序

1. 正本AN3-B3A返却をclaimし、BYOK credential storeのexact diffを先に確定する。
2. AN5 Codex confinementを別の小さいstacked branchへ分離し、macOS broker、isolated home、named permission profile、outside-root / helper / network canaryを実装する。
3. Windowsへ同じcontractを移植し、restricted token / AppContainer相当、Credential Manager、named pipe capability、outside-root / helper / network canaryを実機とCIで確認する。
4. 両OSでHost schema validation、declared tests、preview、default-No approval、immutable install、runtime / Surface readbackまで通す。
5. 最後にVoiceからPocket App生成を依頼し、credential非露出、承認、導入、rollbackを実機E2Eで確認してからproduction flagを開く。

## 未完了gate

- AN3-B3A正本artifactの回収・適用・ローカル検証。
- Host-owned credential brokerの実装とtoken非露出canary。
- Windows実機のfilesystem / process / network / Credential Manager canary。
- macOS実アプリ署名後のKeychain broker、cancel / timeout / crash cleanup。
- Voice生成、承認、install、runtime / Surface readback、rollbackの両OS E2E。

