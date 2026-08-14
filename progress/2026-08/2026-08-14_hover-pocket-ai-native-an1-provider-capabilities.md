# HoverPocket AI-native AN1 Provider Capabilities

## 結論

AN0のversioned contractを、macOS / Windows双方で既存Provider Storeへ接続する内部Capability handlerへ実装した。Calendar、Timer、Sticky Notesの10 handlerは同じID・version・typed arguments・readback意味論を持ち、既存UIが使うStore instanceを再利用する。

現時点ではVoice、Text、WebView、MCP、生成Pocket Appからhandlerへ到達する経路を実装していない。AN2でCapability Registry / Broker、approval binding、durable idempotency replay、sanitized receipt、auditを完成させるまでは、外部入力へ公開しない。

## Git / PR

- AN0 PR: [#7](https://github.com/shotaro311/hover-pocket/pull/7)
- AN0 merge commit: `6e248c8fbefbd3c27fb56896aca25f9724291647`
- AN1 branch: `codex/ai-native-an1-provider-capabilities`
- AN1 worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an1`
- AN1 implementation head: `63be1549055922c3536dd051e8338909c879dbad`
- AN1 PR: [#8](https://github.com/shotaro311/hover-pocket/pull/8)（Ready）

## 実装した共通Capability

| Capability | Effect | 実行後確認 |
|---|---|---|
| `calendar.events.list@1` | read | 指定timezoneの今日のeventRef / start / end / safeTitle |
| `calendar.event.get@1` | read | eventRefからevent IDと安全な表示項目を取得 |
| `calendar.event.create@1` | external write | Google create応答のIDを使ったGET readback |
| `timer.countdown.start@1` | local write | 新規timer IDのrunning state |
| `timer.countdown.get@1` | read | timer IDの現在state |
| `timer.countdown.pause@1` | local write | 同一timer IDのpaused state |
| `timer.countdown.resume@1` | local write | 同一timer IDのrunning state |
| `timer.countdown.stop@1` | local write | 同一timer IDのstopped state |
| `sticky.note.upsert@1` | local write | stableKeyに対応するnote ID、title、body、updatedAt |
| `sticky.note.get@1` | read | note IDの保存済みtitle / body / color / updatedAt |

## macOS / Windows共通境界

- handlerはViewを参照せず、OS別composition rootが既存Storeを注入する。
- unknown capability、duplicate registration、型不一致、非object引数、range / length違反をfail closedにする。
- JSON Schema `maxLength`に合わせ、SwiftはUnicode scalar、C#は`Rune`単位で数える。UTF-16 code unit差でWindowsだけ拒否しない。
- 全write handlerは16〜128文字、先頭英数字、残りASCII英数字と`-._:`だけのidempotency keyを必須にする。
- Calendarの明示calendar IDが存在しない、またはread-onlyなら別calendarへfallbackしない。未指定時だけprimary / writableへ解決する。
- Calendar all-dayはrequested day spanを維持する。Windowsのtoday境界は対象timezoneの各midnightから作り、DST日を固定24時間にしない。
- Calendar createはPOST成功だけで完了せず、IDを使ったGET readbackを必須にする。readback完了後の月表示cache refresh失敗は作成失敗へ変換しない。
- Sticky生成noteはstableKeyでatomic upsertし、既存のstableKeyなしnoteと衝突させない。title / bodyを含むreadbackでsilent truncationやcontent lossを検出する。

## Reviewで修正した事項

1. 明示されたread-only / missing calendarから別calendarへfallbackしていた経路をfail closed化。
2. WindowsのDST日境界を`TimeZoneInfo`でmidnightごとに解決。
3. Windows capability経路だけSticky titleをlegacy UIの30文字へ切っていた処理を分離。
4. multi-day all-day eventを1日へ圧縮していたnormalizeを両OSで補正。
5. Sticky mutation readbackをIDだけでなくtitle / body一致へ強化。
6. 書込みidempotency keyの欠落・不正形式を全handlerで拒否。
7. 文字数をSwift grapheme / C# UTF-16ではなく共通のUnicode code point意味論へ統一。
8. Calendarの作成とGET確認後、UI cache refresh失敗をfalse failureとして返して重複retryを誘発する経路を補正。
9. Swift 6で検出された`SystemControlsService`のActor境界をactor-inheriting Taskへ補正。

## ローカル検証

実装head `63be1549055922c3536dd051e8338909c879dbad`で確認した。

```text
swift build
  PASS (Swift 6)

.build/debug/HoverPocket --verify-capabilities
  capability_verify=ok
  capability_handlers=10
  capability_timer_lifecycle=ok
  capability_sticky_upsert=ok
  capability_calendar_readback=ok

.build/debug/HoverPocket --verify-timer
  timer_verify=ok

.build/debug/HoverPocket --verify-clipboard
  clipboard_verify=ok

.build/debug/HoverPocket --verify-calculator
  calculator_verify=ok

.build/debug/HoverPocket --verify-panel-layout
  panel_layout_verify=ok
  panel_layout_cases=112

.build/debug/HoverPocket --verify-media
  media_verify=ok

python3 script/verify_pocket_contracts.py --report-json <report>
  PASS hoverpocket.pocket/v1: schemas=12 fixtures=52 matched=52
  2 runs byte-for-byte identical
  report SHA-256=b11c7a6f4e5e9b6dcfe6ad99e257d33086c7d92a567945f9fdb28b694ce5d0b0

git diff --check
  PASS
```

`--verify-google-calendar`は`Google OAuth client ID is not configured.`で終了した。これはこの隔離worktreeのローカル設定不足であり、外部予定を作成して検証する迂回は行っていない。fake Calendar create / mismatch / timeout、API response decode、CI buildを実施済みだが、実アカウントでのcreate/readbackはAN3の明示承認付きE2E gateとして残る。

## GitHub Actions readback

- [Verify Pocket Contracts run 31790106852](https://github.com/shotaro311/hover-pocket/actions/runs/31790106852): Ubuntu / macOS / Windows verifierとreport byte比較が全成功。
- [Verify Windows run 31790106903](https://github.com/shotaro311/hover-pocket/actions/runs/31790106903): Release build、Capability、既存Windows回帰が成功。
- [Verify macOS Capabilities run 31790106993](https://github.com/shotaro311/hover-pocket/actions/runs/31790106993): Swift 6 build、Capability、Timerが成功。

## Security readback

- Scan ID: `hoverpocket_an1_63be154_20260814T103252Z`
- Exact source range: `6e248c8fbefbd3c27fb56896aca25f9724291647...63be1549055922c3536dd051e8338909c879dbad`
- Snapshot SHA-256: `d6da39ec4464d5c400d431747f118ecb03ab087f16205d9a5d3503b80a9a7674`
- Inventory: 24 source files + supporting contracts / CI
- Coverage: complete
- Reportable findings: 0
- Status: sealed complete
- Token measurement: unavailable in the local prompt-only scan path

## 未実装 / 次gate

- AN2: Capability Registryをruntime正本へ昇格し、Capability Brokerを唯一の実行入口にする。
- AN2: approval request / exact plan binding / TTL、durable idempotency replay、receipt、audit redactionを実装する。
- AN2まではVoice / WebView / MCP / Pocket App /既存AI command laneへhandlerを公開しない。
- AN3: Calendar + TimerのVoice縦断、実アカウントでの書込み前承認とevent ID readbackをWindows実機から確認する。
- 既存UIの全操作を共通Capabilityへ置換するStrangler移行は、Broker導入後に機能単位で進める。
