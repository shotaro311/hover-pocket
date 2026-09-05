# 音声による既存機能の詳細操作

## 依頼と範囲

個人用ツール生成とToday Focusの検討は保留し、採用済みのタイマー・付箋・予定・メディア・クリップボード操作を実装する。作業branchは`codex/voice-personal-operations`。630公開ソースを含むworktreeを使用し、元のmainとAI-native final-integrationの未コミット作業は変更していない。

## 実装

- 17個の操作定義を追加し、Voice公開schemaとBroker入力検証の正本を共通化。既存6操作に確認待ち取消を加え、Calendar許可ありでは24個のtoolを公開する。
- 同一会話で実際に一覧/取得/作成した対象IDだけを参照し、同名は候補一覧を返す。古い内容のまま編集しないよう、Hostが最新revisionを読み、確認と実行へ結び付ける。
- タイマーの一覧/残り時間、停止中の残り時間、相対増減/絶対設定、名前、一時停止/再開、キャンセル。無効な残り時間では名前も変更しない。
- 付箋の検索/一覧/全文/編集/削除。段落と未指定項目を保持し、既存IDを更新する。削除は既存Undoに対応し、確認OFFでもstrong-per-call確認が必要。
- メディアの曲名/再生状態と再生/一時停止/次/前。停止済みへの一時停止はtoggleを送らない。既存adapterに完全停止はないため、一時停止として扱う。
- Calendar期間検索/最新詳細/指定項目のPATCH/削除。If-MatchとGET readback、終日の排他的終了日、繰り返しのタイムゾーン保持、対象1回とシリーズID、参加者への更新通知の確認。実際のCalendar書き込みテストは行わない。
- 明示したコピー内容の取得を既存の付箋作成/予定作成へ接続。内容は非信頼データとして扱い、長文は省略を明示する。本文を監査へ保存しない。
- 確認待ちのみの取消は会話を継続する。実行済み操作を取り消せたと表示しない。長い確認内容はスクロール可能にした。

## 互換性

既存のTimer/Sticky保存形式、既存Capability v1、Today Focus、生成機能の無効化状態は変更しない。新操作は追加契約`contracts/personal-tools/v1/`に保存し、生成出力とCIでbyte比較する。Windowsは新handler未実装であり未対応として扱う。アプリを旧版へ戻しても、Google上で実行済みの変更は巻き戻らない。

## 検証

- Debug warnings-as-errors: PASS。
- 新規41 assertions: PASS。隔離した保存先とfake Calendar/Mediaで、対象隔離、同名候補、保存後再読込、確認中変更、削除拒否/Undo/再送、確認OFFでも削除確認、タイマー相対/絶対編集、無効入力の無変更、メディア冪等操作、Calendar権限取消、未実行操作取消、終日/タイムゾーン/省略項目/readback mismatchを検証した。
- 既存Voice Foundation、Capability、Broker、Timer、Voice静的検証、Voice E2E isolation、Panel layout: PASS。
- 共有Pocket contract: 15 schema / 72 fixture、72一致。
- 最終Release warnings-as-errors: PASS。署名付きpreviewは42 assertions（同梱resourceの参照検証を含む）とBroker検証がPASS。
- Googleから実予定のresource/ETagをGETし、値を出力せず取得成功を確認。書き込みなし。
- previewのstrict codesign、Google client/callback設定、location entitlementはPASS。previewは`dist/personal-tools-preview/HoverPocket.app`、build 631。公証/公開は未実施。
- 検証中にpreviewのSparkle探索pathとSwiftPM resourceの開発フォルダ依存を検出。既存と同じFrameworks rpathへ修正し、resource bundleをContents/Resourcesへ同梱して、通常起動と既存Broker/Pocket App検証が同じlocatorを使うようにした。最終署名後のBroker検証はこの同梱bundleを使用した。
- 根拠: `progress/evidence/2026-09-05-personal-operations/receipt.json`と同ディレクトリの検証ログ。
- 追加の承認質問なしで、採用済み範囲のコード変更、隔離テスト、実Calendar read、専用previewの署名、ローカルcommitまで実施した。

## 未検証・配信境界

実マイクでの全操作、実Google予定の編集/削除/参加者通知、実メディア再生元の全種類は未検証。Windowsへの実装・配信、本番appcast/GitHub Releasesの変更、インストール済み630の置換は行わない。
