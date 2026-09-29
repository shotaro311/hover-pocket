# macOS build 631 本番配信

## 依頼と公開対象

ユーザーの「配信お願い」により、音声で既存機能を確認・編集する改善版を本番公開した。追加確認なしで配布ビルド、署名、公証、ソースtagのpush、GitHub ReleaseとmacOS専用フィードの更新を実施した。

- 公開: https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-631
- ソース: `742158a1e4d6ec1cf168e11642767e3a089d7ce1`、remote tag `v0.1.0-631`との一致を確認。
- macOS専用フィード: `macos-latest`。Windows `win-v0.2.7`のasset metadataは配信前後で一致した。

## 検証

- Developer ID署名・Apple公証Accepted・staple・Gatekeeper: PASS。
- 公証後のZIP再展開appで新機能42 assertions、Broker、Voice Foundation、Capability、Timer、Panel layout: PASS。
- 公開stable ZIPの再downloadでローカルZIPとのbyte一致、build 631、strict codesign、stapler、Gatekeeper、Google callback設定、location entitlement: PASS。
- 既存の共通release readbackは93 checks PASS。macOS stable/versioned ZIPのhashとSparkle Ed25519署名、Windows betaの公開feedと全assetを検証した。WindowsのAuthenticode署名は未対応betaとして検証した。
- 証拠: `progress/evidence/2026-09-06-macos-release-631/receipt.json`と`release-readback.json`。

## 残る境界

インストール済み`/Applications/HoverPocket.app`は630であることをreadbackし、置換していない。アプリ内更新から631へ更新できる。実マイクでの全新操作、実Google予定の編集・削除・参加者通知、実メディア再生元の全組み合わせは未検証。Windows新機能実装や配信は対象外。
