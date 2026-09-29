# 機能ライブラリによる個人用ツール生成

## 依頼と範囲

2026-09-08、登録済みの機能をCodexが選んで組み合わせ、追加・削除と利用関係を管理する構成について合意し、実装依頼を受けた。既存の作業ブランチ `codex/pocket-tools-platform`、`hover-menu-preview-macos-release-629` の隔離作業ツリーで実装。macOSローカル変更と検証を実施し、公開・本番アプリ置換・Windows配布はしていない。

## 実装

- `PocketLibraryCatalog`に9個の同梱モジュールを登録。操作の権限とeffectは既存descriptorから取得し、別の権限台帳を作らない。
- 生成時の有効な台帳をCodexへ渡し、request digestに結び付ける。生成可能な5操作を固定プロンプトから台帳由来へ変更。標準画面・HTML・記録保存も有効範囲を検査する。
- 依存関係は既存manifestから導出。導入済みの全バージョンと作成履歴を読み、使っているライブラリは無効化できない。履歴が壊れて読めない場合も停止する。有効化は回復のため可能。
- 自作ツール設定に「機能ライブラリ」の一覧、利用中ツール、有効・無効スイッチを追加。生成中・導入確認中は変更を拒否。
- 生成候補・導入・履歴復元・起動時に利用可否を検査。バックアップ復元も準備時と実行直前に全対象のライブラリを検査し、データの書き換え前に拒否する。
- Codexの音声Host/driverとツール生成factoryを `PocketCodexLibrary` に集約。既存のセッション所有者・キャンセル・認証経路は継続する。旧CLI adapterは既存検証用として残す。
- UserDefaultsへ `disabledPocketLibraries` だけ追加。既存設定のキー省略、無効化、空配列へのロールバックfixtureとschemaを追加。manifest v1/v2・記録・履歴・バックアップの形式は変更しない。

[設計判断と追加手順](../../docs/plan/20260908_POCKET_LIBRARY_ARCHITECTURE.md)。新しい実行コードの配布は開発側のアプリ更新で行い、今回のスイッチはツール向けの有効・無効を管理する。

## 検証とreadback

- Swift build: PASS。
- 新規 `--verify-pocket-libraries`: 49 checks PASS。重複登録、循環・欠落依存、OS差、間接依存の保護、要求digest、無効な画面を含む生成拒否、有効な同一入力の対照、旧設定再読込、利用中・無効ツール・履歴だけのツールの保護、壊れた履歴の停止、有効化による回復、バックアップ準備/実行直前の拒否、記録の不変を確認。
- 既存 `--verify-pocket-tools-platform`: 78 checks、`--verify-pocket-app-os`: 49 checks PASS。
- `--verify-pocket-app`: package / lifecycle / generation / activation / capability migration / health / workspace backup PASS。旧manifestとgenerationのgolden digestも一致。
- 共通契約: v1 72 fixtures、v2 53 checks、Voice 42 checks PASS。
- 音声Foundation、音声波形/lifecycle 37 checks、panel layout、WebKit 20 checks PASS。
- 実Astra生成: 2種類 PASS。読書メモは `pocket.collections` だけ、HTML作業開始は `pocket.html` / `pocket.sticky` / `pocket.timer` を選択。使わないライブラリを無効にした台帳を渡し、Hostが生成物の依存関係を独立して再計算して一致を確認。300px/520pxの小型画面と最大文字のpreview検査もPASS。
- 実生成された作業開始ツール: 既存の操作検証で、Host確認の準備・取消では書込みなし。承認で実TimerStoreとStickyNotesStoreへ反映し、receiptと別経路の付箋再読込を確認。
- 実SwiftUI設定: 一時ディレクトリとEphemeral設定の専用ウィンドウで、9行、Codexの本体使用中表示、タイマーのon→off→onと結果メッセージをComputer Useで確認。暗色・560x800・縦スクロールを視認。終了時に専用ウィンドウと専用プロセスを終了。
- `git diff --check`: PASS。

[検証ログとsource hash](../evidence/2026-09-08-pocket-libraries/)。

## 検証中に修正した点

初回の実生成検証は、生成後の検証保存先を作り忘れて失敗した。検証側で保存先を準備し、再実行した2種類は通過。無効なライブラリの拒否検証にも同じ入力が有効時に通過する対照を加え、保存先の失敗を機能の拒否と誤認しないようにした。

アンインストール検証は初め、インストール時の履歴を作らずに直接lifecycleを操作していた。通常の導入履歴を持つfixtureに直し、履歴保護を確認した。

設定UIの検証用bundleは、既存のVoice E2Eアプリと同じ識別子を避け、専用のアプリID・Keychain suffix・標準metadataで再署名した。UIは元から一時保存先・Ephemeral設定を使い、既存アプリや本番設定は操作していない。これは配布用成果物ではない。

## 境界

Codexライブラリは本体専用。生成ツール自身が文章要約などのAI呼び出しを行うAPIは未提供であり、利用可能と表示しない。ライブラリの任意ダウンロードや個別バイナリ更新も含めない。

既存の物理マイクE2EとWindows実機受入は今回の検証に含めない。バックアップ処理全体のクラッシュ復旧設計を変更したものではなく、今回はライブラリ不一致を処理前に拒否する変更。

承認済みの実装範囲としてローカル編集・非破壊検証・検証用AI呼出しを追加確認なしで実施した。本番公開は別途。

## 本番配信

追加の配信依頼により、macOS 642として公開し、このMacもSparkle経由で更新済み。[配信とreadback](2026-09-08_hover-pocket-ai-release.md)。
