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

## 残タスク（Phase 3 以降）

- 設定画面での Automation / Accessibility 権限状態の可視化（未実施）。
- 倍速の MediaRemote フォールバックは adapter 未対応のため現状維持（ブラウザ HTML5 直接制御が第一経路）。
- 楽観的更新 / readback / watchdog の完全削除は adapter 不使用環境のフォールバックとして温存中。
