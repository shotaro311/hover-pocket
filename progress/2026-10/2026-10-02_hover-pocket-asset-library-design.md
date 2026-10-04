# 2026-10-02 素材ライブラリの設計

## 依頼と変更

Eagleを介さない素材ライブラリ、配布アプリを誰でも利用できる前提、Eagleの軽快さとUI/UXを取り入れる要望を受け、[設計案](../../docs/plan/20261002_ASSET_LIBRARY_DESIGN.md)を作成した。[要件定義](../../docs/requirement/requirements.md)と[進捗入口](../progress.md)から参照できる。

原本・ローカルSQLite・サムネイルキャッシュの構成、UIを止めない取り込み、段階的プレビュー、可視範囲の描画、ポケットと整理用ウィンドウの役割、分類・キーボード操作、障害復旧と性能の受入条件を記録した。数値は初期目標であり、現在の測定結果ではない。

## 根拠と判断

- Eagle公式の[Eagle 4](https://en.eagle.cool/blog/post/eagle4)、[Build2](https://en.eagle.cool/blog/post/eagle4-build2)、[整理機能](https://en.eagle.cool/support/desktop/organize)を参照。プレビューが完全読み込みを待たず表示される振る舞い等を確認した。Eagleの内部DBや処理構成は不明であり、SQLite・キャッシュ・非同期処理はHoverPocket側の設計判断。
- SQLiteの[用途](https://www.sqlite.org/whentouse.html)と[WALの制約](https://www.sqlite.org/wal.html)を確認。稼働中のDBを端末間で直接共有する方式を避ける。
- 現行Windowsの `ClipboardHistoryStore.cs` は30件のテキスト・20件の画像をJSON保存する。永続的な素材管理のために上限だけを増やす方式を避け、短期履歴と素材ライブラリを分離した。
- 既存のAI用機能台帳は維持。素材ID・Schema・移行・互換性検証を実装段階で同時に定義する。Dropbox同期は前の会話の候補として記録し、ローカル機能の必須条件にはしない。

## 検証と未完了

`git diff --check`は通過。新規文書も含めて末尾空白・競合マーカーを検査し、新しい相対リンク6件の参照先を確認した。変更は設計・要件・進捗入口・日別ログの4文書のみ。実行コードを変えていないためビルドとアプリ検査は今回の対象外。素材ライブラリの実装、性能測定、各OSの実機受入、同期とiPhone対応は未実施。

Downloads内の既存独立cloneで文書のみを変更。起動アプリ、ユーザー設定、元の作業中checkoutには変更を加えていない。
