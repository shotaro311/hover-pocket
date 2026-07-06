---
project_slug: hover-pocket
target: Windows OAuth review prep W13
created: 2026-07-06
updated_by: codex
status: completed
---

# 2026-07-06 Windows OAuth W13

## 実装内容

- `GoogleOAuthConfiguration.Load()` の解決順序を、ビルド時埋め込み値、`%APPDATA%\HoverPocket\oauth.json`、`null` の順に変更した。
- `HoverPocket.Shell.csproj` に空既定の MSBuild プロパティ `GoogleOAuthClientId` / `GoogleOAuthClientSecret` を追加し、値が渡された場合だけ `AssemblyMetadata` として埋め込むようにした。実 client_id / secret はソースに置いていない。
- `windows/script/publish_release.ps1` が `HOVERPOCKET_GOOGLE_CLIENT_ID` / `HOVERPOCKET_GOOGLE_CLIENT_SECRET` を読み、`dotnet publish` に `-p:` で渡すようにした。スクリプトは値を表示しない。
- `.gitignore` に `bin/` / `obj/` / secret 系 JSON を追記し、MSBuild 生成物とローカル OAuth 秘密ファイルを追跡対象から外した。
- `--verify calendar` に、埋め込み値優先、`oauth.json` フォールバック、未設定時 `null` の経路検査を追加した。検査値は dummy のみ。

## スコープ最小化

- Google 公式 CalendarList.list ドキュメントでは、CalendarList 一覧取得に `calendar.readonly` / `calendar` / `calendar.calendarlist` / `calendar.calendarlist.readonly` のいずれかが必要で、`calendar.events` は含まれていない。
  - 公式: https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list
- Google 公式 Events list / insert / patch / delete ドキュメントでは、予定の読み書きに `calendar.events` が許可 scope として含まれている。
  - list: https://developers.google.com/workspace/calendar/api/v3/reference/events/list
  - insert: https://developers.google.com/workspace/calendar/api/v3/reference/events/insert
  - patch: https://developers.google.com/workspace/calendar/api/v3/reference/events/patch
  - delete: https://developers.google.com/workspace/calendar/api/v3/reference/events/delete
- 判定: requirements 4.3 の複数カレンダー選択・対象カレンダー指定には CalendarList.list が必要なため、`calendar.events` だけにはできない。ただし広い `calendar.readonly` は外し、要求 scope を `calendar.events` + `calendar.calendarlist.readonly` に最小化した。既存の旧 `calendar.readonly` 付き保存済み token は、Google API 上は CalendarList.list を許可できるため互換的に受け入れる。

## 検証結果

- `dotnet build windows\HoverPocket.Windows.sln --nologo -p:NuGetAudit=false`: exit 0、警告 0、エラー 0。
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -p:NuGetAudit=false -- --verify calendar`: exit 0。
- `dotnet run --project windows\src\HoverPocket.Shell\HoverPocket.Shell.csproj -p:NuGetAudit=false -- --verify ui-model`: exit 0。
- dummy の `GoogleOAuthClientId` / `GoogleOAuthClientSecret` を MSBuild プロパティで渡した `--verify calendar`: exit 0。埋め込みありなら `oauth.json` 不要の経路を確認した。
- dummy 埋め込み検証後に通常プロパティで再ビルドし、最終ビルドを空既定へ戻した。再ビルドも exit 0、警告 0、エラー 0。
- `git diff --check`: exit 0。
- `rg --hidden --no-ignore` で dummy 値の残存を確認し、残っているのは verifier ソース内の dummy 検査値だけだった。実値は未使用。

## 未実行・引き継ぎ

- WebView2 実行系の `--verify ui` は、アーキテクトの通常 desktop session 実行待ち。今回の W13 では実行していない。
