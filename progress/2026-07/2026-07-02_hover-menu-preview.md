# 2026-07-02 HoverPocket 付箋テキスト操作修正ログ

## 依頼

- 付箋機能で、コピペやクリックによる入力中テキストの確定など、通常のテキスト操作ができない問題を修正する。

## 実施内容

- `StickyNoteEditorCard` の title/body 変更時に毎キー `store.updateNote()` を呼ぶ処理を停止した。
- 付箋外クリック、別付箋への切替、色変更、archive、delete の前に編集中 draft を確定するようにした。
- 編集確定時に `NSApp.keyWindow?.makeFirstResponder(nil)` を呼び、テキスト編集の first responder を外してから保存するようにした。
- 付箋編集開始時に `NSApp.activate(ignoringOtherApps: true)` を呼び、非アクティブな hover panel 上でも標準テキスト編集操作が届きやすい状態にした。
- `AppDelegate` で app main menu に標準 Edit menu を追加し、cut/copy/paste/select all/undo/redo/delete/paste and match style を macOS の responder chain へ流すようにした。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched` を確認。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。

## 配信

- Code commit: `126e05e` (`付箋のテキスト操作を修正`)。
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-85`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-85.zip`
- SHA256: `56da2b0b609af0cd33edea1efae4afbcbf060632359ae38396ec5da4d347362f`
- Notary submission ID: `cb67081a-54d3-44ca-b961-ce6e728b2451`
- Notary status: `Accepted`

## 配信後 readback

- `gh release view v0.1.0-85 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-85.zip`、SHA256、`appcast.xml` の4 asset を確認。
- `curl -fsSL https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `85`、enclosure が `v0.1.0-85/HoverPocket-0.1.0-85.zip` を指すことを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-85.zip | awk -F/ '{print $1}' | sort -u`: top-level が `HoverPocket.app` のみ。
- `shasum -a 256 -c dist/releases/HoverPocket-0.1.0-85.zip.sha256`: 成功。
- `git ls-remote --tags origin v0.1.0-85`: tag が commit `126e05e` を指すことを確認。

## 残リスク

- 自動検証では実際のユーザー操作としての Cmd+C / Cmd+V 入力までは行っていない。修正は macOS の標準 menu/responder chain と SwiftUI text control の更新タイミングに基づく。
- 入力中の内容は、外側クリック、別付箋切替、色変更、archive/delete、または閉じる操作で確定保存される。編集中にプロセスを強制終了した場合の最後の draft 保存は対象外。

---

# 2026-07-02 (2回目): メディア操作改善 + カクつき解消 + タイマー機能追加 (build 88)

## 目的

- メディア再生操作（再生停止、倍速、シーク）のレスポンスを改善し正常動作させる。
- たまに発生する動作のカクつきを解消する。
- シンプルなタイマー機能（4プリセット、ポモドーロ、2本同時、発火時バウンス+波紋+自動オープン）を追加する。

## 実施内容

### メディア操作 (`64c09b7`)

- AppleScript/JXA 実行を同期セマフォから async/await（`OSAScriptRunner`）に置き換え、タイムアウト時は SIGTERM → 500ms 後 SIGKILL で確実に回収。
- ブラウザタブ検出に10秒キャッシュ（`CachedTabContext`）を追加し、毎回の全ブラウザ×全タブ列挙を回避。
- 再生/倍速コマンドにウォッチドッグ（2.5s / 4.0s）を追加し、pending が残り続ける edge case を解消。
- 倍速は操作直後に UI へ楽観的反映。readback ポーリングを短縮（再生 150/350/700ms、倍速 250/500/800ms）。
- `stopPolling` 時に request ID を進め、stale readback の書き戻しを無効化。`refreshNowPlaying` に pending ガード追加。
- OSLog（subsystem `local.codex.hover-pocket` / category `MediaControls`）で失敗・タイムアウト・強制クリアを記録。
- pending インジケータは300ms以上継続時のみ表示（チラつき防止）。

### カクつき解消 (`64c09b7`)

- ScreenCaptureKit: `SCShareableContent` の全ウィンドウ列挙を `SCWindow` キャッシュ（5秒 TTL、失敗時再解決）に変更。0.75秒毎の重い列挙を廃止。
- Clipboard: `save()` を300msデバウンス+バックグラウンド書き込み（書き込み順はタスク連鎖で保証）、画像 PNG 変換/SHA256 も `Task.detached` へ移動。
- DDC 輝度読み取り（I2C）をメインアクター外で実行。ソフトウェア輝度辞書はメインに残し data race を回避。
- ホバー監視 Timer を 0.08s → 0.12s + tolerance 0.04 に調整（判定ロジックは不変更）。各ポーリング Timer に tolerance を設定。

### タイマー機能 (`61170ae`)

- 新規: `TimerModels` / `TimerStore` / `TimerProvider` / `TimerView` / `TimerDurationInputView` / `AdjustmentRailComponents` / `TimerAlertOverlayController`。
- 4プリセット保存（タイトル任意、色4種、音トグル、ポモドーロ切替）。`Application Support/HoverPocket/Timer/` に JSON 保存、再起動復元（超過分は破棄）。
- 2本同時実行、残り時間は endDate ベース計算、`didWakeNotification` でスリープ復帰時即 tick。
- 時間入力は直接入力 + Calendar と同じ調整バー（部品を `AdjustmentRailComponents` に共通化、Calendar は差分のみで挙動不変）。
- 発火時: pill/ミニバーが `TimerAlertBounceModifier` でバウンス（周期0.9s）、`TimerAlertOverlayController`（ignoresMouseEvents の別ウィンドウ）で波紋がバウンスと同位相で下方向に拡散、`openPanel(showing:)` でタイマー画面を自動表示。アラート中はホバー監視の自動クローズを抑止。
- 音は `NSSound(named: "Glass")` を停止までループ。Reduce Motion 時は静的ハイライトのみ。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched` を確認。
- `pgrep osascript`: 残留プロセスなし。

## 配信

- Code commits: `64c09b7` (`メディア操作の応答性とカクつきを改善`)、`61170ae` (`タイマー機能を追加`)。
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-88`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- ZIP: `dist/releases/HoverPocket-0.1.0-88.zip`
- SHA256: `f565d5e64ccb314b25f9bee6438ddbf766dd031dcdd76646cc64794aeec25875`
- Notary submission ID: `6f4b21a6-6875-4d18-8597-310f095eed59`
- Notary status: `Accepted`

## 配信後 readback

- 初回公開時にローカルコミット未 push のまま `gh release create` を実行したため、タグが旧コミット `2363155` を指す不整合が発生。ユーザー承認の上で main を push → リリース削除 → 同一成果物で再作成し解消。
- `git ls-remote --tags origin v0.1.0-88`: tag が commit `61170ae` を指すことを確認。
- `gh release view v0.1.0-88 --json assets`: 4 asset（install ZIP / versioned ZIP / SHA256 / appcast）を確認。
- `curl .../latest/download/appcast.xml`: `sparkle:version` が `88` であることを確認。
- `shasum -a 256 -c`: 成功。`zipinfo -1`: top-level が `HoverPocket.app` のみ。

## 残リスク

- メディア操作の体感改善（YouTube 再生中の連打等）は実機での手動確認が必要。OSLog `MediaControls` カテゴリで失敗経路を追跡可能。
- タイマー発火演出（バウンス/波紋/自動オープン）は自動検証対象外。実機でプリセット開始 → 発火 → 停止の一連を確認するのが望ましい。
- 配信手順の学び: `publish_github_release.sh` はリモート HEAD にタグを作るため、**公開前に必ずコミットを push する**こと。

---

# 2026-07-02 (3回目): タイマーUIのピン留め方式への変更と発火演出調整 (build 90)

## 目的

- タイマーUIをユーザーフィードバックに沿って変更: 下部は「タイマー」「ポモドーロタイマー」の2カードのみとし、実行中タイマーの右上ピン留めで最大4つまでストックできる方式にする。
- 波紋アニメーションを削除し、バーのバウンスを「上端から下へぴょこぴょこ顔を出す」自然な動きにする。

## 実施内容 (`1ab6787`)

- `TimerStore`: 固定4プリセットを廃止し、`draftTimer` / `draftPomodoro`（2つの入力カード、drafts.json 保存）+ `pinnedPresets`（最大4、pinned.json 保存）に再構成。
- `RunningTimer` に `pinnedPresetID` を追加し、実行中カードのピン状態を反映。`togglePin` / `removePinnedPreset` を追加。
- `TimerView`: セクション構成を「実行中 → ピン留め → タイマー → ポモドーロタイマー」に変更。実行中カード右上に pin/pin.fill トグル、ピン留め行に再開始 + ピン解除ボタン。
- `TimerAlertOverlayController`（波紋）を削除し、`HoverWindowController` の購読はパネル自動オープンのみに簡素化。
- `TimerAlertBounceModifier`: オフセットを常に0以下（-4pt→0→-4pt）にし、バーが上端に接したまま下へ顔を出す動きに変更。切り離れて見える問題を解消。

## 検証

- `swift build` / `git diff --check` / `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched` を確認。

## 配信

- Code commit: `1ab6787`（配信前に push 済み。タグ整合の教訓を反映）
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-90`
- ZIP: `dist/releases/HoverPocket-0.1.0-90.zip`
- SHA256: `97d78300df694400e0cd1d18de96722ad29a685c63ab017923954252b8638dda`
- Notary submission ID: `700fc5d1-2326-4279-87c9-ec36b5bd1b32`
- Notary status: `Accepted`

## 配信後 readback

- `git ls-remote --tags origin v0.1.0-90`: tag が commit `1ab6787` を指すことを確認。
- `gh release view v0.1.0-90 --json assets`: 4 asset を確認。
- appcast: `sparkle:version` = `90` を確認。`shasum -c`: OK。`zipinfo`: top-level は `HoverPocket.app` のみ。

## 残リスク

- ピン留めUX（右上マークの視認性、ピン→再開始の導線）とバウンスの見た目は実機での体感確認が必要。
