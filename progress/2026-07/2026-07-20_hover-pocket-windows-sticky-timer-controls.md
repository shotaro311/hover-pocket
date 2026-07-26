# HoverPocket Windows Sticky / Timer / Controls 改善

## 実施日

- 2026-07-20

## 付箋

- 編集ツールバーのarchive、delete、saveを文字記号からストロークSVGへ変更した。
- deleteはゴミ箱アイコンにした。
- 淡色の付箋上でも見分けられるよう、archiveは青、deleteは赤、saveは緑の背景と濃色アイコンにし、border、shadow、keyboard focus ringを付けた。

## Timer

- Running / Pinnedは全幅、Timer / Pomodoro入力カードは中・大パネルで`42% / 58%`の2列にした。小パネルは1列へ戻す。
- Pomodoroは集中と休憩を2列、開始とプリセット操作を別行にし、幅が足りない場合の重なりを防いだ。
- Startをアイコンだけでなく「開始」ラベル付きのアクセントボタンにした。
- duration railのドラッグ中はローカルのHH:MM:SSだけを更新し、`change`時にbridgeへ保存する。操作中のDOM全置換は行わない。
- provider instanceごとにtick timerを持ち、複数display時に別instanceのintervalを止めない。

## Controls

- WebViewの5秒ごとの`controls.getState`とnative側の5秒fallbackが重複していたため、WebView pollingを削除し、native eventと10秒fallbackへ集約した。
- `ControlsBridgeController`に750msのsnapshot cacheと同時refreshの排他を追加し、provider activationとWebView初期readの重複API呼び出しを抑えた。
- brightness列挙は15秒cacheにし、WMI / DDC/CIの高コスト列挙を毎refreshで繰り返さない。書き込み後の実readbackは従来どおり強制実行する。
- GSMTCのMedia / Playback / Timeline eventを90msのlatest-only refreshへ合流し、イベントごとのTask待ち行列を作らない。
- artworkはsource / title / artist / albumをkeyにcacheし、timeline更新で最大5MBのstream読み込みとBase64化を繰り返さない。MediaPropertiesChangedとsession変更で無効化する。
- Windows Graphics Captureはpending frame 1枚のみを維持したまま、software JPEG / Base64 encodeを最大10fpsへ制限した。表示fpsはsource arrivalではなくencoded frameに合わせた。
- WebViewはsnapshot signatureが同じ場合にmedia timelineだけを差分更新し、canvas、artwork、button DOMを再生成しない。並列の異なる操作は許可し、古いsnapshotは破棄する。

## 検証

- `node --check`
  - `windows/ui/providers/sticky/sticky.js`
  - `windows/ui/providers/timer/timer.js`
  - `windows/ui/providers/controls/controls.js`
  - `windows/ui/js/app.js`
- `git diff --check`: exit 0
- `dotnet build windows/src/HoverPocket.Shell/HoverPocket.Shell.csproj --no-restore`
  - warnings 0
  - errors 0
- `--verify sticky`: exit 0
- `--verify timer`: exit 0
- `--verify controls`: exit 0
  - immediate snapshot cacheのread count維持をdeterministic fakeで確認
  - 実機volume readback成功
  - 実機displayは1台、brightness非対応として安全にfallback
  - 実機media sessionなし
- `--verify ui-model`: exit 0
- `--verify ui`: exit 0
  - Controlsの同内容refreshでlive preview canvas DOMを維持
  - Timer sectionの横overflowなし
  - duration railの`input`後も同じDOM nodeを維持

## 未検証

- 検証時に実機のWindows media sessionがなかったため、再生中のWindows Graphics Captureに対するCPU使用率の実測は未実施。
