# Googleログインと天気の現在地取得の修正

## 原因と一次証拠

- Gmailの2026-07-16 OAuth審査承認メールを読み取り専用で確認した。HoverPocket projectに対するcalendar.events scopeが承認済み。アカウントのアクセス許可通知とは別の審査承認メールである。
- 本番629はGIDClientID / callback URL schemeが欠落。旧168と元worktreeのGit管理外Google設定は一致した。AI-native final integration worktreeに.env.localがなく、設定なしで梱包・公証・公開できていたことが原因。
- macOS locationdの2026-09-05ログに、Hardened Runtimeのアプリにlocation entitlementがなく、許可ダイアログを表示しなかったことが記録されていた。座標や個人情報は記録しない。

## 修正

- 既存Googleクライアント設定だけをGit管理外の0600 .env.localへ引き継いだ。client secret、token、他の環境変数はコピーしていない。新しいGoogleクライアント作成や再審査は行わない。
- 署名にcom.apple.security.personal-information.locationを追加した。位置情報は現在地ボタンの明示操作時だけ要求する。
- 取得は20秒で期限切れ、キャンセル、拒否・無効・空結果の案内を追加。要求ごとのmanagerで遅延callbackが新しい選択を上書きせず、成功・失敗・キャンセル時に停止してdelegateを外す。
- Settings表示時に既存Google資格情報の復元を呼び、カレンダーを開くまで「確認中」が残る問題も修正。
- ZIP作成時と公開前の再展開ZIPに対して、Google client / callback scheme、署名済みlocation entitlement、利用目的を検証。設定欠落の629は新verifierで拒否された。
- 既存macOS CIへ現在地の決定論的検証と配布設定5テストを追加した。

## 検証

- Debug warnings-as-errors、現在地8シナリオ、配布設定5テスト、Panel 128 cases、Voice Foundation、shell syntax、git diff --checkはPASS。
- Release build、公証、実アプリGoogle / 位置情報の受入、本番修正版の公開readbackは実行中。

## 仕様根拠

- Google: https://developers.google.com/identity/sign-in/ios/start-integrating
- Apple: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.location
