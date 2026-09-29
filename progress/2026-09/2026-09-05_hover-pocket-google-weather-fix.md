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
- Release warnings-as-errors、配布binaryの現在地8シナリオ、Panel、Voice Foundation、実Weather API / global searchはPASS。
- `0.1.0 (630)`をDeveloper ID署名・公証。submission `573ac32d-af78-4ef6-a43e-381261388af3`はAccepted。
- 実Google Calendar verifierは再ログインなしで成功（資格情報や予定本文をログへ記録しない）。Settingsも接続済み。
- 実CoreLocation許可ダイアログが表示され、許可後の再試行で「現在地」が反映された。待機中に期限切れとなるケースも確認し、案内後に再試行できた。正確な座標は証拠ファイルへ保存しない。
- 本番公開: https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-630 （2026-09-05 18:44 JST）。source/tagは`3d9470f35718c0d645fa3cf5c8afe0db36cf8e40`。
- 公開stable ZIPとversioned ZIPを再download。元ZIPとbyte一致、SHA-256 `a8ad926409d1686159e2f72397ade0623b18ff47247e7a057473cb180a8be2d6`、7,655,620 bytes。公開appcast build630 / length / Sparkle Ed25519、展開app Google callback設定 / location entitlement / strict codesign / stapler / GatekeeperはPASS。
- アプリ内Sparkleで`/Applications/HoverPocket.app`を629から630へ更新・再起動した。PID 60220、Google接続済み、現在地設定保持、アップデートなしをUI readback。インストール済みappのGoogle設定 / location entitlement / 署名 / stapleもPASS。
- Windowsはwin-v0.2.7・8月12日公開のまま。Windowsの再公開は行っていない。
- final-integration worktreeへ同じsource修正をapplyし、既存の未コミット変更を保持した。Google native設定だけをGit管理外0600 .env.localへ復元した。
- Google新規ログイン、審査の再申請、カレンダーへの書き込みは行っていない。

## 仕様根拠

- Google: https://developers.google.com/identity/sign-in/ios/start-integrating
- Apple: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.location
