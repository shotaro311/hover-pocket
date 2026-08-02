---
project_slug: hover-menu-preview
date: 2026-08-02
status: implemented; released; installed; verified
---

# Windows Calendar time zone error fix

## 症状

Windows版HoverPocketでGoogle Calendarの予定を編集すると、`Invalid time zone definition for start time.` と表示されて保存できなかった。予定作成も同じrequest builderを使うため、同じ問題の対象だった。

## 原因

`GoogleCalendarApiClient`が、Google Calendar APIの`events.list.timeZone`と予定書き込みbodyの`start.timeZone` / `end.timeZone`へ`TimeZoneInfo.Local.Id`をそのまま渡していた。Windowsでは本端末の値が`Tokyo Standard Time`になる一方、Google Calendar APIが受け付けるのは`Asia/Tokyo`のようなIANA Time Zone Database名である。

## 修正

- `TimeZoneInfo.HasIanaId`と`TimeZoneInfo.TryConvertWindowsIdToIanaId`を使い、Google APIへ渡す前にIANA形式へ正規化する。
- 変換不能時は`timeZone`を省略する。書き込み日時は既存どおりoffsetを含むRFC3339値のため、不正なtime zoneを送らずにAPIへ時刻を伝えられる。
- 予定一覧query、予定作成、予定編集のすべてへ同じ正規化を適用する。
- `CalendarVerifier`へWindowsの`Tokyo Standard Time`→`Asia/Tokyo`変換、変換不能時の省略、予定一覧query、書き込みbodyのstart/endを検査する回帰ケースを追加する。

## 検証

- `dotnet build .\windows\HoverPocket.Windows.sln -c Debug --no-restore --nologo`: exit 0、warnings 0、errors 0。
- Debug `HoverPocket.Shell.exe --verify calendar`: exit 0、`PASS calendar verify`。
- `dotnet build .\windows\HoverPocket.Windows.sln -c Release --no-restore --nologo`: exit 0、warnings 0、errors 0。
- Release `HoverPocket.Shell.exe --verify calendar`: exit 0、`PASS calendar verify`。
- Debug `HoverPocket.Shell.exe --verify calendar-live`: exit 0、Calendar 6件 / event 65件、`PASS calendar-live verify`。予定内容は出力せず、作成・編集・削除も行っていない。
- `git diff --check`: exit 0。CRLF正規化warningのみ。
- 実行中のインストール版0.2.3を対象pathと1 processであることを確認して終了し、修正版Debug 0.2.4を起動した。起動後は期待Debug pathの1 process、`Responding=True`をreadbackした。インストール内容とショートカットは変更していない。
- 配布承認後にWindows版を0.2.5へ版上げした。Debug / Releaseの全13 verifierとWindows UI JavaScript 12ファイルの構文検査はすべてexit 0。
- `win-v0.2.5`をsource target `12771730b82a103bdea050c7a4e3e143a7d25a57`、`latest=false`で公開し、8 assetのGitHub API digest、匿名公開URL、Windows feed、公式サイトのSetup導線をreadbackした。
- このPCのインストール済み0.2.3をVelopackで0.2.5へ更新した。ARP両view、root / current exe、通常起動processが0.2.5を示し、インストール済み実体の`calendar`、`ui`、`calendar-live` verifierがexit 0。詳細: `progress/2026-08/2026-08-02_hover-pocket-windows-0.2.5-release.md`。

## 境界

- 実予定の更新はGoogle Calendarへの外部書き込みになるため未実施。
- 実予定の書き込みを除く修正、配布、公開導線、ローカル更新、起動確認は完了した。
