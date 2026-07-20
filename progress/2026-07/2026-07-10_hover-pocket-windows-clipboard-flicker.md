---
project_slug: hover-menu-preview
date: 2026-07-10
actor: codex
scope: windows-clipboard-flicker
---

# Windows Clipboard flicker fix

## Cause

- `app.js` は `state.changed` と `panel.opened` のたびに選択中providerをunmountし、provider containerを空にしてから作り直していた。
- Clipboard rendererも状態取得のたびにroot DOMを`replaceChildren()`していた。
- 共通CSSのprovider登場animationが新しいroot要素ごとに再発火し、Clipboardでは `空表示 -> state取得 -> root再作成 -> fade-in` が重なってちらつきとして見えていた。
- 選択済みproviderのアイコンを再度押した時も不要な`provider.select`をbridgeへ送っていた。

## Fix

- provider idと言語が変わらないstate更新ではprovider DOMを再mountしない。
- provider登場animationは子要素ではなくprovider container自身に付け、実際にproviderが切り替わった時だけ再開する。
- Clipboardは前回stateを即時表示し、同じstate signatureのrefreshではDOMを置換しない。
- Clipboardのpanel-open refreshは重複中なら同じPromiseへ合流し、scroll位置もrender前後で維持する。
- 選択済みproviderの再選択はUI側でno-opにした。
- Controls / Clipboard rendererへ`refresh` / `dispose` lifecycleを追加し、panel openと手動refreshで全providerを作り直さないようにした。

## Verification

- `node --check`: `app.js`、`clipboard.js`、`controls.js` はexit code 0。
- Debug build: warnings 0、errors 0。
- Debug `--verify ui`: 10回連続exit code 0。毎回 `clipboard stable refresh` を確認。
- Debug `--verify clipboard`: exit code 0。
- Debug `--verify shell`: open/close 25 cycle、20前後の描画frame、window count不変。
- Release `--verify ui`: 5回連続exit code 0。
- Release `--verify clipboard`: exit code 0。
- Release `--verify shell`: open/close 25 cycle、20 frames、最大frame gap 20.1ms、window count不変。
- WebView2 verify timeout時に最後のstepを返す診断を追加し、検証項目増加に合わせて上限を18秒へ拡張した。

## Distribution boundary

- `dist/windows/releases/0.2.1/` を最終修正版で再生成した。
- Setup SHA256: `A67B972C7F53E28045362A0A04AA43853B815492B3840BE36145924B2332FD8C`。
- Portable ZIP SHA256: `451FFC96A5CB9389F62639346A77FCCF488411355C1DF5E6FE3712A6EECD5D6C`。
- Authenticode未署名。GitHub Release作成・upload・pushは未実施。
- Browser pluginはこのWebView2 virtual-host appを対象にできないため、アプリ内WebView2 verifierを使用した。
