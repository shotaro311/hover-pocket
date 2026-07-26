---
project_slug: hover-pocket
date: 2026-07-20
area: windows-controls-brightness
status: completed-local
---

# Windows Monitorian-style Brightness Control

## 依頼

Windows版のモニター調整コントロールが重いため、軽快に動作するMonitorianの仕組みを参考に改善する。

## 調査結果

- 変更前は輝度操作のたびにdisplayを再列挙し、物理モニターハンドルを開き直し、capabilityと現在値を読み、さらに全displayのreadbackを最大2回行っていた。
- 輝度変更の応答を作るために、無関係な音量とメディア状態も毎回取得していた。
- UIは`change`時にだけ送信するためドラッグ中の追従がなく、同じモニターの処理中に後続値が来ると破棄していた。
- high-level DDC brightness capabilityがない場合を一律非対応としていた。実機ではこの判定により`\\.\DISPLAY1`が非対応だったが、VCP luminance `0x10`は利用できた。
- Monitorian公式実装は、物理モニターハンドルとraw範囲を保持して対象へ直接書き込み、成功後はメモリ上の値を更新する。slider bindingには短いDelayを設け、低レベルVCPをfallbackに使用する。

## 実装

- `MonitorBrightnessService`
  - 物理モニターハンドルをSafeHandleで保持し、topology変更または2分経過時だけ再検出する。
  - high-level APIとVCP `0x10`を自動選択し、選択結果とraw最小・最大値を再利用する。
  - VCPの再試行をDDC message / I2C transmissionの一時エラーに限定する。
  - 輝度変更後の全display再列挙と全readbackを廃止し、対象へ直接書き込んでsnapshotを更新する。
  - DDC読取が180msを超えた場合は既存状態を返してUIを先に描画し、バックグラウンド完了時に`StateChanged`で差し替える。
  - 保持した物理ハンドルはtopology再検出時とservice破棄時に確実に閉じる。
- `ControlsBridgeController`
  - brightness eventを既存snapshotへ合成する。
  - 輝度変更時は既存のvolume / media / previewを保持し、無関係な再取得を行わない。
- `controls.js`
  - input値を即座に表示しつつ、bridge送信は60ms間隔に制限する。
  - 送信中は最新値1件だけを保持し、古い値をqueueへ蓄積しない。
  - 最終`change`値をflushし、応答によるDOM差し替えは操作完了まで遅延する。
- `ControlsVerifier`
  - brightness操作がvolume / mediaの追加readを発生させないことを決定的テストへ追加した。
  - 初回応答時間、cached read、直接write時間を出力する。
  - 輝度変更と復元は、保持した接続から実値を読み戻して検証する。

## 検証

- `dotnet build windows/src/HoverPocket.Shell/HoverPocket.Shell.csproj -c Debug --nologo`
  - 成功。warnings 0 / errors 0。
- Debug `--verify controls --change-brightness`
  - `controls_deterministic=ok`
  - `display_initial_read_ms=188.6`
  - `display_cached_read_ms=0.0`
  - `Generic PnP Monitor`, `supported=True`, `value=39`
  - `brightness_write_ms=61.1`
  - 39%から40%への変更を実readbackで確認した。
  - 39%への復元を実readbackで確認した。
  - `controls_verify=ok`, exit 0。
- Debug `--verify ui`
  - Controlsの安定refresh、領域収まり、bridge/provider round-tripを含めてPASS、exit 0。

## 境界

- 自動検証は単発writeとreadback、UIの実描画を確認した。人の手による長い連続ドラッグの体感評価は自動化していない。
- release artifactの生成、署名、公開は依頼範囲外のため実施していない。

## 画像readback後の追加修正

ユーザー画像で、実アプリ上のdisplayカードが`\\.\DISPLAY1`、`非対応`、`明るさを検出しています。`の一時状態から更新されていないことを確認した。

### 原因

- brightness検出完了時にvolume / mediaを含む初期snapshotが未完成だと、controllerに合成先がなく確定値を失っていた。
- パネル非表示中またはControls providerのmount直前に検出が完了するとWebViewがeventを受信できず、直後の`controls.getState`も750ms cache内の一時snapshotを返していた。

### 修正

- controllerはbrightness完了値を`_latestDisplays`へ常に保持し、初期snapshot作成時だけでなくcached snapshot返却時にも合成する。
- 一時状態は右側を`非対応`ではなく`検出中…`と表示する。
- WebViewは検出中だけ900ms後に完了cacheを再確認する。最大3回で停止し、進行中の同じtaskを共有するため、新しいDDC列挙やprobeを重複させない。
- 決定的テストへ、初期snapshot作成中に完了する競合と、非active時に完了してcached snapshotへ合成する競合を追加した。
- UI verifierはdisplay行の`is-detecting`が4.5秒以内に解消することを検査する。

### 再検証

- Debug build: warnings 0 / errors 0。
- `--verify controls --change-brightness`: `controls_brightness_detection_race=ok`、`controls_brightness_cached_merge=ok`、actual monitor 39%、write 61.4ms、変更・復元readback成功、exit 0。
- `--verify ui`: brightness一時状態の解消、Controls stable refreshを含めてPASS、exit 0。
