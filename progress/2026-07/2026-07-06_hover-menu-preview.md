# 2026-07-06: Cross-platform agent read gate

## 目的

- Mac / Windows の 2 バージョン運用で、他の AI エージェントが作業前に同じ正本を読むようにする。
- 新しい `product.md` ルールは増やさず、既存の開発 docs ルールへ寄せる。

## 変更

- project root に `AGENTS.md` を追加。
  - 必読入口を `progress/progress.md` と `docs/requirement/requirements.md` に固定。
  - macOS 作業時は `README.md` / `script/`、Windows 作業時は `windows/README.md` / `windows/script/` を追加確認するよう明記。
  - macOS / Windows が GitHub Releases の `latest` を共有しない方針を明記。
- `docs/requirement/requirements.md` に `1.4 Mac / Windows 横断ワークフロー` を追加。
  - OS 別担当、共通仕様の置き場所、release feed 分離、readback 完了条件を requirements の正本に統合。
- `progress/progress.md` の先頭に今回のドキュメント更新を追記。

## 検証

- `git diff --check`: 成功。
