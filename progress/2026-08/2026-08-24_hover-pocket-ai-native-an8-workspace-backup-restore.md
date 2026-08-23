# HoverPocket AI-native AN8-C workspace backup / restore

## 目的

ユーザー所有の生成Pocket App定義、version履歴、lifecycle状態、ユーザーデータを、macOS / Windows共通形式で書き出し、検証・preview・明示承認・readback・失敗時rollbackを通して復元できるようにする。

## ChatGPT Pro回収

- 正本run `20260824-000623-hoverpocket-an8-cpocket-app-workspacebackup-export-restoredata-version-readbackmacoswindowschanges-patch`は、通知のdelivery IDとstate hashを`claim-synthesis`で検証してclaimした。
- completion statusは`blocked`、理由はsame-session harvest timeoutだった。`response.md`は空で、`pro-receipt.json`、`artifact-manifest.json`、`auto-collect-receipt.json`は存在しなかった。
- 適用可能な成果物がないため再送せず、Skillのblocked例外に従い、PR #30 exact head `d93abf8`から隔離branch `codex/ai-native-an8-backup-restore-core`を作ってCodexが実装した。

## 実装

- 共通契約:
  - `hoverpocket.pocket-app-workspace-backup/v1`のDraft 2020-12 schemaとvalid / traversal fixtureを追加した。
  - 単一canonical JSONへ、検証済みpackage全version、active version / digest、state schema digest、enabled / disabled、effective permission、data version / digest、`state.json`を格納する。
  - file entryは安全なPOSIX相対path、decoded size、SHA-256、canonical base64 bytesへ束縛する。
- 対象外:
  - OAuth、credential、Capability audit / receipt、Codex workspace、外部path、symlink / reparse pointをexportしない。
- 上限と拒否境界:
  - 64 App、2,048 files、1 MiB / file、64 MiB decoded、96 MiB encoded。
  - traversal、absolute path、Unicode非正規化、case-insensitive衝突、未参照file、hash / base64 / schema / package / permission不一致、stale previewを副作用前に拒否する。
- 承認と実行:
  - 追加 / 置換、version、enabled / disabled、permission差分、data変更をpreviewする。
  - backup digestとcanonical previewをbinding digestへ束縛し、5分以内・1回限りのgrantを使う。
  - macOSはSwiftUI native alert、WindowsはHost native `MessageBox`を使い、どちらもキャンセル / Noを既定操作にする。WebViewへfilesystem pathを渡さない。
- commit / readback / rollback:
  - 既存Lifecycleのstage / approve / install / rollback / disableを再利用し、生成UIやCodexからProvider Storeへ到達させない。
  - Windowsは復元対象Appの未保存Surface state flushを待つ。macOS state bindingは既存runtimeが変更時に同期保存する。
  - commit後にLifecycle、runtime activation、permission、data digestをreadbackする。失敗時は復元前snapshotへ補償rollbackし、rollback失敗は成功表示しない。
- UI:
  - 両OS Settingsへ「workspaceを書き出す」「backupから復元」、restore preview、readback表示、対象外データの説明を追加した。
  - Windowsの保存先 / 復元元はnative file dialogだけで選択し、Bridge routeはpath引数を受け取らない。

## deterministic検証

| 検証 | 結果 |
|---|---|
| `swift build -Xswiftc -warnings-as-errors` | 成功 |
| macOS `--verify-pocket-app` | package / lifecycle / generation / migration / health / workspace backup、全成功 |
| workspace backup | deterministic export、OS portability、正常roundtrip、取消、binding mismatch、stale preview、tamper、traversal、case衝突、oversize、commit失敗rollback、runtime readback失敗rollback、成功 |
| `--verify-capabilities` | 20 handler、成功 |
| `--verify-broker` | 21 descriptor / 20 handler、成功 |
| `--verify-pocket-surface` | 15 negative、成功 |
| `--verify-timer` | 成功 |
| `--verify-panel-layout` | 128件、成功 |
| `--verify-voice-foundation` / `script/verify_voice_foundation.py` | 成功 |
| `script/verify_pocket_contracts.py` | 15 schema / 71 fixture、全一致 |
| Windows Settings JavaScript / generation target | 構文・state helper、成功 |
| `git diff --check` | 成功 |
| Draft PR #31 Windows CI [32662630254](https://github.com/shotaro311/hover-pocket/actions/runs/32662630254) | Release build成功、`pocket_app_workspace_backup_verify=ok`、Settings / Voice / Broker / rendered UIを含む全検証成功 |
| Draft PR #31 macOS CI [32662630273](https://github.com/shotaro311/hover-pocket/actions/runs/32662630273) | warnings-as-errors build、`pocket_app_workspace_backup_verify=ok`、Capability / Broker / Voiceを含む全検証成功 |
| 3 OS contract CI [32662630305](https://github.com/shotaro311/hover-pocket/actions/runs/32662630305) | Ubuntu / macOS / Windowsで15 schema / 71 fixture成功、3 reportのbyte一致 |

初回Windows CI [32662469903](https://github.com/shotaro311/hover-pocket/actions/runs/32662469903)は、`IReadOnlySet<string>`向けcollection expressionなどのC#コンパイルエラー6件を検出した。明示的な`HashSet<string>` / `string[]`と文字列overloadへ修正したcommit `d00de9b`で、上記Windows CIが成功した。

## PR readback

- Draft PR [#31](https://github.com/shotaro311/hover-pocket/pull/31)のexact headは`d00de9b3f38c104a6d3048acdd493ec945a2de5c`。
- 全7 checkが成功し、失敗0、pending 0。PRは`Draft / OPEN / MERGEABLE / CLEAN`である。
- review / comment / unresolved threadは0件。local / remote parityは`0 / 0`、worktreeはcleanである。
- 自動mergeは行わず、stack base `codex/ai-native-core-ga-legacy-path-removal`への人手review gateを維持する。

## 未完了gate

- macOS / Windows実機でnative file dialog、既定No、実データを含む相互importを最終確認する。
- AN8-C完了後もCore GA全体では、production Voice positive tool allowlist / 実音声E2E、実Codex confinement E2E、Windows正式署名済みrelease / rollback、stack PRの人手mergeが残る。
