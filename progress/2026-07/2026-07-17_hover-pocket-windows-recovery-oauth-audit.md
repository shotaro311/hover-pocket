---
project_slug: hover-pocket
date: 2026-07-17
platform: windows
status: implemented-and-verified-with-gui-caveat
---

# Windows hover self-recovery and Google OAuth audit

## Scope and preservation

- 正本clone: `C:\Users\shotaro\code\shared\hover-pocket`
- 作業開始時HEAD: `4a75426aafb937f81d4242831e76dbd2b74a4665`
- 作業開始時からstaged / unstaged / untrackedのユーザー変更が多数存在した。reset、checkout、pull、rebase、commit、push、releaseは行わず、対象ファイルの既存差分へ狭く追記した。
- build / verifierはrepo内bin / objを増やさないため、`C:\Windows\Temp\hover-pocket-final-161f452663434cfabec3b509b815367b`の一時copyで実行した。

## Hover recovery implementation

- 既存の120ms pointer pollingとは独立した2秒health timerを追加した。
- access surfaceとpanelについて、native HWND、WPF/native visibility、必須extended style、期待frameを検査する。
- 修復可能なhidden / style / topmost / placement異常は既存windowへ再適用する。無効HWNDは対象windowだけを再生成する。
- panel再生成時は共有`PanelBridgeController`を維持し、古いWebView dispatcher attachmentだけを解除することでprovider / bridge stateを失わないようにした。
- `WM_DISPLAYCHANGE`、`WM_DPICHANGED`、`SystemEvents.DisplaySettingsChanged`、Power Resume、session unlock / console connect / remote connectから、即時・450ms・1.4秒後の段階的recoveryを予約する。各stageで120ms pollingとhealth timerを再始動する。
- Disposeでpolling / close-delay / health timer、recovery cancellation、SystemEvents、window message hooks、WebView bridge attachmentを解除する。
- close開始時にexpected-visibleを先にfalseへ切り替え、animation中のhealth repairをスキップした。これは実カーソル試験で、close完了前のhealth tickがpanelを再表示し得る競合を検出したためである。

## Verification

- `dotnet build ...\HoverPocket.Shell.csproj --configuration Debug --nologo`: exit 0、warnings 0、errors 0。
- `HoverPocket.Shell.exe --verify shell`: exit 0。`windows=12`、`cycles=25`、`polling_open=true`、`health_repair=true`、`window_recreate=true`、`staged_recovery=true`、`outside_close=true`。
- `HoverPocket.Shell.exe --verify display`: exit 0。実機monitor 1台、2560x1440、96 DPIをreadback。
- `HoverPocket.Shell.exe --verify calendar`: exit 0。OAuth configuration解決、PKCE URL、loopback、Credential Manager一時round-trip、request builder、read-only guardを通過。検証buildの`oauth_embedded_metadata=absent`も確認。
- 通常起動のnative readbackでは上端access surface `168x9`と、一度はpanel `680x488`のopenを確認した。この試験でclose/health競合を検出し修正した。修正後の最終再試行ではpanel open自体をreadbackできず、全画面抑止または通常起動直後のWebView初期化タイミングを分離できなかったため、最終実GUI open/closeは未確定。決定的なpolling-only / outside-close verifierは修正後にexit 0。
- PCのsleep、lock、display設定変更は行っていない。resume/session/display経路はevent購読とfault-injected staged schedulerで検証した。

## OAuth audit

- コードが新規認可で要求するscopeは`calendar.events`と`calendar.calendarlist.readonly`だけである。legacy資格情報の再接続判定では過去の上位scopeも互換として受理するが、新規要求には含めない。
- 認可requestはランダムstate、S256 PKCE、`access_type=offline`、動的`http://127.0.0.1:{port}/`を使用する。callback stateを検証し、refresh tokenとgranted scopesをWindows Credential Managerへ保存する。
- refresh時のscope不足、`invalid_grant`、`invalid_scope`は再接続扱いにし、無効な保存資格情報を削除する。Calendar storeは`needs_reconnect`をUI状態へ反映する。
- csprojはMSBuild propertyを`AssemblyMetadata`へ埋め込み、publish scriptは`HOVERPOCKET_GOOGLE_CLIENT_ID` / `HOVERPOCKET_GOOGLE_CLIENT_SECRET`を値を表示せず渡す。
- 現在のshell環境にWindows用OAuth環境変数はなく、repoの`.env.local`と`%APPDATA%\HoverPocket\oauth.json`も存在しない。
- インストール済み`HoverPocket` 0.2.1の実assemblyはclient ID / client secret metadataともabsent。Credential Managerの本番targetはnot foundで、保存tokenはない。
- GitHub公開`win-v0.2.1`のPortable assetを一時directoryへ取得し、実assemblyをreadbackした。version 0.2.1.0で、client ID / client secret metadataともabsent。インストール済みDLLとはhash不一致で、同じversion番号の別buildだが、どちらもOAuth設定はない。
- Googleの審査はCloud project、consent screen、branding、承認scopeに紐づく。Windows Desktop OAuth clientが承認済みproject `hoverpocket`内にあり、同じbrandと承認済み2 scopeだけを要求する場合は審査結果を利用できる。ただし現行Windows binaryにはclient ID自体がないため同一project判定不能で、現行配布物へは実質適用されていない。
- 新規ログイン、同意、token refresh、予定取得・作成・編集・削除は行っていない。実アカウントE2Eは未確認。

## Remaining risk and next minimum action

- 最終実GUI open/closeを、全画面抑止の影響がないデスクトップ状態で再確認する。
- 次のWindows release作成時に、承認済み`hoverpocket` project内のDesktop client IDをpublishへ設定し、artifact metadataのpresenceとproject-family equalityを値を出さずにreadbackする。
- そのrelease候補で1回だけ実アカウントの同意、calendar list / event read、refresh後再接続状態を確認する。Calendarの書き込みE2Eは別途明示承認後に行う。
