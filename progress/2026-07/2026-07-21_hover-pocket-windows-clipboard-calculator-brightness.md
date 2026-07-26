---
project_slug: hover-pocket
date: 2026-07-21
area: windows-clipboard-calculator-controls
status: completed-local
---

# Windows Clipboard / Calculator / Brightness Follow-up

## 依頼

- Clipboardの外部ドラッグボタンを個別削除へ変更し、通常/お気に入りタブ、中央split view、解像度非表示、画像/テキスト全体プレビューを整える。
- Calculatorの履歴をmacOS版と同じサイドバーにする。
- DDC/CI輝度の連続操作時に出る`Brightness command failed`を修正する。

## 実装

### Clipboard

- 既定表示を「すべて」、切替先を「お気に入り」とする2タブに変更した。両タブともテキストと画像を同時表示し、CSS gridを`1fr 1px 1fr`としてdividerを中央へ固定した。
- 外部ドラッグUIを削除し、通常項目・お気に入り項目・全体プレビューのすべてに赤いSVGゴミ箱を配置した。既存の`clipboard.deleteItem`を使うため、画像削除時は履歴metadataとPNG実体を同時に削除する。
- 画像カードと全体プレビューから解像度を削除した。画像はパネルの残り領域へ`object-fit: contain`で全体表示し、テキストは選択可能な`overflow: auto`表示にした。
- paneごとのscroll位置をキー別に保存し、状態更新時にテキスト/画像双方の位置を復元する。
- 要件書、provider説明、READMEの検証説明を今回のUIへ同期した。nativeの外部ドラッグ実装は互換性のため残すが、通常UIからは呼ばない。

### Calculator

- macOS `CalculatorView`の構成に合わせ、履歴がある時だけ左に154px（compact時124px）のサイドバーを表示する。
- 上部のsidebarボタンで開閉でき、履歴件数、全消去、結果の再利用、式の復元を維持した。履歴は最新を上に表示する。
- WebView2 verifierは`7+5=12`を作り、sidebarの左右配置、領域内収まり、開閉を確認する。

### Brightness

- Microsoft Learnでは`SetMonitorBrightness`と`SetVCPFeature`が約50msかかり、DDC/CIはモニター実装差があると明記されている。60ms間隔で次値を即送信していた経路を、JavaScript 110ms、native 100msの最小間隔へ変更した。
- DDC書き込み失敗時は55ms待ってVCPを1回再試行する。それでも失敗した場合だけ対象HMONITORのphysical handleを開き直し、raw範囲と利用APIを再読込してから最後の1回を送る。
- 成功時は従来どおり保持済みendpointへ直接writeし、display再列挙、音量/メディア再取得、全display readbackを行わない。
- 英語の`Brightness command failed for N%.`を日本語化し、display listの横overflowとrangeのbox sizingを修正した。

## 検証

- `node --check`
  - `windows/ui/providers/clipboard/clipboard.js`
  - `windows/ui/providers/calculator/calculator.js`
  - `windows/ui/providers/controls/controls.js`
  - `windows/ui/js/app.js`
  - すべてexit 0。
- `dotnet build windows/src/HoverPocket.Shell/HoverPocket.Shell.csproj -c Debug --nologo -p:NuGetAudit=false`
  - 成功。warnings 0 / errors 0。
- Debug verifier
  - `--verify clipboard`: explicit text/image/PNG deleteを含めexit 0。
  - `--verify calc`: arithmetic、JIS記号、履歴value/restore/clearを含めexit 0。
  - `--verify ui-model`: exit 0。
  - `--verify controls`: detection race/cache、音量readback、brightness検出を含めexit 0。
  - `--verify ui`: Clipboard 2タブ/中央split/ゴミ箱/解像度なし/全体preview、Calculator sidebar、既存provider回帰を含めexit 0。
- 実機brightness
  - `Generic PnP Monitor`、開始85%。
  - 85→77→69を連続writeし、所要169.3ms、69%のfresh readback成功。
  - finallyで85%へ復元し、fresh readback成功。
- 実画面readback
  - Clipboardの2タブ、中央divider、全項目のゴミ箱、解像度なし、保存画像の全体previewを確認した。
  - Calculatorで`7+5=12`を入力し、左履歴sidebar、履歴件数、trash、restore、main keypadの領域内収まりを確認した。

## 境界

- Browserプラグインは通常URLを持つブラウザ面向けで、対象はWPF内のprocess-local WebView2 virtual hostのため使用しなかった。代わりにアプリ内WebView2 verifierと通常起動GUIのreadbackを使用した。
- release artifact、署名、公開、commit、pushは実施していない。
