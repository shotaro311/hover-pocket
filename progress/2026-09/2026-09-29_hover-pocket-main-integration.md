# Mac本番644のmain統合

## 対象と判断

ユーザーの「メインの統合」依頼に基づき、`main`（1782066）へ本番644を含む `codex/pocket-tools-platform`（35701a4）を履歴を保持して統合する。専用worktreeで作業し、既存作業フォルダの未コミット変更は保持する。

- main固有の両OSアイコン更新、Windows 0.2.8表記、GitHub Codex Autofix廃止を保持。
- 競合は `progress/progress.md` の日付・冒頭履歴だけ。両方の履歴を保持し、現在地を冒頭へ追加。
- 本番644のMac実装、共有契約、関連Windows実装を統合。アプリの新規配信・入替は対象外。
- 既存の古い作業ブランチやPRを一括削除・終了しない。

## 統合時に修正した検証不備

- Codex認証検証のschema固定ハッシュが、個人用ツールのcollections/views追加前の値だった。元ブランチでも失敗を再現し、eae1f22のschema変更を確認して更新。改変されたschema/fixtureを引き続き拒否する回帰テストを追加。
- 音声の承認検証で、付箋v2の実handlerとstubを二重登録していた。stub除外キーを実handler一覧から導出し、23項目の検証が成功。
- App OS音声検証のdispatchMain経路でMainActorスレッド警告が発生。既存のGUI検証と同じNSApplicationイベントループを使い、実Codexのcatalog読取・終了と警告消失を確認。
- macOS CIへ音声承認検証と認証契約のPython回帰テストを組み込み、再発を検出する。配布メタデータ23テストは既存Ubuntu CIで実行する。

## ローカル検証

- Debug / Release warnings-as-errorsビルド成功。検証コード修正後の最終Releaseビルドと音声承認・Personal Tools・付箋通知の検証も成功。
- 共有v1契約72、v2契約62、付箋通知契約18、Voice静的42、Python30テスト、認証/隔離/音声receiptのself-testが成功。
- Capability、Broker、Pocket Surface、Package/lifecycle/generation/migration/health/backup、Timer、付箋通知、Voice Foundation/Activity、Personal Tools、Voice E2E隔離、Panel Layout/100回soak、天気地点、Tools Platform、Libraries、AI Text、App OS、天気音声、音声承認、Codex app-serverが成功。
- App OSの実Codex catalog読取は1回実行・正常終了。実マイク発話とは区別する。
- Windows UIのJavaScript構文・設定生成対象の検証成功。Windows native build/実行はGitHub CIで確認予定。
- 公開644のZIPとインストール済み105ファイル一致、署名・公証・Gatekeeperは本チャットの直前調査で確認。

## GitHub CIで判明した追加修正

- macOS runner既定のXcode 16.4 / Swift 6.1.2がemit-moduleでsignal 11となった。公式runner imageの同梱一覧を確認し、Xcode 26.3を明示選択する。アプリの対応OS下限は変更しない。
- 音声の削除確認設定に合わせた説明文3件が共有operations.jsonへ未反映だった。既存exportコマンドから再生成して完全一致を確認。操作ID・型・権限・schemaの変更はない。
- runner参照: https://github.com/actions/runner-images/blob/macos-15-arm64/20260907.0337/images/macos/macos-15-arm64-Readme.md

- Windows CIはDebug/Release・installer・Capability・Brokerまで成功後、共有generation schemaとの不一致で停止。Windowsの出力schemaを共有正本へ一致させ、Mac専用collections/viewsをWindowsのmaterializerが拒否する既存制約は保持。拒否ケース2件を追加した。WindowsでMac専用機能が使用可能になったとは扱わない。

- macOS CIへPython全件を追加した際、既存のOpenSSL依存の配布署名テストがrunner環境で失敗した。配布検証は従来どおり既存Ubuntuジョブで23テストを実行し、macOSジョブは設定5件・認証契約2件を明示実行する。テストの削除や署名検証の緩和は行わない。
- 9f4325dのWindows CIは全段階が成功。Macもビルド・音声・Capability・Broker・保存復元・Timer・天気地点まで成功。

## 統合とreadback

- [PR #41](https://github.com/shotaro311/hover-pocket/pull/41)をユーザーの明示依頼に基づきmerge。検証head `bd34e8b`、merge commit `48c1c037333931cb724de093dc97fd6a06d7b0cb`。両者のtree一致を確認。
- 最新headのCIは10 SUCCESS、8 SKIPPED、failure/pending 0。Mac / Windowsのnative buildと既存機能検証、3 OS契約と比較、配布/更新スクリプト検証が成功。配信・実機インストールの8件はPRで意図したskipであり、受入済みとは扱わない。
- 元フォルダのmainをfast-forwardし、GitHub mainと同一SHAを別経路でreadback。元の未追跡49ファイルは全件SHA-256不変。うち4件は同一内容の追跡ファイルになった。
- 既存progressの34行追記は、原本・patch・stashで保全し、この記録反映後に同じmain作業フォルダへ未コミット差分として戻す。既存の他worktreeは変更していない。
- macOS appcastのSHA-256は事前調査と不変。公開アプリは644のままで、新規配信なし。
- [検証結果とCIリンク](../evidence/2026-09-29-main-integration/readback.json)。本記録の追記は統合後の文書変更のみ。

## 未検証範囲
- 実マイク会話、他Mac、Windows実機の利用者操作は今回の受入対象外。

## 参照

- [本番644の配信記録](2026-09-11_hover-pocket-sticky-reminders.md)
- [Autofix廃止](2026-09-23_github-codex-autofix-retirement.md)
