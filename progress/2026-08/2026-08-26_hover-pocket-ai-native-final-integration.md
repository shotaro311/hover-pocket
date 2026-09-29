# HoverPocket AI-native Core GA final integration

## 目的

AN3-B3BのWindows Voice E2E、macOS Realtime Voice、AN5 Codex credential confinementを、既存のAI-native Core / AN8基盤へ壊さず統合する。統合候補の作成と自動検証までを行い、実機音声、正式署名、配布、mergeは独立gateとして残す。

## Pro criticの回収

- run: `20260826-132725-hoverpocketan8realtime16090d7windows-voice-7472c73macos-voice-5883925an5-mutual-credential-e4cd8f0criticgate`
- exact base: PR #36 `16090d7a86c81ab19d85018462814c7279bb8801`
- exact heads: PR #37 `7472c73bd12abf4d7e3c9946590000603f223132`、PR #38 `5883925ade7472b1490e424a4eb5002e384b479d`、PR #35 `e4cd8f09d56bab9901e0e1fb4f8d938a6ca5baee`
- artifact: `integration-review.md`
- artifact SHA-256: `8e8bc5c4ddf402ef3f86f1ef29408e8d339bc85bd49f99da0ca8e7cdb1ad5b80`
- Pro送信後、回答生成とinline artifactは完了したが、download fallback後にNodeの`setTypeOfService EINVAL`でOracle hostが終了した。`sent-state-unknown`をbounded recoveryへ記録し、新規promptを送らず同じsessionをharvestした。
- Codexが応答SHA、artifact SHA、standalone性、`## END`、GitHub上のexact head不変を別経路で確認した。受入条件4 / 4をPASSにし、deliveryをterminal化した。

## 統合履歴

| 段階 | 内容 | commit |
|---|---|---|
| R0 | PR #36 exact base | `16090d7a86c81ab19d85018462814c7279bb8801` |
| R1 | Windows Voice E2E / security | `8f3a34884b2dfc0bb1919f690f34c69bfaa24f98` |
| R2 | macOS Realtime Voice | `9201154d58911f204f76b390f8401f3efc7df0b1` |
| R3 | AN5 credential confinement / mutual identity | `b66392fb5237a62ea3959035b31fee9d5376078d` |

統合順は`#37 → #38 → #35`。#32〜#34は#35の祖先なので個別には再mergeしていない。

## 競合解消

- `progress/progress.md`: Windows Voice、macOS Voice、AN5 credential stackの記録と未完了gateをすべて残した。
- `windows/src/HoverPocket.Shell/Program.cs`: `--codex-credential-helper`を最初に判定してterminal dispatchし、その後だけ`StartupOptions.Parse`、Voice E2E root、本番Velopack / WPFへ進む。
- `.github/workflows/windows-verify.yml`: 自動merge後に、Release / Debug build、Pocket Surface 2分timeout、Voice E2E isolation、`voice_e2e_windows.ps1`構文、signing contractを保持していることをreadbackした。

## final headのローカル検証

- `git merge-base`でPro artifactの祖先関係を再確認: PASS
- `git diff --check`: PASS
- `swift build -Xswiftc -warnings-as-errors`: PASS
- `python3 script/verify_voice_foundation.py`: PASS、42 cases
- `.build/debug/HoverPocket --verify-voice-foundation`: PASS
- `.build/debug/HoverPocket --verify-panel-layout`: PASS、128 cases
- `.build/debug/HoverPocket --verify-capabilities`: PASS、20 handlers
- `.build/debug/HoverPocket --verify-broker`: PASS、21 descriptors / 20 handlers
- `.build/debug/HoverPocket --verify-pocket-surface`: PASS
- `.build/debug/HoverPocket --verify-pocket-app`: PASS。package、lifecycle、generation、capability migration、health、workspace backupを含む
- `.build/debug/HoverPocket --verify-timer`: PASS
- `python3 script/verify_pocket_contracts.py`を2回実行: PASS、15 schemas / 71 fixtures、report byte一致
- Windows panel / i18n / settings JavaScript構文: PASS
- `node windows/script/verify_settings_generation_target.mjs`: PASS

## release hardening follow-up

- exact `16090d7...e1753616`のSecurity scan `23c25e97-43eb-45c0-80a1-0682722024d4`は変更source 39 / 39を確認し、sealed complete、reportable finding 0件だった。attack-path policy上のreport対象外だった2件を、初回実用リリース前の安全性・privacy correctness問題として修正した。
- Windows Debug Voice E2Eは`--verify shell|display|ui`との併用を明示拒否する。これにより、E2E専用rootをVerifierのApplicationDataで上書きし、本番Google credential targetやCalendarへ再接続する設定衝突を防ぐ。`VoiceE2EIsolationVerifier`へ3経路のnegative回帰を追加した。
- macOS embedded Realtime rendererはmicrophone captureの世代を管理する。許可待ち中にcloseされたcaptureは、遅れて`getUserMedia`が返ってもtrackを即停止し、peer、SDP offer、session stateを作らない。実際のembedded JavaScriptをNode VMで動かす`verify_macos_realtime_renderer.mjs`を追加し、macOS CIへ組み込んだ。
- `codex-security:verify-fix`で元のsource / control / sinkを再追跡し、Windows設定衝突とmacOS遅延captureを`fixed / fixed`と判定した。ローカルで新renderer回帰、Voice静的42件、Swift warnings-as-errors build、Voice Foundation、Panel layout 128件、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket Surface、Pocket App、Timer、Pocket contract 15 schema / 71 fixtureの2回byte一致、Windows JavaScript / Settings生成先、`git diff --check`が成功した。このMacには.NET SDK / PowerShellがないため、Windows C# buildと`voice-e2e-isolation`実行は更新headのGitHub Actionsを必須gateとする。

## macOS実音声E2E隔離harness

- `b51e7f0`をbaseに、Debug専用marker、専用bundle ID、freshなsystem temp直下root、ephemeral settings、process-memory credential、Timer-only Provider Registryを持つ隔離起動を実装した。Release build、通常bundle、E2E引数不足、verifier併用、nested / occupied / symlink rootは起動前に拒否する。
- E2EではGoogle OAuth callback、Calendar、Weather、Camera、Updater、Clipboard legacy migration、生成Pocket Appを起動せず、本番Application Support、UserDefaults、Keychainへ接続しない。SettingsからAPI keyを入力した場合も現在processのメモリだけで保持し、Stop時にzeroing storeから消去する。
- receiptはexact allowlistのboolean、enum、最終transcript件数だけをatomic保存し、API key、transcript本文、音声、SDP、PID、filesystem pathを保存しない。各media attemptでmic、remote audio、transcript件数、Timer readback、native確認をresetし、Hostの確認sheetを非永続attempt IDへ結合して古い完了通知を拒否する。
- `script/voice_e2e_macos.sh`は`Build → Run → Readback → ValidateIsolation → Validate → Stop → Cleanup`を分離した。Run / Stop / Cleanupはsession単位lockで直列化し、exact command / PID、bundle identity、ad-hoc署名、top-level symlink・型・canonical containment、stopped receipt後のlifecycle確定、exact process不在後のTrash cleanupを確認する。
- 秘密値・マイクなしの実ライフサイクルでは、事前lockによるRun拒否とlifecycle不変、Run成功、receipt存在、credential 0 / media 0、隔離検証、allowlist名`PocketApps` symlink拒否、symlinkをTrash後の再検証、Stop後`safe_close` / credential 0、Cleanup後のsession / build / runtime source不在、exact process不在を別経路で確認した。
- `bash -n`、receipt self-test、embedded renderer、Voice静的契約、Voice Foundation、E2E isolation、Panel layout 128件、Capability 20 handler、Broker 21 descriptor / 20 handler、Pocket Surface、Pocket App package / lifecycle / generation / migration / health / workspace backup、Timer、Swift debug / release warnings-as-errors、Windows JavaScript / Settings生成先、15 schema / 71 fixtureの2回byte一致、`git diff --check`が成功した。
- 最終Security scan `710a8647-1d45-4f45-98dc-56d0b66a5909`はimmutable snapshot `codex-security-snapshot/v1:sha256:ad8cb7efaf599d7e27e9a9512c46448e00ae083b82f2d6459524b96897a96f7a`の20 / 20 changed code / script fileをcoverage complete、reportable finding 0件で封印した。CI workflowとrequirements差分も手動で確認した。
- Draft PR #39 code head `c3435b1b85e8fb05c265a79c9842679eb8cb8688`で、Windows [32952589486](https://github.com/shotaro311/hover-pocket/actions/runs/32952589486)、macOS [32952589632](https://github.com/shotaro311/hover-pocket/actions/runs/32952589632)、Router [32952585405](https://github.com/shotaro311/hover-pocket/actions/runs/32952585405)、Pocket contractの全11 checkが成功した。macOSはbuildとHost-owned Voice Lane step内のreceipt self-test、embedded renderer、Voice静的契約、Voice Foundation、E2E isolationを含む。WindowsはRelease / Debug Voice E2E build、Voice E2E isolation、PowerShell構文、signing contract、rendered WebView2を含む。GitHub readbackは`Draft / OPEN / MERGEABLE / CLEAN`、review 0、comment 0、unresolved thread 0だった。
- 実API key、実マイク、可聴remote audio、ユーザー / assistant transcript、Timer native approval、Hostの「話せた・聞こえた」確認は未実施である。Developer ID署名候補のTCC、notarization、配布、rollback、mergeも別gateのままにする。

## Draft PR / CI readback

- Draft PR: [#39](https://github.com/shotaro311/hover-pocket/pull/39)
- hardening code head: `b32824399a6f63ef012a5ffacddb76de4c3ccc2e`
- base: PR #36 head `16090d7a86c81ab19d85018462814c7279bb8801`
- Windows run [32941881191](https://github.com/shotaro311/hover-pocket/actions/runs/32941881191): SUCCESS。Release / Debug Voice E2E hostの両buildが警告0・エラー0で、Settings、Capabilities、Broker、Pocket Surface、Timer、旧AI lane不在、Voice Foundation、Voice E2E verifier mutual exclusion、PowerShell構文、Updater、signing contract、rendered WebView2の全stepが成功した。
- macOS run [32941881164](https://github.com/shotaro311/hover-pocket/actions/runs/32941881164): SUCCESS。build、late microphone captureのtrack停止 / stale state / SDP offer不在を含むHost-owned Voice Lane、Capabilities、Broker / Today Focus、Pocket App / Surface、Timerが成功した。
- Router run [32941879235](https://github.com/shotaro311/hover-pocket/actions/runs/32941879235): SUCCESS。
- GitHub readback: `Draft / OPEN / MERGEABLE / CLEAN`、review 0、comment 0、unresolved thread 0、remote parity `0 / 0`。
- CI成功は自動検証の証拠であり、実マイク、可聴remote audio、署名済み配布の証拠には使わない。

## 未完了gate

1. Windows実機で、default-off、明示enable、実マイク、可聴remote audio、Timer承認/readback、native physical confirmation、Stop後resource 0を確認する。
2. macOS実機で、隔離harnessへユーザーがAPI keyを入力し、default-off、明示マイク操作、実発話 / 可聴remote audio、最終transcript、Timer承認/readback、Host native確認、`Validate`、Stop後resource 0を確認する。通常の署名済み候補ではCalendar grant off / on、Calendar承認/readback、mute / end / WebContent異常時の物理track停止を別途確認する。
3. macOS Developer ID / notarization / staple / Gatekeeper / Sparkleと、Windows timestamped Authenticode / Velopack / feedをfinal source artifactで別々に確認する。
4. install、upgrade、rollback、uninstall、reinstall、user data保持を両OSでreadbackする。
5. Draft PRをReady、merge、releaseへ進める判断は上記gate完了後に行う。

## rollback単位

- R3のcredential / startup境界に問題があればR2へ戻す。
- macOS Voiceだけに問題があればR1を保持し、R2差分を再監査する。
- runtimeはVoice default-offを安全弁とし、無効化後のmic / WebRTC / session resource 0をreadbackする。
- credentialをrollbackで暗黙削除しない。Pocket Appはimmutable versionへ戻し、permission、version、digest、data、runtimeをreadbackする。
- release rollbackはGitのrevertだけで完了扱いにしない。
