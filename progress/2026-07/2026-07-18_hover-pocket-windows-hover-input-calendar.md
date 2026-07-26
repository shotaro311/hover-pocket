# Windows Hover / Text Input / Clipboard Flicker / Calendar UI

Date: 2026-07-18

## 目的

- 上端へhoverしてもpanelが開かない問題を修正する。
- Sticky Notesで文字入力と貼り付けを受けられるようにする。
- Clipboard icon上の微小なmouse移動で画面が高速にちらつく問題を修正する。
- Windows Calendarの予定表表示をmacOS版に合わせる。

## 原因

1. 前景windowのrectがmonitor全体を覆うかだけで全画面判定していたため、Windowsの最大化枠がmonitor外へ数px出る通常の最大化windowも全画面と判定し、`disableTopEdgeInFullscreen=true`でhover pollingとaccess surfaceを抑止していた。
2. panelは常時`WS_EX_NOACTIVATE`、`Focusable=false`、`WM_MOUSEACTIVATE -> MA_NOACTIVATE`だったため、WebView2内のinput / textareaへDOM focusが見えてもtop-level windowがkeyboard focusを取得できなかった。
3. Clipboard provider本体の再mount抑止は入っていたが、headerのprovider iconはstate更新のたびに`replaceChildren()`で全再生成されていた。hover中のnode消失と再生成が新しいmouseenter / provider選択を誘発し、微小移動で循環した。
4. Windows Calendarは上部toolbar、予定件数bubble、card状の右paneで、macOS版の固定幅month pane、event dots、divider、簡潔なday detailと構造が異なっていた。

## 実装

### Hover

- `NativeMethods.IsForegroundWindowFullscreen()`へ`IsZoomed`判定を追加した。
- 最大化windowは全画面抑止対象から除外し、非最大化でmonitor全体を覆うborderless windowは従来どおり抑止するpure geometry helperを追加した。
- shell verifierへborderless fullscreen、最大化overhang、work-area windowの3ケースを追加した。

### Text input / paste

- `NoActivateWindow`へactivation modeを追加した。通常は`WS_EX_NOACTIVATE`を維持し、panel内のmouse interactionだけ`MA_ACTIVATE`へ切り替える。
- `PanelWindow`へ`panel.beginTextInput` / `panel.endTextInput` bridgeを追加し、WebView2 input開始時にno-activate styleを外してpanelとWebViewへfocusを渡す。
- Sticky editorとCalendar event editorは編集開始時にactivationを要求し、確定・cancel・provider dispose・panel closeで非active styleへ戻す。
- health checkerは入力中だけpanelに`WS_EX_NOACTIVATE`がない状態を正常として扱う。

### Clipboard flicker

- provider構成が変わらない限りheader icon nodeを再生成せず、selected classとARIA stateだけを更新するようにした。
- hoverによるprovider選択を1本のqueueで直列化し、待機中は最後にhoverしたproviderだけを次の要求にする。
- UI verifierへClipboard icon node identity、Clipboard root identity、unchanged refresh identityの検査を追加した。

### Calendar macOS parity

- macOS `CalendarPreviewMetrics`に合わせて、smallはcalendar width 248px / day 32x28px / gap 4px、medium / largeは282px / 36x32px / gap 5pxにした。
- month header、weekday initials、42 day cells、予定色dot最大3個、today / selected state、縦divider、right detail paneを実装した。
- detail paneは日付、snapshot更新時刻、追加button、4pxのcalendar color bar付きevent row、empty / reconnect / error状態を表示する。
- `CalendarProviderState`へ`UpdatedAt`を追加し、実snapshotがある時だけ更新時刻を渡す。
- signed-out、missing OAuth setup、needs-reconnect、event editor、connect / disconnectの既存経路は保持した。

## 検証

- `node --check`:
  - `windows/ui/js/app.js`: pass
  - `windows/ui/providers/sticky/sticky.js`: pass
  - `windows/ui/providers/calendar/calendar.js`: pass
  - `windows/ui/providers/clipboard/clipboard.js`: pass
- `dotnet build windows/HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`: pass、warnings 0 / errors 0。
- Debug executable verifier:
  - `--verify shell`: exit 0。`windows=12`、`cycles=25`、`stable_position=true`、`outside_close=true`、`polling_open=true`、`health_repair=true`、`window_recreate=true`、`staged_recovery=true`、最終animation 16 frames / max gap 23.2ms。
  - `--verify sticky`: exit 0。
  - `--verify clipboard`: exit 0。
  - `--verify calendar`: exit 0。
  - `--verify ui-model`: exit 0。
  - `--verify settings`: exit 0。
  - `--verify ui`: exit 0。icon identity、input activation style、Mac型month/detail pane、42日dot gridを含む。
- live cursor / Win32 readback:
  - primary screen `2560x1440`、上端中央`1280,1`へ実cursorを移動するとpanel HWNDがvisibleになり、rectは`940,9,1620,497`だった。
  - pointerを画面中央へ戻すとpanelはcloseした。
  - idleでは`WS_EX_NOACTIVATE=true`、mouse activation responseは`MA_ACTIVATE=1`、input modeではstyleが外れ、close後に`WS_EX_NOACTIVATE=true`へ復元した。
  - 通常起動後はPID `41980`の1processだけで、pathは`windows/src/HoverPocket.Shell/bin/Debug/net10.0-windows10.0.22621.0/HoverPocket.Shell.exe`、`Responding=True`。

## 注意点

- Computer Useのwindow列挙はtray / no-activate panelを対象windowとして返さないため、screen OCRによるSticky本文への実文字入力は行っていない。保存済み付箋を変更せず、WebView UI verifierとlive Win32 activation/style readbackで入力経路を検証した。
- 最初のbuildは旧processの対象確認式がPowerShellで解釈されずfile lockで失敗した。PIDと実行pathを再照合して旧processだけを終了し、その後の最終buildはwarnings 0 / errors 0で成功した。
- 既存のstaged / unstaged作業を保持し、commit、stage、release、外部公開は行っていない。
