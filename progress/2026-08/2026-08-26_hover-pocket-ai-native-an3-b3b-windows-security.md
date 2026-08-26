# HoverPocket AI-native AN3-B3B Windows Voice E2E security follow-up

## 対象

- branch: `codex/ai-native-an3b3b-windows-e2e`
- Draft PR: [#37](https://github.com/shotaro311/hover-pocket/pull/37)
- scan base: `16090d7a86c81ab19d85018462814c7279bb8801`
- scanned head: `276e5eb57b06e45c0cc8f8a5ffe064b46040eeca`
- fixed code head: `ba1273fb832463307d4a41de3e0b769607d4677c`

## Codex Security scan

- scan ID `32812599-f0a7-4397-af98-fcce4a65990f`
- changed-source coverage: 13 / 13
- severity: Low 4件
- TAC照合はconnector未ログインのため未検証であり、scan自体の静的根拠とは分けて扱う。

検出内容は次の4件だった。

1. renderer由来media receiptをE2E成功証跡として信頼できる。
2. media telemetry待機がmicrophone cleanupを止め得る。
3. 隔離E2EのAPI keyがCredential Managerへ残り、crash後も存続する。
4. E2E WebViewが外部browserを起動できる。

## 修正

- Hostが試行ごとに32桁media leaseを発行し、renderer eventsは同一lease・正しい順序だけを診断情報として受理する。Host-ownedのtransport detach / safe closeはrenderer parserから除去した。
- leaseは現在のrendererにも見えるため、それだけでfinding 1を閉じたとは扱わない。Debug E2EだけにWPFのネイティブ確認ダイアログを追加し、人が実際にマイクへ話しremote assistant audioを聞いた場合だけHostが`physicalMediaUserConfirmed=true`を記録する。
- receipt schemaをv2へ更新した。`voice_e2e_windows.ps1 -Action Validate`はprovider、feature、root session、transport / realtime、microphone、remote track / playback、Timer Broker readback、Host-owned physical confirmationをすべて必須にする。旧schemaやrenderer診断だけでは成功しない。
- media receipt telemetryをfire-and-forgetへ変更し、失敗経路は通知前にstreamを停止する。JavaScript harnessは`voice.mediaEvent`を解決しないPromiseにしてもcleanupが完了することを検証する。
- `OpenAIRealtimeCredentialStoreFactory`を追加し、isolated E2Eはzeroing process-memory store、ProductionはWindows Credential Managerを選択する。E2E Settingsの説明と削除確認もprocess-memory表記へ分けた。
- `ExternalIntegrationsEnabled`をPanel / Settings WebViewの共通navigation policyへ渡し、E2Eでは`Process.Start`へ到達しない。Production既定の外部link動作は維持する。

## verify-fix

| finding | 結果 | 根拠 |
|---|---|---|
| renderer receipt forgery | fixed | renderer fieldsは診断情報だけ。最終Validateはrendererが直接設定できないWPF user confirmationを要求する。 |
| telemetry blocks cleanup | fixed | cleanupはtelemetryをawaitせず、never-settling telemetry harnessを追加した。 |
| durable E2E credential | fixed | E2E compositionはprocess-memory store、ProductionだけCredential Managerを使う。 |
| external browser escape | fixed | E2E policy falseがPanel / Settings両sinkでbrowser launchを拒否する。 |

## 検証

- `node --check windows/ui/js/app.js`: PASS
- `node --check windows/ui/js/i18n.js`: PASS
- `node --check windows/ui/settings/settings.js`: PASS
- `git diff --check`: PASS
- Windows CI [32914420289](https://github.com/shotaro311/hover-pocket/actions/runs/32914420289): PASS
  - Release build
  - Debug Voice E2E host build
  - Settings / Capabilities / Broker / Pocket Surface / Timer / UI model
  - Voice foundation / Voice E2E isolation
  - PowerShell syntax
  - Updater / signing contract
  - rendered WebView UI
- Router [32914419440](https://github.com/shotaro311/hover-pocket/actions/runs/32914419440): PASS
- CI readback時点のPR: `Draft / OPEN / MERGEABLE / CLEAN`、review / comment 0件。

## 未完了gate

- Windows実機で`voice_e2e_windows.ps1 -Action Run`を実行する。
- Settingsへテスト用OpenAI Realtime API keyを入力する。秘密値はGit、progress、CI artifactへ残さない。
- 明示mic click後、自然言語でTimerを実行し、remote assistant audioを実際に聞く。
- Voice LaneのDebug確認ボタンからWPFダイアログを表示し、実音声を確認できた場合だけYesにする。
- `-Action Validate`で`voice_e2e_physical_validation=verified`をreadbackする。
- `-Action Stop`後、process、media、transport、realtime、credentialが残っていないことをreadbackする。
- macOS AN3-B3Bは既存ChatGPT Pro runの正本deliveryを待つ。sent状態を推測して再送しない。
