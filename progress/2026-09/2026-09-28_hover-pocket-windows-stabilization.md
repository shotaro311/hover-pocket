# Windowsの基本機能確認とローカル安定化

## 方針

ユーザーが選んだ「ライブラリ開発に進める安定版」を目標とし、基本機能を総点検した。Windows公開版 `win-v0.2.8`（ece89a6）を基準に専用worktreeを作成。元の `C:\Users\shotaro\code\shared\hover-pocket` のdirty変更を保持した。

## 実装

- PanelWindowのWebView2送信をUIスレッドへ移し、終了済みのパネルを参照しないようにした。修正前はバックグラウンドイベントの実機テストでInvalidOperationExceptionを再現、修正後はJS側の受信を確認。
- TimerBridgeHandlersが最後の接続先だけを保持する実装を廃止し、PanelBridgeControllerの既存の通知配信処理へ統合。追加画面の接続中・解除後とも、パネルのtimer.alert受信と再表示を確認。
- publish_release.ps1をGUI verifierの終了待ち・終了コード判定に変更。不一致バージョンで実verifierがexit=1となるテストでは梱包前に停止し、release assetを生成しなかった。
- ReleaseConfigVerifierはInformationalVersionからbuild metadataを除いた製品バージョンを照合。
- 実装コミット: `fcaa509935110cf57da3ffab5ab26164dd867fd5`。ローカル候補: `0.2.9-local.2`。push・公開は実施していない。

## 検証

- .NET 10.0.301、Releaseビルド成功、警告0・エラー0。
- 最終パッケージ内のexeで `ui-model / settings / sticky / clipboard / controls / calc / timer / calendar / updater / display / shell / ui / calendar-live / release-config` 成功。
- 現在の画面は5120×2160、DPI 144、1台。Shellでは25回の開閉・位置・外側で閉じる・自己修復・ウィンドウ再生成・復旧処理を確認。
- 既存認証でGoogle Calendarの読み取り成功。予定の変更なし。
- Velopackの実更新後、installed ProductVersionとARPが0.2.9-local.2、installed DLLのSHA-256が検証済みpublish DLLと一致。通常起動し、既存インストール先で常駐。
- 設定のStartWithWindows=trueに対してHKCU Runの登録がなかったため、既存設定に合わせて現在のinstalled exeを登録し、読み戻し一致を確認。再ログインは未実施。
- 更新直後は既存データ20ファイルのSHA-256一致。通常起動後に画像1件を自動取得しhistory.jsonが変化したが、既存43項目は削除0・変更0。他の既存データに欠損なし。
- 旧0.2.7パッケージと既存データはチャットのwork/hoverpocket-validation/rollbackに保管。復元操作は未検証。

## 未確認と次の作業

実スリープ・ロック復帰、トレイ手操作での終了・再起動、再ログイン、自分の耳での通知音、他アプリへの実画像ドラッグ・再コピー、再生中メディア・実輝度変更が未確認。自動検証の成功だけで安定版の受入完了とはしない。Computer Useでは常駐パネルを対象として取得できなかった。ユーザーへ実操作の確認可否を質問済み。

詳細結果と証拠は `C:\Users\shotaro\Documents\Codex\2026-09-27\codex-win-desktop-bridge\outputs\hoverpocket-windows-stabilization-result.md` と同チャットの `work/hoverpocket-validation/` に保存。要件の正本追補は `docs/requirement/windows-stabilization-20260928.md`。
