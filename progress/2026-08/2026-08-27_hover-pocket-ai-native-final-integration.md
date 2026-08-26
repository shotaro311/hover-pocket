# HoverPocket AI-native Core GA final integration follow-up

## 目的

AN5のproduction Codex Pocket App生成を有効化せず、macOSで実Codex CLIのfilesystem / network隔離境界を先に証明する。CIへは再現可能な自己テストを追加し、実行canary、credential delivery、Windows隔離、Voice物理E2E、署名・配布を別gateとして維持する。

## ChatGPT Pro回収状態

- Pro run `20260826-132725-hoverpocketan8realtime16090d7windows-voice-7472c73macos-voice-5883925an5-mutual-credential-e4cd8f0criticgate`は、既存sessionのbounded recovery後にstate `completed`、受入4 / 4、terminal receipt `complete`であることをreadbackした。
- 同一deliveryは処理済みであり、新規prompt、重複claim、成果物の再適用を行っていない。
- Pro criticの境界どおり、production生成はoffのまま、macOS隔離canaryだけを独立した次の証拠にした。

## 実装

- `script/verify_codex_generation_confinement_macos.py`
  - fixed npm vendor pathだけを候補にする。
  - regular file、非symlink、owner、group / world write禁止、OpenAI Developer ID authority / Team ID、strict codesign、exact `codex-cli 0.145.0`を検証する。
  - fresh temp root内のworkspaceをread-only、Codex Home / virtual User Homeをdeny、networkをoff、shell environment inheritanceをnoneにする。
  - root外sibling fileとloopback listenerをcanaryにし、outside-root readとnetwork接続を実行時に検証する。
  - 10秒timeout、process group TERM / KILL、bounded stdout / stderr、exact JSON、canary非露出、cleanup rootの親・prefix・type・owner検証を行う。
  - receiptはallowlist booleanとpinned versionのみを出力する。
  - `--self-test`は期待結果を1項目ずつ反転して拒否し、named permission profileの固定markerも確認する。
- `.github/workflows/macos-capabilities-verify.yml`
  - script変更をpush / pull request triggerへ追加した。
  - Python compileと`--self-test`をmacOS CIへ追加した。
  - CI runnerへ署名済みpinned CLIがあることを仮定せず、実sandbox canaryはlocal / manual evidenceとして分離した。
- `Sources/HoverPocket/PocketApps/CodexPocketAppGenerationAdapter.swift`の`supportsConfidentialGeneration == false`は変更していない。

## ローカル検証

- `python3 script/verify_codex_generation_confinement_macos.py --self-test`: PASS
- `python3 script/verify_codex_generation_confinement_macos.py`: PASS
  - signed executable: true
  - workspace read: true
  - workspace write denied: true
  - Codex Home read denied: true
  - virtual User Home read denied: true
  - outside-root read denied: true
  - network denied / loopback listener unreached: true
  - stderr bounded: true
- symlinkの`/opt/homebrew/bin/codex`を`--codex-bin`へ指定するnegative test: 想定どおりregular file検証でFAIL
- `swift build -Xswiftc -warnings-as-errors`: PASS
- `.build/debug/HoverPocket --verify-pocket-app`: PASS。package、lifecycle、generation、migration、health、workspace backupを含む
- workflow YAML parse: PASS
- `git diff --check`: PASS

## Codex Security readback

- scan ID: `a020f0d1-bfde-401f-94ab-243146343be9`
- snapshot: `codex-security-snapshot/v1:sha256:ff99dad207ee72deafdbf38d21001cb1444b175dfdd61da4a96ee2b4b838ee05`
- mode: exact working-tree diff
- coverage: complete
- reportable finding: 0件
- reviewed surfaces:
  - macOS Codex generation confinement executable verifier
  - macOS capabilities CI integration
  - production Codex Pocket App generation fail-closed root control
- limitations:
  - 実canaryはmacOS Seatbeltのみ。
  - CIはdeterministic self-testのみ。
  - credential delivery、実モデル生成、Windows confinement、Voice物理E2E、署名、releaseは対象外。

## Draft PR / CI readback

- code head: `8cd445bdf6ebf6fe7c3150aea877be7c459fd035`
- remote parity: `0 / 0`
- Router [33022367720](https://github.com/shotaro311/hover-pocket/actions/runs/33022367720): SUCCESS
- macOS [33022481993](https://github.com/shotaro311/hover-pocket/actions/runs/33022481993): SUCCESS。Swift build、Codex confinement self-test、Voice、Capability、Broker、Pocket App / Surface、Timerが成功し、logで`PASS Codex generation confinement verifier self-test`と`pocket_app_generation_verify=ok`をreadbackした。
- Windows [33022484529](https://github.com/shotaro311/hover-pocket/actions/runs/33022484529): SUCCESS。Release / Debug Voice E2E build、Settings、Capability、Broker、Pocket Surface、Timer、Voice Foundation / E2E isolation、Updater、signing contract、rendered WebView2が成功した。
- 3OS Pocket contract [33022486583](https://github.com/shotaro311/hover-pocket/actions/runs/33022486583): SUCCESS。Ubuntu / macOS / Windows verifierとreport比較の4 jobが成功し、3 reportのbyte一致をlogでreadbackした。
- PR同期時はRouterだけが自動起動し、通常の`pull_request` workflow runが作成されなかった。上記3本は同じexact headを手動dispatchした証拠であり、PR required checkへの接続を代替しない。
- 最終進捗commitを含むhead `ebb0aa7570acfd0db1bb4c85ffac9cb89234926f`では、遅れて通常のPR workflowが自動起動した。Router [33022842034](https://github.com/shotaro311/hover-pocket/actions/runs/33022842034)、macOS [33022844429](https://github.com/shotaro311/hover-pocket/actions/runs/33022844429)、Windows [33022844408](https://github.com/shotaro311/hover-pocket/actions/runs/33022844408)、3OS Pocket contract [33022844417](https://github.com/shotaro311/hover-pocket/actions/runs/33022844417)の全7 checkがSUCCESSである。
- Draft PR #39は`Draft / OPEN / MERGEABLE / CLEAN`、review 0、comment 0、unresolved thread 0へ戻った。CI greenは実マイク、実API、credential delivery、production生成、署名、配布の完了証拠には使わない。

## 未完了gate

1. Windowsでequivalentなrestricted-token / AppContainerのoutside-root、write、network canaryを実装・readbackする。
2. macOS / Windows双方でHost-owned一回限りcredential deliveryを隔離generatorへ接続し、秘密値をargument、environment、disk、logへ残さないことを確認する。
3. 同じ隔離境界でPocket App DSLを1件生成し、schema検証、preview、install、activation、readback、remove / rollbackまで確認する。
4. 両OSの実API key / microphone Voice E2E、正式署名、配布、rollbackを別々に完了する。
5. 上記が完了するまでproduction generatorを有効化しない。
