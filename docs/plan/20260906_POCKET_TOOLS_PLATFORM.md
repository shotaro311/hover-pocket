# 個人用ツール基盤の実装設計

状態: ユーザーが変更履歴・保存上限を含む設計の採用と実装を依頼した。既存データを保つ新形式、標準UI+独自HTML、Astra設定、履歴管理を実装する。

## 目的と範囲

誰でも自然文で思いついたHoverPocket専用ツールを作成・試用・導入・編集・削除できる。ファイル置き場とToday Focusは固定の実装要件としない。Macを先行実装し、共通契約はOS別の実装可否を明示する。Windows対応・本番配信は別の受入とする。

採用アーキテクチャ: ツール定義から標準UIを表示し、必要な場合にHTML/CSS/JavaScriptの独自画面を追加する。MacのShellはSwiftUI/AppKitを保持する。標準/独自UIは同じ保存・権限・既存Capability Brokerを使う。AIだけが直接書く別データは作らない。

## 現在の実装との差

- v1 manifestはdeclarative surfaceのみ許可する。
- v1 stateはstring/integer/number/boolean/nullのpropertyのみ。汎用レコード一覧を保存できない。
- staging testはToday Focus固有のcase群で、自由なツールの受入検証には不足する。
- Codex生成adapterの生成・activationは無効であり、旧モデルcatalogもAstraではない。
- 導入/更新/無効化/削除/復元、データを分けた保存、Brokerと実行結果のreadbackは既存基盤を利用する。

## 提案するデータ契約

正本はバージョン別のJSON Schemaと、それを検証するHost実装。作成ガイドには正本への参照と動く例を置き、実装から取得する利用可能機能と結合する。作成中はHost契約バージョンを固定する。

代表的なbefore:

```json
{"apiVersion":"hoverpocket.app/v1","state":{"schema":"data.schema.json","store":"user-data://local.example.tool"},"surfaces":[{"id":"main","kind":"declarative","source":"surfaces/main.surface.json"}]}
```

上記は現行manifestから関係フィールドだけを抜いた例。保存データは例えば`{"selectedItem":null}`のような単純な値の集合である。

代表的なafter（提案、v1へこのまま追加しない）:

```json
{"apiVersion":"hoverpocket.app/v2","state":{"schema":"data.schema.json","store":"user-data://local.example.tool"},"collections":{"items":{"schema":"collections/items.schema.json"}},"surfaces":[{"id":"main","kind":"collection","source":"surfaces/main.surface.json"},{"id":"custom","kind":"html","source":"views/main.html"}]}
```

レコード保存の例:

```json
{"formatVersion":1,"schemaVersion":1,"revision":3,"records":[{"id":"item-1","fields":{"title":"Sample","done":false}}]}
```

- ツール定義とユーザーデータを分離。レコードはHost管理のcollectionデータだけを正本とする。表示用の計算結果を重複保存しない。
- collectionはツール単位に分離し、実パスを生成コードへ渡さない。IDはHostが生成し、更新で保持する。例の`item-1`は説明用。
- revisionはHostだけが増やす非負整数。更新は期待revisionを指定し、競合時は上書きせず再読込する。永続化は一時ファイルから原子的に置換し、メモリとdiskをreadbackする。
- 初期fieldは文字列/真偽値/有限数/日付/選択肢を対象にし、単純な関連参照を必要に応じて同じツール内で扱う。nullは明示許可時のみ、未指定と空文字を区別。日付はYYYY-MM-DD、時刻を扱う型はUTCのRFC3339。単位/通貨は該当field定義に明記する。
- JSからの保存、標準UIからの保存、AI操作は同じHost検証を通す。collection CRUDと利用可能な既存workflowを接続し、追加権限は導入/更新時に表示する。

## 互換性・移行・ロールバック

- v1定義/データはそのまま読む。既存ツールを自動でv2へ変換しない。v2は対応Hostだけで導入可能とし、未対応OSでは理由を表示する。
- 表示だけの変更は保存データを触らない。
- schema変更は明示的な移行計画を作り、旧データのコピーに適用して検証。定義とデータの整合を確認してから切り替える。元snapshotを保持し、失敗時は旧定義・旧データを維持する。
- 更新後に新たに入力したデータは、旧snapshotへ戻すだけでは失われるため、無条件の自動巻き戻しをしない。対象データを退避し、復元時点と失われる変更を表示する。
- ツール削除では保存データ保持を既定とし、データ削除は別の明示操作としてゴミ箱/復元可能な退避へ移す。
- 外部サービスで実行済みの変更はツールsnapshotの復元では戻らない。

## 表示と実行

標準のボタン・文字・余白・最小操作領域は共通デザイン定義を参照。独自HTMLにも同じテーマを供給する。パネル寸法/文字拡大/overflow/keyboard操作を検証する。

独自画面は専用のWKWebViewで実行し、通常サイトへの遷移・外部通信・任意ファイルアクセスを許可しない。Host bridgeで表示中のツールidentityと権限を固定し、生成画面が任意のツールIDや実パスを指定しても操作できない構成とする。Shell、Voice、承認画面は生成HTMLの外側でHostが描く。メモリ/CPU/終了時cleanupとMac/Windows間の差は実測する。

## Codex生成と作成ガイド

開発作業はGPT-6 Astra / Highをユーザーが指定した。アプリ内の生成はGPT-6 Astraを明示し、推論の既定はMediumとする。設定画面で推論の強さを変更可能にし、利用者が変更済みの値を保持する。選択肢は利用中の実モデル一覧が返す対応値に限定し、保存値が未対応になった場合は再選択を案内する。生成開始時に設定をsnapshotし、途中の設定変更は次の生成から反映する。利用不能時は別モデルへ自動代替しない。現行の実モデル一覧/対応推論値で確認する。アプリ内の既存ChatGPT認証を使うapp-server経路を候補とし、既存の隔離・認証保護を弱めて旧falseフラグだけを解除しない。

最初に基本ガイドと利用可能機能を取得し、UI/保存/API/更新/検証の各トピックを必要に応じて取得できるようにする。Hostが提供する仕様とユーザー依頼/既存データを区別する。生成→構文/型/契約検証→動くpreview→限定回数の修正→明示導入を行う。通常クリックやドラッグはAI推論なしで動かす。

## 受入検証

1. 固定Today Focusに依存しない記録管理・既存機能の組み合わせ・独自表示の複数要求で実モデル生成。
2. 生成物が検証を通り、実previewで入力/表示/操作できる。
3. 導入後は通常パネルに登録され、再起動後もデータが一致する。
4. 会話で表示/項目を変更し、既存データ保持と旧版復元を確認する。
5. 無効なデータ、別ツール参照、権限不足、破損、通信失敗、取消、表示崩れを検証する。
6. 公開前には署名付きappで生成/導入/編集/削除を実機確認する。検証用fixtureだけを実モデルE2Eと扱わない。

## 作成途中の履歴と保存上限（採用）

ユーザーは導入済みの版だけでなく、開発途中に「さっきの方がよかった」と戻せることと、履歴が無制限に増えないことの検討を依頼した。

- AIの修正1回が終わりpreviewを作れる段階でツール定義のcheckpointを残す。クリックや入力1文字ごとは保存しない。無変更は新履歴を作らず、失敗した候補が直前の動く候補を置換しない。
- 「作成中の変更履歴」と「導入した版」を同じツールの履歴で識別できるようにする。日時、変更内容、検証状態を表示し、コードを読まずに選べるようにする。
- 推奨する暫定値はツールごとに自動履歴20件、合計100 MiB以内。期間経過だけで最近の履歴を消さない。使用中の版と直前の動作確認済み版は自動整理対象から除外する。保護対象だけで容量を超える場合は無断削除せず、追加履歴の保存を止めて整理を案内する。
- 古い自動履歴はOSのゴミ箱へ退避する。これはアプリ管理領域の上限であり、ゴミ箱を含む端末総容量が自動的に減る保証ではない。保存データ本体、データ移行backup、exportはこの自動整理対象に含めない。
- 復元は新しい履歴として記録し、復元前の状態へも戻れるようにする。通常は定義/UIだけを戻し、現時点のユーザーデータを保持する。schemaが合わない場合はデータ移行・復元の別確認へ進む。
- 素材は可能なら同一内容を共有し、履歴数ぶん大きな素材を丸ごと複製しない。容量計算と参照中素材の保護を検証する。

参考調査（MulmoClaude公開ソース94360b2）:

- Wikiは有意な保存時のsnapshot、履歴一覧、差分、復元を実装。復元自体も新snapshotになる。
- Wikiの保持は直近100件 OR 180日以内であり、両方から外れた時のみ削除する。厳密な件数/容量上限ではない。
- Collections削除時に定義とローカルデータを退避し、復元手順を保存する実装もある。
- 今回確認したCollections資料・入出力・削除経路では、生成ツール全体の作成途中の版を一覧して戻す統合UIは確認できなかった。Wikiの履歴をCollections全体にもあると推定しない。
- 実アプリ操作やテスト実行は行っておらず、公開ソースによる確認。

参照:
- https://github.com/receptron/mulmoclaude/blob/94360b2312098479c2957a2fe80074ccc151e878/server/workspace/wiki-pages/snapshot.ts
- https://github.com/receptron/mulmoclaude/blob/94360b2312098479c2957a2fe80074ccc151e878/src/plugins/wiki/history/HistoryDetail.vue
- https://github.com/receptron/mulmoclaude/blob/94360b2312098479c2957a2fe80074ccc151e878/packages/core/src/collection/server/delete.ts

## 参照

- https://github.com/receptron/mulmoclaude/blob/main/MANIFEST.md
- https://github.com/receptron/mulmoclaude/blob/main/docs/papers/collections-architecture.md
- https://github.com/receptron/mulmoclaude/blob/94360b2312098479c2957a2fe80074ccc151e878/packages/core/src/collection/server/schemaDocs.ts
- https://developer.apple.com/documentation/webkit/wkwebview/
- https://developers.openai.com/codex/app-server
