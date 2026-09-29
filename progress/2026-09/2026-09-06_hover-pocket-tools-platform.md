# 個人用ツール基盤の実装

## 依頼と採用した設計

ユーザーは、思いついたツールをアプリ内Codexとの会話で作成し、プレビュー、導入、追加編集、削除、作成途中の履歴への復元を行える基盤を依頼した。ファイル置き場は例示で固定要件ではない。標準画面と隔離HTML、共通Host API、更新可能なガイド、v1を維持するv2保存契約と移行・履歴設計を採用済み。追加確認をせず承認範囲のローカル実装と検証を進めた。外部公開は今回の作業範囲に含まれない。

開発モデルはGPT-6 Astra High、アプリ内はAstra Mediumが既定。設定で選べる推論強度は利用可能なモデル情報から取得し、変更済み値を保持する。

## 実装済み

- v2 package、型付きcollection、host生成ID、revision競合検知、ツール単位の保存隔離。標準SwiftUI画面で検索・追加・編集・削除。
- WKWebViewのopaque sandbox子frameと制限付きbridge、CSPとネットワーク遮断、権限操作のnative確認。実WebKit受入は以下の未完了欄を参照。
- Codex app-serverのAstra生成。ガイド取得、ファイル単位のdraft書き込み、検証APIを使用し、大きな一括応答の出力上限を回避。以前のdraftを引き継ぐ会話編集。
- 成功したプレビュー単位の履歴。変更なしの重複を省き、直近20件/100 MiB以内で使用中と直前版を保護。除外物はゴミ箱へ移す。runtimeに必要な現在と直前の定義も容量に算入し、古いruntimeコピーはゴミ箱へ移す。データバックアップは上限に含めない。
- collectionの互換移行。任意項目追加は最新レコードとIDを維持。削除項目は影響を示し、事前バックアップを保持。値の推測変換は拒否。承認時点以降のデータ変更を検知して停止。
- 共有ファイルlock、journal、失敗時と次回起動時のdefinition/data復元。定義のrollbackも最新入力値を対象にし、古いデータを無言で上書きしない。
- v2バックアップにstate/collectionsを含め、復元前の原本を保持。v1バックアップの既存経路も維持。

## 検証済み

- Swift Debug（warnings-as-errors）とReleaseビルド成功。最終build632はDeveloper ID署名、Hardened Runtime、release用keychain suffixを設定した。
- 署名付きbundleの`--verify-pocket-tools-platform`: 61 checks PASS。CRUD、null/空/省略、競合、破損・symlink拒否、履歴保持、v2導入/再起動、移行後ID/最新入力保持、承認後変更拒否、v2バックアップ、1 MiB超のデータ復元、journal中断復旧、設定保持、runtime定義保持上限、Trash失敗時の履歴増殖防止、v2の付箋保存先制限。
- 同bundleの`--verify-pocket-app`: package、18 negative、lifecycle、generation、capability migration、health、workspace backupがPASS。既存v1を維持した。
- 同bundleのBroker、Personal Tools、Voice FoundationがPASS。codesign deep/strictと配布設定の確認もPASS。
- 同bundleの実WebKit16 checksがPASS。opaque frameの親DOM/localStorage拒否、外部通信・file拒否、子frameからSwiftへの直接接続拒否、collection CRUD、競合/別collection/パス拒否、別storeからのreadback、無効化後のwrite拒否。
- 同bundleで、実Astraによる水やり画面のフォーム入力・編集・削除確認・競合後の入力維持と再読込・幅320px・provider登録・runtime再生成後のreadback・データを保持した削除を確認。実生成された「置き場所」追加版の導入では、変更前record IDと値を保持し、新項目をUIから保存できた。
- 標準SwiftUIを使う隔離検証アプリをCUAで操作。プレビュー内の追加/編集/検索、導入後に試し入力が混ざらないこと、導入後の保存、作成途中の履歴からの復元、復元後の記録保持を確認。保存ファイルからも1件のタイトル一致、4 checkpoint、試し入力の整理をreadback。検証用ウィンドウとCLIを終了した。
- 実Astra Mediumで本管理（標準画面）、水やり（HTML）、作業開始（タイマー+付箋）の3種類と、水やりへの任意項目追加を生成。全package/staging checks成功。タイマー+付箋は実生成と宣言/承認契約を確認し、生成ツールから実タイマー・付箋への書き込みは実施していない。Host側の実行/拒否/readbackは既存Broker検証がPASS。
- `verify_pocket_contracts.py`: v1の72 fixtures、`verify_pocket_tools_contracts.py`: v2の46 schema/negative/v1拒否、`verify_voice_foundation.py`: 42契約がPASS。

## 検証で見つけて修正した点

WebKitが受け付けない正規表現の選択表記を、schemeごとの遮断ルールへ修正。v1 restoreで保存先を移動する不整合はv2だけへ限定した。v2バックアップが1 MiBで拒否される問題を、data payloadの許可上限と整合させた。履歴日時はUTC RFC3339へ統一し、失敗したTrash操作を繰り返しても新しい履歴が増えない順序へ変更した。

実モデルによるタイマー+付箋の最初の生成は、旧runtimeのtoday-focus専用scope条件により失敗した。v1の制約は維持し、v2では有効なツール用namespaceを許可するように修正。Hostのnamespace長もstableKey契約に合わせ、scopeの欠落と別namespaceへの書き込みは拒否する。修正後の実生成は成功した。

`build_and_run.sh --build-only`が動作中の通常アプリを停止する既存挙動を修正し、ローカルビルド時の不要な停止を防いだ。旧631 bundleをdist/previousへ保持してから632を作成した。

## 保存上限と範囲

checkpointはツールごと20件、100 MiB以内。runtimeに残す現在と直前の定義も容量へ算入し、古いruntimeコピーはゴミ箱へ移す。過去のcheckpointは新しい版として復元できる。データ本体、移行backup、export、ゴミ箱はこの上限に含めない。削除/復元時も元データを保持する。

今回の承認範囲でローカル変更・検証・署名まで追加確認なしで実施した。Git commit/push/PR、公証、GitHub Release・feed、インストール済みアプリの置き換えは行っていない。Windowsはv1 runtimeがv2を拒否する互換境界を維持し、Windows実装・実機検証は未実施。OS全体の電源断試験や、任意の全生成物が動くことの保証は今回の検証範囲に含まない。

## 成果物と別経路の確認

- `dist/HoverPocket.app`: 0.1.0 build632、Developer ID署名済み・未公証・未公開。
- `progress/evidence/2026-09-06-pocket-tools-platform/packaged-verification.json`: 署名付き実行ファイルのhash、build、9分類の終了結果。
- 同ディレクトリの個別ログ、実生成HTML画面のPNG、native UI保存readback、変更ソースのhash一覧。
- `contracts/pocket/v2/fixtures/`: 実生成された本管理、水やり、置き場所追加版、作業開始の定義。ユーザーデータを含まない。
