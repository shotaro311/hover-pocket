# HoverPocket Agent Instructions

このリポジトリで作業する AI エージェントは、実装前に次を読む。

## 必読

- `progress/progress.md`: 現在の状態、直近の検証、未完了事項を確認する。
- `docs/requirement/requirements.md`: HoverPocket の体験原則、Windows 要件、Mac / Windows 横断運用方針を確認する。

## 作業別の追加確認

- macOS 実装、配布、Sparkle 更新に触る場合は `README.md` と `script/` の対象スクリプトを読む。
- Windows 実装、配布、更新に触る場合は `windows/README.md` と `windows/script/` の対象スクリプトを読む。
- 作業終了時は `progress/progress.md` と日別ログへ、実行した検証と readback 結果を残す。

## Codex Voice Lane

`feature/codex-voice-lane` またはPR #6で作業する場合は、実装前に次を必ず読む。

- `docs/plan/20260806-codex-voice-lane-plan.md`
- `docs/report/20260806-codex-voice-lane-architecture-review.md`
- `docs/report/20260806-codex-app-server-upstream-verification.md`
- `progress/2026-08/2026-08-06_hover-pocket-codex-voice-lane-review.md`

アーキテクチャレビューのCritical 3件を解消しないまま、UI・microphone・WebRTCの本実装へ進めない。

1. voice session / app-server / thread状態を `PanelWindow` とWebView2の寿命から分離する。
2. UI用 `BridgeDispatcher` をapp-server clientとして流用せず、専用 `CodexAppServerClient` を作る。
3. `AiLaneHeight` を静的定数のまま使わず、disabled / compact / expandedを含む動的レイアウトへ変更する。

現在のブランチには上記3件の基盤型とVerifierがあるが、`PanelWindow` / `HoverShellController` / WebView2 UIへの本番接続は未実装である。基盤が存在することを、機能が完成した証拠として扱わない。

Codex app-serverのwire仕様は、対象PCにインストールされたCodex自身が生成するJSON Schemaを正本とする。現行公式資料では`v2 + WebRTC`は非対応とされているため、その組み合わせをハードコードしない。Phase 0で利用可能versionとtransportを実測し、互換性がない場合はVoice Laneだけをfail closedで無効化する。

各milestoneのpush後はPR #6へ、到達点、変更ファイル、実行コマンド、verifier結果、実機確認、未確認事項を記録する。Phase 0 / 0.5の実測と実音声E2Eが揃うまで、PRをDraftのまま維持し、mergeしない。

## 横断リリース方針

- macOS と Windows は GitHub Releases の `latest` を共有しない。
- macOS は macOS 専用 appcast URL を使う。
- Windows は Windows 専用 feed を使う。
- 配信後は各 OS の feed と成果物を別経路で readback する。