# 2026-10-02 Windows液体アニメーション

## 実装と配置

Mac開発版661の参照をWindowsで移植した。作業先は`C:\Users\shotaro\Downloads\hover-pocket-windows-liquid-20261002`、branchは`codex/windows-liquid-mac661`。元のdirty checkoutと`hover-pocket-windows-stabilization-20260928`は変更していない。

- 基準: origin/main `0080be397592000b66c64ece1a2ffcc65b33be0c`。
- 既存の天気/XL parity `c285b3e8ecdc0f78cff952c8906327579527b57f`を検証済みローカルbundleから移入。安定化`fcaa5099`のTimer配信修正も保持。
- Mac参照ZIP SHA256: `f7c2201e658f084dfbe8d873b0a0dd66835c3ed98689e2e3165f42ddadd0f4ed`。33ファイルのmanifestのサイズ/ハッシュ不一致0。
- ローカル開発版`0.2.9-local.3`。起動対象は`windows/src/HoverPocket.Shell/bin/Debug/net10.0-windows10.0.22621.0/HoverPocket.Shell.exe`。
- 21:01 JSTに上記Debug exeを引数なしで通常起動（PID26524）。実パス・ProductVersion・exe/DLLのSHA256を[起動receipt](../evidence/2026-10-02-windows-liquid/normal-launch.json)へ保存した。版のcommit suffixはビルド時の移入基準`0cbcad87`を示す。今回のローカル変更の識別はDLLハッシュとこのbranchの差分で行う。

輪郭と内容を別々に拡大する処理を廃止し、現在の位置・速度から反転できるばねへ置き換えた。WebView2CompositionControl、WPF Clip、SetWindowRgn、ホバー判定を同じ輪郭へ揃えた。完了時の再入で新しい遷移を停止しないようにした。入口は既存の168/72 DIPs、接合は最大6 DIPs。サイズ変更中も画面上端を固定する。

「細い入口を残す」「上端まで覆う」と自動切替・Reduce Motionを設定画面へ追加した。保存済みの手動値と実効値を分離し、同じresolverを描画とブリッジで使う。新規依存やproductionのbroker/sandbox flag変更はない。

## 検証

Debug/ReleaseともWindowsネイティブbuildが警告0・エラー0。JS構文検査と`git diff --check`が通過。

- Release関連14対象: ui、shell、display、settings、ui-model、weather、voice、timer、calendar、calc、sticky、clipboard、pocket-surface、voice-e2e-isolationが全てexit 0。[全体結果](../evidence/2026-10-02-windows-liquid/release-regression-results.json)。追加検査後にui/display/settingsも再検証。
- [実UI・設定・表示先の追加検証結果](../evidence/2026-10-02-windows-liquid/release-liquid-surface-results.json)。旧JSON fixture追加後のsettings verifierもexit 0。
- shell: 100回開閉、ポーリングだけの開く操作、外側で閉じる動作、位置保持、第二インスタンス、窓破損の修復・再生成、復帰schedulerが通過。17 frames、最大frame gap 20.8ms（今回の検査値）。
- 実WebView2: 4サイズ×2モードで画面上端の隙間0、300回の静止入口保持、途中反転、30回の再進入、手動/自動の保持、Reduce Motionが通過。GetWindowRgnとWindowFromPointで内容の内側と切り抜いた角のWindowsヒット判定を検査。
- 設定の実WebView2で2ボタン・自動checkbox・Reduce Motion checkboxを操作し、bridgeから読み戻した。独立した設定storeでは旧JSON fixture・既定オフ・保存再読込・自動を切った時の手動復帰を検査。
- UIの既存Controls/Timer/Clipboard/Calculator/Calendar/自作ツール、背景threadからの配信、非表示パネルのTimer通知・再表示が通過。Voiceは基盤・geometry/契約・安全境界の検査で、実会話を起動していない。
- 座標検査: 4サイズ×100/125/150/200%×正負の原点、compact/expanded Voice高さを確認。実接続は1画面、5120×2160、DPI144（150%）。他DPIと複数画面は実接続での検査ではない。
- 静止CPU: 開いた実パネルを3秒計測し、本体0.52～1.56%、WebView2 browser process 0～0.52%（1コア換算）。ばねRendering購読停止を確認。renderer process/GPUの負荷は含まない。

実画面の8枚を検査アプリからCopyFromScreenで採取し、隣接するデスクトップ部分を輪郭の外側から除いた。HTML fixture画像ではない。代表画像を目視確認:

- [細い入口](../evidence/2026-10-02-windows-liquid/native-medium-preserveMenu.png)
- [上端まで覆う](../evidence/2026-10-02-windows-liquid/native-medium-coverMenu.png)

Computer Useでは非アクティブのtool windowが列挙されなかったため、物理マウスによるボタン操作の自動化は行っていない。設定のDOM操作、ブリッジreadback、OSヒット判定を使った。実ノッチ、複数画面、画面切替・抜き差し、長時間CPU、実マイク会話は未確認。

## 修正した検証失敗

初回は内容がゼロサイズになるとWebView2のcapture poolが失敗したため、内容の寸法を保って切り抜く方式にした。Macのside paddingを前提にした上端の曲線はWindowsの窓内へ収めた。負の画面座標をサイズと同じ丸め関数で正値へ制限していた既存不具合を修正した。設定変更の窓サイズが未確定の瞬間を拾わないよう、ネイティブサイズと描画停止が連続して安定するまで待つ検査へ変更した。失敗ログは証拠として保持。

## 再実行

```powershell
dotnet build windows/src/HoverPocket.Shell/HoverPocket.Shell.csproj -c Release
./windows/script/verify_liquid_local.ps1 -Configuration Release
```

公開・GitHub Releases更新・既存インストールの置換・課金は行っていない。既存worktreeのローカル変更も保持した。
