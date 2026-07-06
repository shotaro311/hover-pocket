---
project_slug: hover-pocket
target: Windows 版 配布前プライバシー・セキュリティレビュー
created: 2026-07-06
updated_by: claude (architect)
status: findings-open
scope_commit: b3ca06f
---

# Windows 版 配布前プライバシー・セキュリティレビュー

レビュー方式: アーキテクト(Claude)によるコードレビュー。対象は `windows/` 配下
(コミット b3ca06f 時点)。攻撃面(OAuth、WebView2、bridge、updater)と
データ面(保存・ログ・秘密情報)を確認した。

## 1. 問題なしと確認した点

| 領域 | 確認結果 |
|---|---|
| OAuth 認可フロー | PKCE(S256)+ `state` の Ordinal 一致検証 + loopback は `127.0.0.1` バインド + 3分タイムアウト。コールバック応答ページは静的 HTML で、攻撃者制御の入力を反射しない(ローカル XSS なし) |
| トークン保存 | refresh token は Credential Manager(CredWrite)のみ。access token はメモリのみ。トークンをファイル・ログ・audit log に書く経路なし |
| 秘密情報の管理 | client_id/secret は `%APPDATA%\HoverPocket\oauth.json` 外部配置でリポジトリに秘密なし(desktop アプリの client_secret は Google の設計上、非機密扱いで許容) |
| Bridge(JS→C#)の攻撃面 | 公開メソッドは typed で、任意ファイルパス・任意コマンド実行のプリミティブなし。外部ドラッグもストア内アイテムの id 参照のみ(JS から任意パスを FileDrop に載せられない) |
| WebView2 コンテンツ | `SetVirtualHostNameToFolderMapping` は `windows/ui` フォルダーのみ、`DenyCors`。リモートコンテンツの読み込みなし |
| 更新の適用同意 | 更新チェック→ダウンロード→適用は Yes/No 確認ダイアログを挟み、勝手に再起動しない |
| 通信先 | Google(accounts.google.com / oauth2.googleapis.com / Calendar API)と GitHub(Releases)のみ。すべて HTTPS。テレメトリ・外部送信なし |

## 2. 指摘事項(配布前に対応を推奨)

### F-1(重要度: 中〜高)配布ビルドで DevTools が有効

- `PanelWindow.cs:315` / `SettingsWindow.cs:56` で `AreDevToolsEnabled = true`。
- 影響: 配布先で F12 相当から bridge メソッドを直接叩ける。ユーザー混乱・
  いたずらの攻撃面になる(リモート攻撃ではないが、配布物として不適切)。
- 対応: `#if DEBUG`(または起動フラグ)でのみ有効化。`AreDefaultContextMenusEnabled`
  も配布ビルドでは無効化。

### F-2(重要度: 中)WebView2 のナビゲーション制限なし

- `NavigationStarting` / `NewWindowRequested` のハンドリングがなく、
  `https://app.hoverpocket.local/` 以外への遷移を防いでいない。
- 影響: 現状のコンテンツは静的で直ちに悪用経路はないが、将来 UI に外部リンクや
  ユーザー由来の HTML(予定の説明文等)が入った場合、外部ページに bridge
  (設定変更・clipboard 読み出し等)が露出するリスクがある。多層防御として必須級。
- 対応: virtual host 以外への遷移をキャンセルし、外部 URL は既定ブラウザで開く。
  `NewWindowRequested` は常に抑止。

### F-3(重要度: 中 / プライバシー)AI lane audit log に予定の実データを保存

- `AiLaneAuditLog` が承認カード(title / start / end / location / notes)を
  平文 JSONL で無期限保存している。
- 要件 R-DATA-002 は「action metadata と結果だけを保存」。予定タイトル・場所・メモは
  個人情報であり、要件との乖離がある。
- 対応(いずれか): フィールドを action 種別・結果・時刻・イベント ID 程度に最小化 /
  保持期限(例 90 日)でローテーション / 保存内容をプライバシーポリシーに明記。
  推奨は「最小化 + ローテーション」。

### F-4(重要度: 低 / プライバシー)ローカル平文保存の明示

- Clipboard 履歴(テキスト・画像)、付箋、audit log は `%APPDATA%` に平文保存。
  ローカル専用アプリとして一般的な設計だが、クリップボードはパスワード等の機密が
  混入しうる(要件も明示を求めている)。
- 現状: Private mode は実装済み(既定 OFF = 要件どおり)。
  「パスワードマネージャー由来のコピーを除外」(要件 Should)は未実装。
- 対応: 配布時の README / プライバシーポリシーに保存場所・消去方法を明記。
  パスワードマネージャー除外(Clipboard の `ExcludeClipboardContentFromMonitorProcessing`
  等の format 尊重)を次フェーズの改善項目にする。DPAPI 暗号化は将来検討。

### F-5(重要度: 低)更新チャネルの真正性が GitHub アカウントに依存

- バイナリ未署名 + Velopack の GitHub Releases フィード。リポジトリ/アカウントが
  乗っ取られると悪意ある更新を配布できてしまう(この構図は Sparkle + 未署名でも同じ)。
- 対応: GitHub アカウントの 2FA 必須(要確認)。一般配布の段階でコード署名
  (または Velopack のパッケージ署名機構)を再検討。SmartScreen 警告の件と合わせて
  README に明記済みであることを維持。

## 3. 対応の推奨順序

1. F-1、F-2: コード修正(小規模。Codex ワーカー 1 タスクで両方)
2. F-3: audit log の最小化 + ローテーション(同上タスクに含められる)
3. F-4、F-5: 配布文書(README / プライバシーポリシー)への明記
   → OAuth 審査ロードマップのプライバシーポリシー作成と同時に行うのが効率的
4. パスワードマネージャー除外・DPAPI・コード署名: 次フェーズの改善バックログ

## 4. 結論

現時点の実装に、**外部から攻撃可能な重大な欠陥は見つからなかった**。
OAuth・トークン管理・bridge 設計は要件どおり堅く作られている。
一方、**配布物としての体裁(F-1 DevTools、F-2 ナビゲーション制限)と
プライバシー整合(F-3 audit log)は配布前に修正すべき**。
F-1〜F-3 を修正すれば、家族・友人への配布に支障のない水準と評価する。
一般配布時は F-4/F-5 の文書化・署名検討を OAuth 審査対応と合わせて行うこと。
