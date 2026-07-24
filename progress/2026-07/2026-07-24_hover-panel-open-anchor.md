# 2026-07-24 HoverPocket Panel Open Animation Anchor Fix

## Summary

- 妻のM2 Mac（配布版build 127）で、パネルの開閉アニメーションが画面上部中央からではなく右上部から左へスライドして見える、という報告を受けた。
- 原因機構は `NSHostingController` の既定 `sizingOptions`。`HoverPanelShell` が固定 `.frame(width:height:)` を持つため、SwiftUIの固有サイズがウィンドウのmin/maxサイズとして確定し、開始フレーム `collapsedPreview`（72x12）が左上を起点に全幅へ引き伸ばされる。左端がノッチ中央−36ptに残ったまま右へ拡大するので、中心が本来より大きく右へ寄り、そこから目標フレームへ左スライドして見える。
- プレビュー／アクセス両ウィンドウの `NSHostingController` に `sizingOptions = []` を設定した。

## 重要な限界（未確認事項）

- **開発機（macOS 26 / Darwin 27、ノッチなし2560x1440、miniBar経路）では、配布版build 127の時点で既に症状が再現しない。** 実アプリのCoreGraphics readbackで、build 127も修正版も開始70x12・中心オフセット0で対称に開くことを確認した。
- したがって本修正は「症状を再現する実機で直ったことを確認した」ものではない。確認できたのは次の2点にとどまる。
  1. 単体プローブで、既定 `sizingOptions` が報告どおりの右寄せ拡大を生むこと。
  2. 開発機で本修正が回帰を起こさないこと。
- 妻のM2 Macでの最終確認は、build 131配布後の実機確認が必要。

## Implementation

- `HoverWindowController.configurePreviewWindow` / `configureAccessWindow` で `NSHostingController` 生成後に `sizingOptions = []` を設定。
- 幾何計算（`PanelGeometry`）とアニメーション本体は変更なし。
- 併せて寸法制約の明示クリア（`contentMinSize` / `minSize` を0にする）も試したが、プローブで**単独では無効**と判明したため採用しなかった。

## Verification

- `swift build`: passed。
- `--verify-panel-layout`: passed、63ケース。
- `--verify-calculator`: passed、結果 `25`、履歴1件。
- `--verify-clipboard`: passed。
- `git diff --check`: passed。
- 緩和策比較プローブ（scratchpad、開発機で実行）— 開始フレーム72x12を中心x=1280に置いた場合:

  | sizingOptions | 寸法制約クリア | 実フレーム | centerX | 判定 |
  |---|---|---|---|---|
  | 既定 | なし | 680x488 | 1584 | 右へ304ptずれる（症状再現） |
  | 既定 | あり | 680x488 | 1584 | 右へ304ptずれる（無効） |
  | `[]` | なし | 72x12 | 1280 | 中央維持 |
  | `[]` | あり | 72x12 | 1280 | 中央維持 |

- 実アプリのアニメーションreadback（CoreGraphicsでウィンドウ矩形を4ms間隔サンプリング、カーソルを上端へワープして開かせる）:
  - 配布版build 127: 開始 70x12 / 中心オフセット 0、最大中心オフセット 0。
  - 修正版dist: 開始 70x12 / 中心オフセット 0、最大中心オフセット 0。回帰なし。

## Remaining

- 妻のM2 Macへbuild 131を導入し、開くアニメーションが中央起点になるか実機確認する。
- 直らない場合は、そのMacのmacOSバージョン、ノッチ有無、外部ディスプレイ構成、`displayPlacementMode` 設定を取得して再調査する。原因が別（ウィンドウ位置の持ち越し、複数ディスプレイ選択）である可能性が残る。

## Release (build 131)

- commit `83a7e23` を `origin/main` へpush後、`NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh` を実行した。
- 公証 submission `ae7f4e7e-aed6-41e2-9d60-22af75c644aa` = `Accepted`。
- Release: https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-131
- macOS feed: https://github.com/shotaro311/hover-pocket/releases/tag/macos-latest
- readback: 公開ZIP SHA-256 `97c4819f...1dd79c` がローカルと一致、手動インストールZIPも同一。`CFBundleVersion=131`、codesign / stapler / spctl 合格、appcast `sparkle:version=131`。
- 注意: 配信直後のappcast取得はCDNキャッシュで旧versionを返すことがある。`Cache-Control: no-cache` とクエリ付きで再取得すること。
