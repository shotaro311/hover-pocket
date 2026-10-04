# 素材ライブラリの共通契約

検索はNFKC正規化後に、同梱の`case-fold.json`（Unicode 15.1.0、Pythonの標準Unicode定義から生成した1,530写像）で言語に依存しないfull case foldを行う。OSごとの大小文字変換へ委ねず、Mac側も同じ表を使う。ASCII、全角、ギリシャ語の終止シグマ、ドイツ語ß、トルコ語のI等を共通fixtureで検証する。

`001-initial.sql`はDB版1の正本で、WindowsのAssetStoreが埋め込みリソースから適用する。`PRAGMA user_version`が新しい場合は書き込みを停止する。v0はDB未作成、v1は初期スキーマで、既存の他のプロバイダーのデータを移行しない。

`manifest.schema.json`は完全バックアップの公開契約。原本は`originals/<UUID>.<extension>`、拡張子なしの場合は`originals/<UUID>`。日時はUTC、サイズはバイト。タグ・フォルダはUUIDの集合。名前の変更は原本のパス・ID・拡張子を変更しない。元の絶対パス・取得URL・資格情報を含めない。

保存検索の`filter.version`は1。省略された既存fixtureは1として読む。`folderIds`と`tagIds`は各集合内OR、異なる集合間AND。単一の`folderId`/`tagId`も集合に合流する。日付の`createdAfter`はUTCの含む境界、`createdBefore`は含まない境界で、画面が端末の現地日付から翌日境界を計算する。`excludedPending`はエクスポートで除外された未確定の取り込み数で、原本数に含めない。

`fixtures/v1`は生成した原本と固定ハッシュを含む、両OS用の復元fixture。名前・分類・お気に入り・ゴミ箱・由来フラグ・保存検索の意味を復元して検証する。WindowsのCoreテストは自動生成fixtureの保存/復元とこのfixtureの読み込みを別に実行する。

今後のDB変更は適用前のSQLite backup APIによるスナップショット、対応migration、fixture、旧版の書き込み拒否検証を同時に追加する。DBスナップショットは原本を含むバックアップとは別。未知の版を旧版へ自動変換しない。
