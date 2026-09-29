# Codex App OS 実装・検証

状態: macOSローカル実装と自動検証を完了。実音声の総合受入は未完了。2026-09-07の実装承認に基づくmacOSローカル変更。公開・既存アプリの置換は行っていない。

## 実装

- 既存の音声・Broker toolを保持して共通操作を追加。Hostが現行provider・package・schema・履歴を返し、画面表示、背景生成、確認、導入、記録、データ保持のアンインストール、復元を既存サービスへ接続する。
- job/承認はセッション内。確認は対象digest/revision、会話、要求後の利用者発話、期限、一回限りのIDへ紐付ける。重複callを再実行しない。
- 標準provider登録と同梱packageディレクトリを保護の正本にする。将来追加される同梱packageもHost操作から削除・置換を拒否する。
- カレンダー・collectionの選択と未保存入力を共有。音声で変更した記録を表示へ反映し、編集中の競合変更を拒否する。
- 生成物を隔離WebKitで検査し、固定エラーコードを最大3ターン内で修正へ戻す。標準native表示のクリック受入と実音声は別に残す。
- 音声設定に実接続先が対応する声の選択を追加。V3用のv1群だけを表示し、次回接続へ適用。

## 確認済み

- 最終ソースでswift buildと署名付きローカルbuild637を作成。bundle ID/build/実行ファイルhash/署名を別途readback。
- 最終bundleのHost隔離検証43項目。生成受付直後の取消抜けを修正。workflowの音声承認からBroker実行とreadback、承認期限、画面の共有状態、保持アンインストールと復元、標準機能保護を検証。テストfixtureのtimer readback handler不足も補完してPASS。
- 最終bundleで既存platform78項目、Broker、personal-tools42項目、voice-foundation、pocket-app、panel-layout128項目、HTML bridge20項目、Codex app-server検証がPASS。共有v1契約72/v2契約46/voice静的42もPASS。共有modelへの変更に合わせ、再表示時のquery取得を保持する検証へ更新。
- 実Astraの読書管理(collection)と水やり記録(HTML)で新しいpreview検証を通過。最終bundleから同じ実生成artifactを再検証しPASS。HTMLは幅520/300・最大文字と代表入力/保存/検索/取消、nativeは実描画と別経路の保存確認。生成モデル/Mediumは既存設定のまま。
- 実app-serverのtool経路と、実ChatGPTモデルが共通catalogを一度発見・実行する検証がPASS。ephemeral会話と子プロセスの終了を確認。
- 実接続先0.153.4でMapleを指定し、9候補・WebRTC接続・プロセス終了を確認。物理マイクでの発話や声の聞き比べは未検証。
- 別IDの隔離アプリで最小パネル・最大文字の水やり記録の表示を観測。画像は progress/evidence/2026-09-07-codex-app-os/small-panel-large-text.png。Computer Useの操作時に状態変更/timeoutが発生したため、この画像だけを入力操作の成功根拠にはしない。

## 未検証・完了範囲

物理マイクでの連続対話（カレンダー表示一致、生成中の別質問、完了通知、音声承認）と声の聞き比べ、native入力の実クリック受入は未検証。上記の自動検証を、実音声の総合受入完了とは扱わない。Windowsは対象外。

ユーザーが承認したローカル実装と非破壊検証は追加確認なしで実施した。既存/Applicationsアプリは稼働したまま、隔離UI検証アプリだけを終了。コミット・公開・インストール済みアプリの置換は行っていない。検証根拠は [証拠ディレクトリ](../evidence/2026-09-07-codex-app-os/)、最終build readbackは同ディレクトリのbuild-readback.json。
