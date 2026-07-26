---
project_slug: hover-menu-preview
date: 2026-07-10
actor: codex
scope: windows-controls-settings-motion
---

# Windows Controls / settings / motion parity

## Summary

- Windows 版の対象を Controls、Calendar、Clipboard、Sticky Notes、Timer、Calculator とし、Mirror / Microphone はユーザー判断により対象外へ変更した。macOS 版の Mirror 実装と配布要件は変更していない。
- Controls provider を追加し、Core Audio のマスター音量・ミュート、WMI / DDC/CI のディスプレイ輝度、Windows の system media session による Now Playing・再生/停止・シーク・再生速度を実装した。
- Settings に表示先、最後に選んだ provider / 固定 provider、上端ハンドル B / C / None、ハンドル横幅、全画面中の上端抑止、Sticky grid size、表示先リセット、データフォルダー導線を追加した。B / C は選択ラベルだけを文字で表示し、実ハンドルはmacOS同様に下向きchevron / pocket glyphを描画する。
- パネル開閉・リサイズを WPF の描画タイミングへ同期し、通常時の WebView2 GPU 無効化を廃止した。開閉中は事前取得した WebView snapshot を伸縮・crossfadeし、閉じかけからの再オープンは現在位置から反転する。OS の animation 無効設定も尊重する。
- 開閉の位置更新は最短 5ms 間隔へ制限し、native resize が Rendering event を再発火する feedback loop を抑えた。

## Readback

- 実機 Controls probe: `displays=1`、`volume_available=True`、`media_available=False`。再生中メディアがない状態は空表示として正常に扱う。
- Debug shell: open/close 25 cycle、window count 12、最終 close 18 frames、最大 frame gap 23.6ms。
- Release shell: Clipboard flicker fix後の再生成版でopen/close 25 cycle、window count 12、最終 close 20 frames、最大 frame gap 20.1ms。
- WebView2 runtime は Controls の Displays / Sound / Now Playing 3セクションを描画し、provider bounds 内に収まることを DOM 実寸で確認した。
- 旧 `net10.0-windows` 通常プロセスは新しい single-instance verifier の妨げになるため、実行パスと PID を照合して終了した。
- Computer Use は旧 target をアプリ候補として優先し、NOACTIVATE / TOOLWINDOW の新パネルを targetable window として列挙できなかった。画面入力はそこで停止し、WebView2 runtime / DOM layout verifier を実画面相当の確認経路として使用した。

## Verification

- `node --check` for `app.js`, `controls.js`, `settings.js`, `i18n.js`: exit code 0.
- `dotnet build windows/HoverPocket.Windows.sln --configuration Debug`: exit code 0, warnings 0, errors 0.
- Debug verifiers: `controls`, `settings`, `ui-model`, `calc`, `timer`, `sticky`, `clipboard`, `calendar`, `ailane`, `updater`, `display`, `ui`, `shell`: all exit code 0.
- `--verify settings` の初回 timeout は、UI thread を同期停止したまま Clipboard listener が同じ dispatcher を待つ deadlock が原因だった。Settings verifier を UI dispatcher 上の async flow へ変更し、再実行は exit code 0。
- `windows/script/publish_release.ps1`: exit code 0。self-contained Release と Velopack 1.2.0 assets をローカル生成した。
- Release verifiers: `settings`, `controls`, `ui`, `shell`: all exit code 0.
- Setup SHA256: `A67B972C7F53E28045362A0A04AA43853B815492B3840BE36145924B2332FD8C`。
- Portable ZIP SHA256: `451FFC96A5CB9389F62639346A77FCCF488411355C1DF5E6FE3712A6EECD5D6C`。

## Distribution boundary

- ローカル成果物は `dist/windows/releases/0.2.1/` に生成済み。
- Authenticode signing parameters は未設定のため、Setup と配布ファイルは未署名。SmartScreen warning の可能性がある。
- GitHub Release の作成、asset upload、Windows feed の公開 readback は外部書き込みになるため実行していない。
- ChatGPT Pro への設計レビュー送信も外部送信の確認待ちとし、ローカル実装と検証には使用していない。
