---
project_slug: hover-menu-preview
date: 2026-07-29
platform: windows
status: implemented
---

# Windows Instant Panel Close

## 現象

パネルが閉じる終盤に、内容が細長い黒いバーへ変形し、画面上端を横へ滑るように見える。

## 原因

commit `b9dcdc4`で、WebView2のリサイズ中のカクつきを隠すため、パネル内容の静止画をWPF Imageへ表示するモーフィングが追加されていた。

- `_morphImage`は`Stretch.Fill`。
- close中はパネル全幅からcollapsed `72x12`へ220msで縮小する。
- close進捗78%までは静止画opacity 1を維持する。
- 静止画全体が小さい矩形へ圧縮されるため、終盤では画像内容が黒いバー状になる。
- left / top / width / heightを同時補間するため、バーが横へ移動して見える。

ユーザー提供画像の位置・高さと、このclose終盤のcollapsed geometryが一致する。CSS provider animationではなく、native windowのclose morphが原因。

## 修正

- `PanelWindow.CloseAsync`からsnapshot morphと220msのgeometry / opacity animationを除去した。
- close要求時にanimation generationとsnapshot refreshを無効化し、`Opacity=0`、`Hide()`、collapsed配置、morph resetを同一ターンで行う。
- openとpanel resizeのsnapshot morphは維持した。
- close専用のeasing、crossfade、enum分岐を削除した。
- `ShellVerifier`に、close task開始直後にpanelがvisible / animatingの中間状態を残さない回帰検査を追加した。
- 即時closeで初めて露出したControlsライブプレビューの停止競合も修正した。linked cancellationをcapture停止より先に発火すると、キャンセル済みframe processorがactive sessionの保留frameを同期再起動し続け、`0xC00000FD`で落ちていた。captureを先に停止し、キャンセル済みsessionではframe処理を再起動しない。
- synchronous close中の再入に備え、進行中close taskをcore処理開始前に公開するようにした。

## 検証

- Debug build: warnings 0 / errors 0。
- Release build: warnings 0 / errors 0。
- `--verify shell`: exit 0。
  - `cycles=25`
  - `stable_position=true`
  - `outside_close=true`
  - `instant_close=true`
  - Debug open animation frames: `31`
  - Debug maximum frame gap: `17.5ms`
  - Release open animation frames: `29`
  - Release maximum frame gap: `18.1ms`
- `--verify ui`: exit 0。実WebView2 host、Controls、Clipboard、Calculator、Timer、Calendar、bridge、settingsのround-tripに合格。
- `--verify display`: exit 0。1 monitor、5120x2160、144 DPI。
- Debug / Releaseの`ui-model`、`sticky`、`clipboard`、`calc`、`timer`、`calendar`、`settings`、`ailane`、`updater`、`controls`: すべてexit 0。
- updater verifierは`0.2.3`から`0.2.4`へのupdate-availableを確認した。
- Windows UI JavaScript 12ファイルの`node --check`: exit 0。
- `git diff --check`: errorなし。

## 実画面確認境界

Computer UseではHoverPocketのタイトルなし`WS_EX_TOOLWINDOW`がtarget window一覧へ現れず、座標操作によるclose瞬間の動画取得はできなかった。代わりに、実WebView2を使うUI verifierと、close要求と同一ターンのWPF/native visibilityを検査するshell verifierで確認した。

現在のインストール済み0.2.3は変更していない。修正はローカルsource/buildと0.2.4のversion metadataへ反映済みで、配布版へ反映するにはWindows release `win-v0.2.4`の公開が必要。
