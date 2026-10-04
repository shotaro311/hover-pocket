# Windows液体アニメーション（Mac開発版661参照）

入口からパネルまで連続した黒い輪郭で開閉する。画面上端を固定し、ばねの位置と速度を途中反転・サイズ変更・モード変更で保持する。WebView2の内容、描画の切り抜き、Windowsの窓領域とホバー保持は同じ幾何形状を使う。

- 「細い入口を残す」: 既存入口168/72 DIPsを画面上端まで直線で延ばし、下端の最大6 DIPsの接合曲線で本体へつなぐ。
- 「上端まで覆う」: 同じ入口から横と下へ同時に広がる。Windowsの窓にmacOS側の余白はないため、上端の曲線は窓幅内へ収める。
- 入口と現在の輪郭の和集合、4 DIPsの許容幅でホバーを保持する。別画面の入口は保持対象にしない。再進入で閉鎖予約を取り消し、古い閉鎖処理は新しい開く処理へ閉鎖通知を送らない。
- 4サイズ、Voiceのcompact/expanded高さ、表示先設定、既存の道具を保持する。Reduce Motionでは即時切替。静止時はばねのRendering購読を解除する。

## 保存・ブリッジ契約

`UserSettings`が保存形式の正本。既存JSONへ省略可能な4項目を追加する。DB/OpenAPIや別の設定Schemaは存在しない。

|項目|保存値・既定|意味|
|---|---|---|
|panelAttachmentStyle|preserveMenu / coverMenu、既定preserveMenu|手動選択|
|automaticScreenEdgeAttachment|boolean、既定false|ノッチなし画面では実効値coverMenu|
|reduceMotion|boolean、既定false|Windows側のアニメーション設定と併用|
|autoHideTopHandle|boolean、既定false|上部の入口を自動で隠し、近接で入口だけ表示する|

`settings.setPanelAttachment`のparamsは`style`、`automatic`、`reduceMotion`。省略した項目は保持する。ブリッジの`effectivePanelAttachmentStyle`は共通resolverで導出し、保存しない。Windowsの現在のディスプレイ列挙は物理ノッチ情報を持たないため、各表示先をノッチなしとして解決する。手動選択を上書きしない。

`settings.setAutoHideTopHandle`のparamsは必須booleanの`enabled`。設定画面の「上部の入口を自動で隠す」で切り替える。オンでは入口付近へ近づくと入口だけが滑り出す。近接領域は従来の幅・深さをそれぞれ2倍とし、幅は入口幅の2倍+160 DIPs、深さは72 DIPs。画面外は切り詰める。入口の実領域へ直接マウスを動かすと、入口の表示完了を待たずにパネルを開く。自動非表示オン時の位置確認は30ms間隔。近接だけではパネルを開かない。初回のWebView2準備とパネル表示は同時に進め、内容の初回読み込みで輪郭の表示を待たせない。パネルを閉じて近接領域から離れると240ms待って入口も隠す。近接領域には透明ウィンドウを作らず、非表示完了時はネイティブウィンドウも隠す。表示中のパネルに対応する入口は保持する。Reduce Motionは入口の動きにも適用し、静止時はRendering購読を解除する。

旧JSONに項目がなくても既存の言語・サイズ等を保持して既定を補う。旧バイナリは追加項目を無視できるため、ファイルの破壊的なmigrationは不要。legacy fixture、既定、保存・再読込、手動/自動の復帰をsettings verifierで検証する。

## 描画基盤

既存パッケージに含まれるWebView2CompositionControlを使う。WPF内で内容を輪郭に沿って切り抜けるようにする。ゼロサイズのcapture poolを作らないため、内容の寸法を保って輪郭を縮める。画面座標は符号を保持し、サイズだけを1 pixel以上に丸める。

- [Microsoft: WPF WebView2CompositionControl](https://learn.microsoft.com/en-us/microsoft-edge/webview2/platforms/wpf)
- [Microsoft: SetWindowRgnと領域の所有権](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowrgn)

実機検証と未確認範囲は[日別ログ](../../progress/2026-10/2026-10-02_hover-pocket-windows-liquid.md)を参照する。
