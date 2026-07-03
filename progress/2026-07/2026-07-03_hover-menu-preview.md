# 2026-07-03: メディア操作不能の根本原因特定と mediaremote-adapter 導入（Phase 1）

## 目的

- 何度修正しても直らなかったメディア再生操作（再生/停止・シーク）の根本原因を特定する。
- 0 から設計する視点でアーキテクチャを見直し、Phase 1（コマンド経路の復旧）を実装する。

## 根本原因

- macOS 15.4 以降、`com.apple.mediaremote.send-commands` エンタイトルメントのない第三者バイナリからは MediaRemote 私有 API が無音で失敗する（実機 macOS 26.5.1 で実証）。
- 同一コードが Apple 署名の `swift` インタプリタでは Now Playing を取得でき、`swiftc` ビルドの単体バイナリでは nil。
- アプリ内から直接呼んでいた `MRMediaRemoteSendCommand`（再生/停止・シーク・倍速）は一度も効いていなかった。UI 層の修正では直らない問題だった。
- 既存の `--verify-media` は読み取り（JXA 経由で成功する）しか検証せず、壊れたコマンド経路が配信前チェックをすり抜けていた。

詳細: `docs/plan/20260703-media-controls-root-cause-and-redesign.md`

## 実施内容（Phase 1）

- SwiftPM 依存に `ejbills/mediaremote-adapter`（MIT、revision 固定）を追加。
- `MediaRemoteAdapterClient` を新設。Apple 署名の `/usr/bin/perl` に同梱 dylib をロードさせ、`toggle_play_pause` / `set_time` を中継する。
- `MediaRemoteService.togglePlayPause` / `setElapsedTime` を adapter 優先（レガシー直呼びはフォールバック）に差し替え、async 化。
- `build_and_run.sh` で `libMediaRemoteAdapter.dylib` を `Contents/Frameworks/`、`run.pl` を `Contents/Resources/mediaremote-adapter.pl` として同梱。
- `MediaVerificationCommand` に `--toggle-playback` を追加。再生状態が実際に反転することを確認してから元へ戻す。読み取り成功だけで ok にしない。

## 検証

- 署名済み `dist/HoverPocket.app` の実行ファイルで `--verify-media --toggle-playback` を実行し、`media_toggle_verified=true` / `media_verify=ok` を確認（Spotify 再生中、toggle → 反転確認 → 復元）。
- 検証は必ず署名済みバンドルで行うこと。debug 実行（`swift` 経由）では署名条件が異なり、壊れていても動いて見える。

## 実施内容（Phase 2）

- `MediaRemoteAdapterClient` に loop ストリーム購読（JSONL、diff マージ、自動再起動）と one-shot `get` を追加。
- Controls パネル表示中は Now Playing 変更通知でイベント駆動更新。2 秒ポーリングの media 読み取りと JXA spawn は adapter 不使用環境のフォールバックへ降格（ディスプレイ/音量のポーリングは継続）。
- ストリーム有効時の play/pause は readback リトライ / watchdog を使わず、イベントを状態の真実として扱う。
- 再生位置はイベント間をローカル外挿（elapsed + Δt × rate）で補間。シーク直後は外挿基準も更新して巻き戻りを防止。
- one-shot `get` の大出力（アートワーク base64）でパイプが詰まる問題を逐次読み出しで修正。`media_has_artwork=true` を確認。
- `MediaRemoteService.nowPlaying()` の第一読み取り経路を adapter `get` に変更（JXA → MediaRemote → browser はフォールバック）。

## 配信

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-94`（notarization Accepted、`libMediaRemoteAdapter.dylib` 同梱を検証済み）
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- notarize 済み本番ビルド（hardened runtime）で `--verify-media --toggle-playback` を実行し、`media_toggle_verified=true` / `media_has_artwork=true` / `media_verify=ok` を確認。

## 残タスク（Phase 3 以降）

- 設定画面での Automation / Accessibility 権限状態の可視化（未実施）。
- 倍速の MediaRemote フォールバックは adapter 未対応のため現状維持（ブラウザ HTML5 直接制御が第一経路）。
- 楽観的更新 / readback / watchdog の完全削除は adapter 不使用環境のフォールバックとして温存中。

---

# 2026-07-03: パネルサイズ拡大とホバーパネル文字サイズ設定

## 実施内容

- `PanelLayout.previewSize(for:)` の raw value 対応は維持したまま、`small=520x372`、`medium=600x430`、`large=680x488` へ拡大した。
- `PanelTextSizeOption` と `panelTextSize` 設定を追加し、既定値は現状相当の `small` にした。
- Settings の `パネル` セクションに `文字サイズ` picker を追加した。
- `PanelTextStyle` helper を追加し、`HoverPanelShell` から provider 本体と AI command lane にだけ文字サイズ環境値を渡すようにした。
- 主要 provider の可読テキストへ `panelTextFont(...)` を適用した。対象は Google Calendar、Clipboard、Controls、Sticky Notes、Timer、Calculator、AI command lane。Provider header、Plugin host の空状態、純粋なアイコンは対象外。
- `CalculatorProvider` を追加し、ProviderRegistry に日本語 title `電卓` として登録した。
- Calculator は四則演算、小数、符号反転、パーセント、バックスペース、AC、コピー、キーボード入力、0 除算時の `Error` 表示に対応した。

## 検証

- `swift build` 成功。
- `.build/debug/HoverPocket --verify-calculator` 成功（`calculator_verify=ok`, `display=25`）。
- `.build/debug/HoverPocket --verify-calculator --calculator-sequence '7/0='` 成功（`display=Error`）。
- `git diff --check` 成功。
- `./script/build_and_run.sh --verify` 成功（`HoverPocket launched`）。

## 補足

- Calendar 専用の日時入力コンポーネント、Mirror、細かい tooltip/help 文言は今回の安全適用範囲から外した。主要 provider の本文・見出し・状態文を優先したため。

## 配信（build 96）

- コミット `af86e29` を build `96` として配信した。
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-96`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Notary submission ID: `e6e801d1-7a43-4d98-8b99-3804482bd322`
- Notary status: `Accepted`
- 公開 ZIP SHA256: `179917a6294b91cae94471fc97c8b6fae8d4d0d07247f78664c22a7106ad08e9`
- GitHub Release asset の digest がローカル ZIP SHA256 と一致することを確認した。
- latest appcast が `<sparkle:version>96</sparkle:version>` と `v0.1.0-96/HoverPocket-0.1.0-96.zip` を指すことを確認した。
- 公開 ZIP の top-level は `HoverPocket.app` のみ。展開後 app の `codesign --verify --deep --strict`、`xcrun stapler validate`、`spctl --assess --type execute` はすべて成功し、Gatekeeper は `source=Notarized Developer ID` と判定した。
