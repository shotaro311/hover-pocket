# HoverPocket Agent Instructions

このリポジトリで作業する AI エージェントは、実装前に次を読む。

## 必読

- `progress/progress.md`: 現在の状態、直近の検証、未完了事項を確認する。
- `docs/requirement/requirements.md`: HoverPocket の体験原則、Windows 要件、Mac / Windows 横断運用方針を確認する。

## 作業別の追加確認

- macOS 実装、配布、Sparkle 更新に触る場合は `README.md` と `script/` の対象スクリプトを読む。
- Windows 実装、配布、更新に触る場合は `windows/README.md` と `windows/script/` の対象スクリプトを読む。
- 作業終了時は `progress/progress.md` と日別ログへ、実行した検証と readback 結果を残す。

## 横断リリース方針

- macOS と Windows は GitHub Releases の `latest` を共有しない。
- macOS は macOS 専用 appcast URL を使う。
- Windows は Windows 専用 feed を使う。
- 配信後は各 OS の feed と成果物を別経路で readback する。
