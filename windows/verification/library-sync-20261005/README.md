# Windows同期の検証記録

- core-checks.log: 共通fixture15件を含む102判定。
- assets-regression.log: 既存保存・復旧120検査。
- release-build.log / ui-check.log / release-ui-check.log: ビルドと実WebView2設定操作。
- ui-model.log / voice-regression.log: 既存機能の回帰。
- syncthing-setup.json: 専用共有追加、Eagle共有とdevice設定の操作前後一致。
- mac-to-windows.json / windows-to-mac.json / roundtrip-check.json: 生成した素材だけを使った実転送のDB・原本ハッシュ読戻し。
- runtime-preservation.json: 実ユーザーライブラリの同期オフと稼働開発版の確認。
- settings-sync.png: 隔離した設定画面の表示確認。

実Syncthingの共有IDはhoverpocket-library-sync-verify-20261005。Mac側の最終受信結果はMac担当が独立して照合済み。成果物は開発候補で、本番更新の配信証跡ではない。

Syncthingへの共有追加は[公式の設定API](https://docs.syncthing.net/rest/config.html)のfolder単位POSTを使用し、既存の設定全体を置換していない。
