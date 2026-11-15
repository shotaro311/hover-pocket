# ホバーポケット（HoverPocket）

## 目的

画面上端へマウスを重ねると開く常駐パネルから、ディスプレイ・音量・メディアの操作、Google Calendar、クリップボード履歴、付箋、タイマー、電卓、素材ライブラリ、Codexとのチャットをすぐ使えるmacOS / Windowsアプリ。macOS版にはカメラのミラーもある。Windows版はミラーとマイク確認を対象外とする。

## 構成

| 場所 | 内容 |
|---|---|
| `Sources/HoverPocket/`、`Package.swift`、`Resources/` | macOSアプリ（Swift、macOS 14以上） |
| `windows/` | Windowsアプリ。`HoverPocket.Windows.sln`、WPFの常駐シェル `src/HoverPocket.Shell`、素材ライブラリ `src/HoverPocket.Assets`、Codex隔離環境の導入 `src/HoverPocket.CodexSandboxSetup`、WebView2の画面 `ui/`、テスト `tests/` |
| `shared/asset-library/` | 両OS共通の素材ライブラリの保存契約と同期形式 |
| `shared/pairing-helper/` | 端末をコードで接続する補助プログラム（Rust） |
| `contracts/` | 両OS共通のデータ契約（`pocket`、`personal-tools`、`voice`） |
| `script/`、`windows/script/` | macOS / Windowsの検証・配布スクリプト |
| `site/` | 公開サイトとプライバシーポリシー |
| `docs/` | 要件 `requirement/`、計画 `plan/`、報告 `report/`、使い方 `usage/`、設計判断 `adr/` |
| `progress/` | 進捗。入口は `progress/progress.md` |

## 利用・開発の入口

- 作業前に [AGENTS.md](AGENTS.md) の必読資料（[進捗](progress/progress.md)と[要件](docs/requirement/requirements.md)）を読む。
- macOS: `./script/build_and_run.sh --verify`。詳細は [README.md](README.md)。
- Windows: `dotnet build .\windows\HoverPocket.Windows.sln`。検証は `HoverPocket.Shell` の `--verify <名前>`。詳細は [windows/README.md](windows/README.md)。
- 配信: macOSは `macos-latest` とversioned releaseのSparkle appcast、Windowsは `win-v*` releaseとVelopackの `win` channel。GitHubの `latest` は両OSで共有しない。

## 使う外部サービス

- GitHub: リポジトリ、Releasesでの配信、ActionsでのCI。
- Apple Developer ID署名と公証: macOS版の配布。
- Google Calendar API（OAuth）: カレンダー。
- Open-Meteo: 天気予報。
- Syncthingと公開中継 `mailbox.mw.leastauthority.com`（magic-wormhole）: 素材ライブラリの端末間同期とコード接続。
- Codex（ChatGPTアカウントでのログイン）: パネル内チャットと自作ツールの生成。
- 公開サイトの配信設定: `wrangler.jsonc`（Cloudflare）と `.github/workflows/pages.yml`。
