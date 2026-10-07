# Asset library sync v1

各端末のDBを独立させ、Syncthingは専用フォルダの `blobs/<sha256>` と `events/<deviceId>/<revision>.json` だけを運ぶ。Eagleのtransport/library/stateは使わない。同期は初期オフ、ユーザーが専用フォルダを選んで有効化する。3秒ごと、非重複・バックグラウンド実行。受信後は素材画面を更新する。

## Wire contract

ルートに `hoverpocket-sync.json` = `{ "version":1, "groupId":"lowercase-uuid" }`。参加端末はこのgroupIdをローカル設定へ固定し、markerの欠落/変更は停止する。新しい共有は一方だけが作り、他方は到着したmarkerへ参加する。

イベントはUTF-8 JSON、4 MiB以下。UUIDは小文字のD形式。`version:1`, `groupId`, `revision` (新規UUID), `deviceId` (ライブラリごとに永続UUID), `entityType` (`asset`/`folder`/`tag`), `entityId` (assetはsha256、分類はUUID), `parents` (同じentityの直前revisionのUUID配列), `deleted` (bool), `asset` (既存manifestのAssetまたはnull), `category` (既存Categoryまたはnull)。nullも明示。assetのentityIdはasset.sha256と一致。folder/tagのentityIdはcategory.idと一致。配列の重複を拒否。分類の親はfolderのみ。既存のmanifest validationと名前/参照/循環検査を通す。event pathのdeviceId/revisionとbodyも一致させる。時刻で勝者を選ばない。

新しい原本はsha256をキーに内容を検証して一時ファイルから確定する。イベントは原本確定後に追加し、既存ファイルを上書きしない。受信順が逆でもparents/原本/分類の到着まで保留する。path traversal、symlink/reparse point、別group、未知version、サイズ/ハッシュ不一致は適用しない。生JSONの順序やエスケープはOSに依存してよい。revisionの一致をJSONのバイト同一性と混同しない。

## Local state and conflict

DBへイベントと現在revision・現在ローカル値のsnapshotを保持する。ローカル変更の検出・event/outbox登録を受信より先に、同じwriter lock内で行う。送信失敗時はDB内のeventを再送する。受信のDB変更とhead/snapshot更新は同じtransactionにする。ファイル確定後の中断は同じID/shaで再開し重複を作らない。受信による変更を新しいローカル変更として再送しない。

先祖revisionは無視、子孫は適用、別枝は両方を残し競合表示する。現在の端末の内容を保持し、設定画面で「この端末の内容」または受信した版を選ぶ。解決eventは現在headと競合headsをparentsに含める。参照不足は保留し、現在headが削除済みの分類への古い所属は除外し、削除済みの親はルートへ戻す（原本が遅れて届く再生でも削除済みフォルダ待ちで停止しない）。名前衝突/循環は競合として保持して編集後の再試行を案内する。フォルダ同名衝突は勝手に統合しない。

同期対象は原本・名前・お気に入り・フォルダ/タグと所属・ゴミ箱/復元。保存検索/キャッシュ/設定/チャット履歴は対象外。assetはSHAで同一視し、既存のローカルIDを保持、初回受信では送信元IDを使う。拡張子/作成日時は既存原本がある端末で保持し、internetOriginはORして保護情報を弱めない。ローカルsnapshotは実際の適用後の値を保存する。

asset.deletedはローカルでゴミ箱を空にした記録で、相手ではゴミ箱移動まで。物理削除は端末間に伝播しない。transportの原本/履歴は自動削除しない。分類deletedは所属解除と子フォルダをルートへ戻す。通常のtrashed=false更新で復元できる。同期中のDBスナップショット復元は停止を案内し、古い同期headの巻戻りを起こさない。旧アプリは追加syncテーブルを無視して基本ライブラリを読める。

## Acceptance

両OSで共通fixtureの読み込み/拒否。追加/同一sha重複/分類/日本語名称/お気に入り/ゴミ箱/復元、切断中編集→再接続、逆順配送、繰り返し受信、停止再開、同時編集→保持→両方の解決選択、破損原本/参照不足/別group/リンクを検査。実Syncthing専用共有でMac→Windows→Macを往復し、DBと原本SHAを独立readbackする。既存Eagle共有設定とファイルは不変を確認。ローカルテストと実機往復を区別する。
