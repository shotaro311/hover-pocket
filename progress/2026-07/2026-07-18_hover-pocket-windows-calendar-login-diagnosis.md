---
project_slug: hover-pocket
date: 2026-07-18
platform: windows
status: local-e2e-complete-release-injection-pending
---

# Windows Google Calendar login diagnosis

## Scope and preservation

- 正本clone: `C:\Users\shotaro\code\shared\hover-pocket`
- HEAD: `4a75426aafb937f81d4242831e76dbd2b74a4665`、`HEAD...origin/main=0 0`。
- 作業開始時から存在したstaged / unstaged / untracked変更と、前回のhover recovery変更には触れなかった。reset、checkout、pull、rebase、commit、push、releaseは行っていない。
- ソース、publish設定、実行中binary、ローカル設定、Credential Manager、GitHub Actions設定、Chromeの既存Cloud Console sessionを、秘密値を表示せずreadbackした。

## Actual application state

- 実行中PID 33256は、インストール先ではなく正本cloneの`windows\src\HoverPocket.Shell\bin\Debug\net10.0-windows\HoverPocket.Shell.exe`だった。file versionは`0.2.1.0`。
- 実行中assemblyの`GoogleOAuthClientId` / `GoogleOAuthClientSecret` metadataはともにabsent。
- `%APPDATA%\HoverPocket\oauth.json`は存在しない。
- Credential Manager target `HoverPocket.GoogleOAuth.RefreshToken`はnot found（Win32 error 1168）。credential blob、token、account情報は読み出していない。
- native readbackではaccess surfaceはvisible、panelはhiddenだった。NOACTIVATE windowをComputer Useで一意に選択できず、ウィンドウ単体captureも全画面アプリの映像を返したため、実パネルのエラー文言は視覚確認できなかった。パネルの強制表示や全画面アプリの最小化は行っていない。

## Root cause and code path

- `GoogleOAuthService.SignInAsync`はconfiguration解決後、client IDが空なら`GoogleOAuthException("missing_configuration", "Google OAuth client is not configured.")`を返す。
- `CalendarStore.RefreshConnectionStatus`も同じconfiguration状態を`missing_configuration`へ変換し、UI stateに`Google OAuth の設定が必要です。`を設定する。
- Calendar UIは`missing_configuration`をsetup cardとして描画する。実行中assembly、`oauth.json`、Credential Managerがすべて未設定というreadbackが、このコード経路と一致した。
- 現行実装の新規認可scopeは`calendar.events`と`calendar.calendarlist.readonly`だけで、S256 PKCE、state検証、動的`127.0.0.1` loopback、offline refresh token、Credential Manager保存、再接続判定を備える。

## Safe client configuration search

- `HOVERPOCKET_GOOGLE_CLIENT_ID` / `HOVERPOCKET_GOOGLE_CLIENT_SECRET`は未設定。repo `.env.local`、`%APPDATA%\gcloud`、OAuth client JSON候補も存在しなかった。
- gcloud CLIは未導入。GitHub repository variable / secretにもWindows OAuth client設定は存在しなかった。値やsecret本文は出力していない。
- Chromeの既存Cloud Console sessionはCloud accessがMFA要件で停止しており、指定対象アカウントでもなかった。別アカウントへの切替、MFA・Cloud利用規約操作、OAuth clientの新規作成は行わなかった。
- 安全に取得できる承認済みWindows Desktop OAuth clientがないため、一時検証buildへの埋め込み、Google同意、token取得・refresh、Calendar readは実施していない。Calendar writeも行っていない。

## Verification

- 正本のbin / objを更新しない一時copy `C:\Windows\Temp\hover-pocket-oauth-diagnosis-bea337c39d6b4fd1a48e4344e33d15ef`を使用した。
- `dotnet build ...\HoverPocket.Shell.csproj --configuration Debug --nologo`: exit 0、warnings 0、errors 0。
- `Start-Process ...\HoverPocket.Shell.exe -ArgumentList '--verify','calendar' -Wait`: exit 0。OAuth configuration、OAuth URL / PKCE、loopback、Credential Manager、request builders、month grid、read-only guardsがPASSし、`oauth_embedded_metadata=absent`を確認した。
- 最初のverifier起動ではTFM出力directoryを誤って`net10.0-windows`と指定したため実行ファイルを発見できなかった。成功結果には数えていない。

## Outcome and next safe action

- 原因はOAuth実装不足ではなく、実際に使用中のWindows buildへclient configurationが配布されていないこと。
- OAuthコードは変更しなかった。次のWindows release buildでは、承認済み`hoverpocket` projectのDesktop OAuth clientをpublish環境へ設定し、生成artifactのmetadata presenceとproject-family equalityを値を出さずreadbackする必要がある。
- 再開には、指定対象アカウントでGoogle Cloudへログイン済みの安全なsessionをユーザーが用意するか、同projectからダウンロードしたDesktop client JSONをチャットへ貼らず`%APPDATA%\HoverPocket\oauth.json`へ配置する必要がある。
- configuration入手後、ログイン画面の対象アカウントを確認してから同意、token refresh、Calendar readを実施する。予定の作成・変更・削除は行わない。

## Follow-up: missing-configuration UX

- `%APPDATA%\HoverPocket\oauth.json`と`HOVERPOCKET_GOOGLE_CLIENT_ID` / `HOVERPOCKET_GOOGLE_CLIENT_SECRET`を再確認したが、すべて未設定だった。値は表示していない。
- 既存setup cardは実configuration pathとJSON配置手順を表示する一方、配置後の再起動を案内していなかった。`CalendarStore.SetupInstructions`へ「JSON配置後にHoverPocketを終了して再起動」を日英で追加した。
- `CalendarVerifier`へ、setup pathが実configuration pathと一致すること、日英の手順に`%APPDATA%\HoverPocket\oauth.json`と再起動案内が含まれることの決定的検査を追加した。
- 実行中Debug版はComputer Use上でtargetable windowを公開せず、二重起動によるpanel表示要求後もwindowが返らなかった。座標を推測した入力やpanel強制表示は行わず、実画面readbackは未確認として残した。
- 正本のbin / objを変更しない一時copy `C:\Windows\Temp\hover-pocket-calendar-ux-4030883b5a5649ca9dbb777a0ac9014f`で検証した。`dotnet build`はexit 0、warnings 0、errors 0。`--verify calendar`は`setup-instructions`を含めexit 0、`--verify ui`もexit 0。
- OAuth client設定がないため、対象アカウント確認、ログイン、同意、Calendar read、アプリ再起動後のrefresh、切断後の再接続E2Eは実行していない。予定の作成・編集・削除、OAuth client作成、アカウント切替、MFA、規約同意は行っていない。

## Follow-up: Google Cloud existing client check

- Chrome Extension経由でGoogle Cloud Consoleを開き、画面上のアカウントが指定対象アカウントと一致し、選択projectが`hoverpocket`であることを確認した。別アカウントへの切替は行っていない。
- Google Auth PlatformのClients一覧はvisible row 1件で、種類はiOS、名称はmacOS用だった。Desktop appは0件で、ページ内にもDesktop種別は存在しなかった。client IDは出力していない。
- iOS clientはWindowsの動的`127.0.0.1` loopback OAuth clientとして流用せず、新規Desktop client作成禁止の指示に従って停止した。
- client JSONのダウンロード・配置、HoverPocket終了・再起動、Google同意、Calendar read、refresh、切断・再接続は未実施。OAuth client secret、token、JSON内容は取得結果やログへ出力していない。

## Follow-up: Windows Desktop client creation

- ユーザーの明示承認後、Chrome上のアカウントが指定対象と一致し、projectが`hoverpocket`、既存clientがiOS 1件・Desktop 0件であることを作成直前に再確認した。
- Google Auth Platformでapplication type `Desktop app`、name `HoverPocket Windows`を1件作成し、`OAuth クライアントを作成しました`ダイアログをreadbackした。既存iOS client、consent screen、branding、scope、公開状態は変更していない。
- JSON download buttonを実行したがChrome Extensionのdownload event待機がtimeoutし、直近15分のDownloadsにはJSONが0件だった。その後も作成済みclient詳細のpage state取得が連続timeoutしたため、重複clientを作成せず停止した。
- `%APPDATA%\HoverPocket\oauth.json`は未配置。HoverPocketはPID 33256で稼働を継続し、再起動していない。Google同意、Calendar read、refresh、切断・再接続、審査status確認は未実施。
- client secret、token、JSON内容は出力していない。再開には、開いているCloud Consoleの作成済み`HoverPocket Windows`詳細でJSON downloadをユーザーが1回行う必要がある。

## Follow-up: local OAuth configuration and read-only E2E

- Downloadsに追加されたDesktop OAuth JSONを値を表示せず検査し、`installed`形式、client ID / client secret、Google auth / token URI、`hoverpocket` project系統を確認した。temp fileからatomic renameして`%APPDATA%\HoverPocket\oauth.json`へ配置し、source/destinationのhash一致とDownloads原本の保持をreadbackした。
- 稼働中の正本clone Debug版を同じ実行pathで再起動した。GUI操作基盤にはHoverPocket windowが公開されなかったため座標入力を避け、一時copyに同じ`CalendarStore`を呼ぶ読み取り専用helperを追加して、実Google OAuthとCalendar APIを検証した。一時helperのbuildはexit 0、warnings 0、errors 0。
- Google認証画面では毎回、表示emailが指定対象アカウント1件だけで他emailが0件であることをreadbackしてから選択・同意した。初回`signin-read`はexit 0、`signed_in` / `loaded`、calendar source 5件を取得した。予定名・内容、token、client設定値は出力せず、予定の作成・編集・削除も行っていない。
- 初回接続後にCredential Manager targetの存在を確認した。Debug本体を再起動した後のfresh process `read`もexit 0、`signed_in` / `loaded`で、保存refresh credentialからのCalendar readを確認した。
- `signout`はexit 0で`credentialTargetPresent=false`を確認した。その後、同じ指定対象アカウントで再同意し、`signin-read`がexit 0。Debug本体をもう一度再起動してcredential targetの存在とfresh process `read` exit 0を確認し、最終状態を接続済みに戻した。
- Google Auth Platformの検証センターを同じ指定対象アカウント・`hoverpocket` projectでreadbackし、brandingは検証済み、data accessも検証済みの表示だった。Desktop client追加後も再審査要求やaction-required表示はなかった。既存iOS client、consent screen、branding、scope、公開状態には変更を加えていない。
- 正本Debug `--verify calendar`はexit 0。OAuth configuration、OAuth URL / PKCE、loopback、Credential Manager、request builders、month grid、read-only guardsがPASSし、embedded metadataはabsentのままだった。
- 最終Debug PIDは56012。native readbackではprocess running、top-level HWND 15件、visible 1件で上端access surfaceが存在し、panelはhiddenだった。実Calendar panelの視覚readbackだけはGUI非targetableのため未確認。
- 正式Windows releaseは未実施。次回publish時にDesktop client設定を安全なbuild secret / variableからAssemblyMetadataへ注入し、公開前後artifactのmetadata presenceとproject-family equalityを値を出さずreadbackする必要がある。reset、checkout、pull、rebase、commit、push、releaseは行っていない。

## Follow-up: latest local Windows app restart

- 現行作業ツリーを`dotnet build .\windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`で再ビルドし、exit 0、warnings 0、errors 0を確認した。
- 起動中だった旧`net10.0-windows\HoverPocket.Shell.exe`を終了した。Computer Useの初回起動は登録済みの旧pathへ解決されたため、その誤起動を終了し、生成直後の`net10.0-windows10.0.22621.0\HoverPocket.Shell.exe`を絶対pathで起動し直した。
- 最終readbackはPID 46048、起動時刻`2026-07-18 18:52:16`、file version `0.2.1.0`、product version `0.2.1+4a75426aafb937f81d4242831e76dbd2b74a4665`、`Responding=True`。HoverPocketプロセスは1件だけで、実行pathは期待値と一致した。
- ソース、設定、OAuth credential、release、Git状態は変更していない。GUI操作基盤はtray常駐アプリのwindowを返さないため、最終確認はprocess / path / version / respondingのreadbackで行った。
