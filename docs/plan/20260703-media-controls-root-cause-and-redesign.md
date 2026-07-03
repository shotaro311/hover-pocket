# メディア操作が機能しない問題の根本原因調査と再設計プラン

作成日: 2026-07-03
対象: `Sources/HoverPocket/Services/SystemControlsService.swift`（ControlsStore / MediaRemoteService / JXANowPlayingService / BrowserNowPlayingService）

## 結論（TL;DR)

**再生/停止・シークが効かないのはバグではなく、macOS 15.4 以降の OS 側の仕様変更が原因。**
アプリ本体（Developer ID 署名の第三者バイナリ）から呼んでいる `MRMediaRemoteSendCommand` / `MRMediaRemoteSetElapsedTime` は、`com.apple.mediaremote.send-commands` エンタイトルメントがないため **すべて無音で失敗** する。この経路の上に楽観的 UI 更新・readback・watchdog を何層も重ねてきたため、「押すと一瞬変わって元に戻る」「たまに固まる」という症状になり、UI 側をいくら修正しても直らなかった。

修正には小手先の変更ではなく、**メディア制御経路のアーキテクチャ変更（entitled proxy + イベント駆動化）が必要**。

## 実機での検証結果（2026-07-03, macOS 26.5.1）

同一の MediaRemote 呼び出しコードを 2 通りで実行して比較した。

| 実行方法 | 署名の立場 | `MRMediaRemoteGetNowPlayingInfo` の結果 |
|---|---|---|
| `swift mrtest.swift`（Apple 署名の swift インタプリタ） | Apple platform binary | **18 キーの辞書が返る**（再生中の "Pluto" を取得） |
| `swiftc` でビルドした単体バイナリ（= HoverPocket.app と同じ立場） | 第三者バイナリ | **nil** |

- JXA（`osascript` = Apple 署名）経由の `MRNowPlayingRequest` 読み取りは成功する。現在アプリの「曲名表示だけは動く」のはこのフォールバックのおかげ。
- 送信系（`MRMediaRemoteSendCommand`）も同じエンタイトルメントゲートの対象。アプリ内から直接呼んでいる以下はすべて no-op になる:
  - `togglePlayPause()` → command 2
  - `setElapsedTime()` → `MRMediaRemoteSetElapsedTime` + command 24（シーク）
  - `setPlaybackSpeed()` の MediaRemote フォールバック → command 19

## 現行アーキテクチャの問題点（症状との対応）

1. **コマンド送信が全滅**（上記）。→「再生停止・シーク・倍速が効かない」
2. **楽観的 UI + readback + watchdog の三重構造**: `togglePlayback()` は UI を先に反転し、実コマンドは失敗し、150/350/700ms 後の readback が実状態（変化なし）を返して UI が巻き戻る。倍速側は 4 秒 watchdog まである。→「一瞬反応して戻る」「pending で固まる」
3. **読み取り経路が重い**: 2 秒ごとのポーリングで毎回 `osascript` プロセスを spawn（JXA + 条件次第でブラウザ AppleScript を複数、各 0.8〜2s タイムアウト、SIGTERM/SIGKILL 管理）。→「カクつき」「応答遅延」
4. **ブラウザ JS 経路の環境前提**: Chrome/Safari の `execute javascript` / `do JavaScript` は「Apple Events からの JavaScript を許可」を開発者メニューで有効にしないと動かない。無効なら倍速の HTML5 直接制御は静かに失敗し、キーボードショートカット送信（Accessibility 権限前提 + タブ前面化の副作用）へ落ちる。→「環境により倍速だけ動いたり動かなかったりする」
5. **検証の盲点**: `MediaVerificationCommand` は now-playing の読み取りと倍速のみ検証し、**play/pause・シークのコマンド送信を一度も検証していない**。読み取りは JXA で成功するため「media_verify=ok」が出て、壊れているコマンド経路が配信前チェックをすり抜け続けた。

## 0 から設計する場合のアーキテクチャ（推奨案）

方針: 「**entitled proxy 経由の単一メディア制御チャネル + イベント駆動**」

```
┌─────────────────────────────┐
│ HoverPocket.app             │
│  MediaControllerActor(単一) │←─ JSONL stream ─┐
│  （状態の唯一の真実）        │                  │
└──────────┬──────────────────┘                  │
           │ コマンド(1発)                        │ now-playing 変更通知
           ▼                                     │ (push, ポーリング廃止)
┌─────────────────────────────────────────────┐  │
│ 長寿命ヘルパープロセス (Apple署名バイナリに   │──┘
│ アダプタ framework をロードさせる方式)        │
│  - MRMediaRemoteRegisterForNowPlaying...     │
│  - MRMediaRemoteSendCommand (再生/停止/seek) │
└─────────────────────────────────────────────┘
補助レイヤー（降格）:
  - ブラウザ AppleScript: URL/タブ特定・プレビュー・HTML5 playbackRate の enrichment のみ
  - HID メディアキーイベント: play/pause の最終フォールバック
```

### 具体案: mediaremote-adapter 方式の採用

[ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter)（MIT、DockDoor 等が採用）は、Apple 署名の `/usr/bin/perl` に小さなアダプタ framework をロードさせることでエンタイトルメントゲートを回避する実績あるアプローチ。

- **get**: ストリームモードで now-playing 変更を push 通知として受け取れる → 2 秒ポーリングと毎回の osascript spawn を全廃
- **send**: play/pause・シーク・倍速コマンドが entitled コンテキストから送信され、**実際に効く**
- 導入形態: framework を同梱し、ヘルパーを `Process` で 1 本だけ常駐起動（Controls パネル表示中のみでも可）

### 状態管理の再設計

- `ControlsStore` の media 部分を `MediaControllerActor` に一本化。
- **楽観的更新・readback リトライ・watchdog・requestID・pending フラグ群をすべて削除**。コマンド送信 → ヘルパーからの変更通知（数十 ms〜）で状態確定、という単方向フローにする。イベントが来るので楽観更新そのものが不要になる。
- 倍速は (1) adapter 経由 command 19、(2) ブラウザ HTML5 `playbackRate` 直接制御、の 2 経路に整理。キーボードショートカット送信（フォーカス奪取）経路は削除。

### 代替案との比較

| 案 | 内容 | 長所 | 短所 |
|---|---|---|---|
| **A. mediaremote-adapter 統合（推奨）** | 実績ある entitled proxy + push 通知 | 全操作が復活、ポーリング全廃、実装量最小 | 私有 API 依存は継続（現状と同等）、perl ヘルパー常駐 |
| B. 同等 proxy を自前実装 | JXA/独自 framework で自作 | 外部依存なし | 実装・保守コスト大。A と同じものを作るだけ |
| C. MediaRemote を捨てる | HID メディアキー + ブラウザ AppleScript のみ | 私有 API 依存ゼロ | シーク・進捗表示・対象アプリ特定が不可能に。機能大幅縮小 |

- 私有 API 依存リスクは現状と同じ（今も MediaRemote + JXA に依存）。A はむしろ依存箇所が 1 プロセスに隔離され、壊れた時の切り分けが容易になる。
- App Store 配布は不可だが、現在も Developer ID + notarization 配布なので影響なし。notarization は private entitlement を付けるわけではない（Apple 署名バイナリへの委譲）ため通る想定。DockDoor 等で実績あり。

## フェーズ計画

### Phase 1: コマンド経路の復旧（効果最大・最優先）— ✅ 2026-07-03 実装完了

実装結果: SwiftPM 依存として adapter を追加し、`MediaRemoteAdapterClient` 経由で toggle/seek を送信。署名済みバンドルでの `--verify-media --toggle-playback` で `media_toggle_verified=true` を確認済み。詳細は `progress/2026-07/2026-07-03_hover-menu-preview.md`。

元の計画:
1. mediaremote-adapter（framework + perl ヘルパー）を `Resources/` に同梱し、起動・監視する `MediaRemoteAdapterClient` を新設
2. `togglePlayPause` / `setElapsedTime` / MediaRemote 倍速を adapter 経由に差し替え
3. `MediaVerificationCommand` に **play/pause トグルの実効検証**（toggle → 状態変化を readback）を追加。「読めるだけで ok」を廃止
4. 配信前チェックリストに実機での再生/停止・シーク確認を明記

### Phase 2: イベント駆動化と状態管理の簡素化
1. adapter のストリームモード購読に切り替え、2 秒ポーリング・JXA spawn を廃止（JXA は adapter 死活時のフォールバックとして温存）
2. 楽観的更新 / readback / watchdog / pending フラグ群を削除し、単方向フローへ
3. ブラウザ AppleScript を enrichment（URL・プレビュー用 windowID・倍速 HTML5 制御）専用に降格。ショートカット送信経路を削除

### Phase 3: 仕上げ
1. Automation / Accessibility 権限の状態を設定画面に可視化（静かな失敗をなくす）
2. OSLog `MediaControls` にヘルパー死活・コマンド結果を集約
3. README / docs/requirement 更新、進捗ログ記録

## 検証方法

- `HoverPocket --verify-media --toggle-playback`（新設）で: 再生中メディアの取得 → toggle → isPlaying 反転確認 → 復元
- 配信ビルド（Developer ID 署名後の .app）で検証すること。**debug バイナリや `swift run` では署名条件が異なり結果が変わる**（今回の見逃しの一因）

## 参考

- macOS 15.4 以降、MediaRemote の主要関数は `com.apple.mediaremote.send-commands` エンタイトルメント必須（サードパーティアプリでは取得不可）。media-control / DockDoor / folivora(BTT) 等の既存アプリが同問題に遭遇し、adapter 方式へ移行済み
- 検証スクリプト: scratchpad の `mrtest.swift`（swift 実行 vs swiftc ビルドで結果が変わることを確認済み）
