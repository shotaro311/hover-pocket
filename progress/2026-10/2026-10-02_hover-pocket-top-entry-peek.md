# 2026-10-02 Windows上部入口の自動非表示

設定の「上端とのつながり」に「上部の入口を自動で隠す」を追加した。通常の入口幅を保持し、近接で入口だけを表示、入口にホバーしてパネルを開く二段階の操作へ切り替えられる。旧設定ではオフを補う。作業先は前回と同じDownloads内の独立clone、開発版は`0.2.9-local.4`。

## 動きと保存

- 入口の左右40 DIPs、画面上端から36 DIPsが近接領域。入口が滑り出して落ち着くまでパネルを開かず、実際の入口の内側へのホバーで開く。
- パネルが開いている間はその画面の入口を保持する。閉じて近接領域から離れると240ms待ち、入口を上端へ引っ込める。再進入では途中の位置と速度を引き継ぐ。
- 非表示完了後はWPF/Win32の両方で窓を隠す。近接領域には窓を追加しない。静止時は入口のRendering購読を解除する。Reduce Motionでは即時切替。
- `autoHideTopHandle`はboolean、既定false。`settings.setAutoHideTopHandle`は必須booleanの`enabled`を受ける。既存JSONに項目がなくても既存の選択を保つ。既存serializerと旧JSON fixture、保存再読込を使い、破壊的migrationを追加していない。

## 検証と未確認

Debug/ReleaseのWindowsネイティブbuildが警告0・エラー0。JS構文検査と`git diff --check`が通過。最終Release shellはexit 0、100回の開閉後もプロセスの上位ウィンドウ数12を保持し、30回の途中再進入が通過した。

入口の検査は4サイズ×2入口幅の8通りが通過。近接だけで入口を表示、入口へのホバーで開く、離れると入口まで隠す、再進入、非表示中の修復、Reduce Motion、常時表示への復帰、Rendering停止を確認した。実画面から[入口の画像](../evidence/2026-10-02-windows-liquid/top-entry-peek.png)を採取した。

最終Releaseのshell、ui、display、settingsはすべてexit 0。[最終結果](../evidence/2026-10-02-windows-liquid/release-top-entry-results.json)。実WebView2の設定checkboxをオン・オフし、bridgeから読み戻した。旧JSON、既定オフ、保存再読込、値の型が不正な要求を拒否して設定を保つことをsettings verifierで確認した。表示先は実接続1画面・5120×2160・DPI144（150%）。100/125/150/200%と負の座標は座標検査で確認した。

今回の関連検査ui-model、Timer、Weather、Voice基盤、Calendarはexit 0。Voiceは実音声会話を起動していない。

初回は8通りすべての二段階表示が通ったが、WPFでは隠れたままWin32だけが表示される異常を注入した修復検査が失敗した。`Hide()`だけではこの状態を直せないため、非表示確定時にWin32側も隠すように修正した。次のshell検査では、画像取得のGDI+初期化によるウィンドウ数の変化を拾った。画像取得は既存の検査と同様にUI検査へ限定し、shellの100回開閉で数が変わらないことを確認した。失敗ログは保持する。

物理マウスの自動操作、実接続の複数画面、他DPI、実音声会話は今回の確認に含まない。近接・ホバーはポインター座標を検査アプリへ注入し、実ウィンドウとWebView2、Windowsの領域判定で検証する。

## 通常起動と設定のreadback

21:36 JSTにDebug開発版`0.2.9-local.4`を引数なしで通常起動した（PID48284）。起動パス・版・exe/DLLのハッシュを[起動receipt](../evidence/2026-10-02-windows-liquid/top-entry-normal-launch.json)へ保存。実際に配信する設定HTML/JSとソースのハッシュが一致した。

通常設定`%APPDATA%/HoverPocket/settings.json`の`autoHideTopHandle`だけをtrueへ変更してから起動した。他の設定がJSON構造として等しいことを検査し、元のファイルをDownloadsへバックアップしている。バックアップ先はreceiptに記録した。設定からオフにすると常時表示へ戻せる。

元のdirty checkoutの変更一覧を再確認し、維持した。既存インストールの置換、GitHubへの公開、配信feedの更新、課金、startup登録の変更は行っていない。
