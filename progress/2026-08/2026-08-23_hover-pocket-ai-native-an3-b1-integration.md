# 2026-08-23 HoverPocket AI-native AN3-B1 Final Safety Integration

## 対象

- Worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3b`
- Branch: `codex/ai-native-an3b-voice-runtime`
- Draft PR: [#21](https://github.com/shotaro311/hover-pocket/pull/21)
- 統合前head: `97099eaf2fa03d7f29ccf6eb9bdb652c6e748992`
- 統合head: `3c0b46415d60b1d2e370af6d9c44a7614891154f`

## 統合内容

- 検証済みPR #19 branch `codex/ai-native-an3-voice-foundation`を通常mergeし、PR #21のWindows microphone / WebRTC / Codex experimental Realtime実装へ最終AN3-A安全境界を取り込んだ。PR自体はmergeしていない。
- Windows Coordinatorの競合は、既存のRealtime cleanup taskと追加されたapp-server transport teardown taskを別々に保持する形で解消した。
- crash、unexpected request、stale startup disconnectはowner disposalを追跡登録してから開始する。restart、Voice OFF、system transition、application Disposeは旧transport teardown完了後だけreplacement起動または終了へ進む。
- transcript / session UIは、既存のcurrent-root、user / assistant role、identifier、scalar / count境界に加えて、POSIX / Windows relative path、Bearer、裸のOpenAI key、JSON credential fieldをHost側で表示前に秘匿する。
- PR #21のexact-origin microphone permission、SDP generation fence、root threadのread-only / approval never / tools禁止、prompt local track停止、SettingsへのVoice state非公開は維持した。

## ローカル検証

成功:

- `swift build -Xswiftc -warnings-as-errors`
- `python3 script/verify_voice_foundation.py`
  - 42件のgeometry / state、explicit-origin microphone、fenced Realtime transportを含めて成功。
- `node --check windows/ui/js/app.js`
- `node --check windows/ui/js/i18n.js`
- `./script/build_and_run.sh --build-only`
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-voice-foundation`
- `codesign --verify --deep --strict dist/HoverPocket.app`
- `git diff --check`

制約:

- ローカルMacには`.NET SDK`がないため、Windows Release / native verifier / rendered WebViewはGitHub Actionsを受入根拠にした。
- 実Windows端末のinstalled Codex、microphone、WebRTC remote audioによる1往復は未実施であり、PR #21はDraftを維持する。

## Security diff scan

- scan ID: `b09c2248-5609-4417-8202-59171f3bfdec`
- exact range: `97099eaf2fa03d7f29ccf6eb9bdb652c6e748992...3c0b46415d60b1d2e370af6d9c44a7614891154f`
- changed security surface: 4 / 4 closed。
- completeness: complete。
- reportable finding: 0。
- status: sealed complete。
- report: `/private/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/codex-security-scans-0JCxLg/hover-menu-preview-ai-native-an3b/3c0b46415d60b1d2e370af6d9c44a7614891154f_20260823T135436Z_84aex_16/report.md`

## PR CI / review readback

- Router: [32643781540](https://github.com/shotaro311/hover-pocket/actions/runs/32643781540) 成功。
- 3OS deterministic contract / compare: [32643782576](https://github.com/shotaro311/hover-pocket/actions/runs/32643782576) 成功。
- Windows Verify: [32643782605](https://github.com/shotaro311/hover-pocket/actions/runs/32643782605) 成功。
- macOS Verify: [32643782572](https://github.com/shotaro311/hover-pocket/actions/runs/32643782572) 成功。
- review thread: 0件。未解決: 0件。
- Draft PR #21: `CLEAN / MERGEABLE`。
- local / remote parity: `0 / 0`、worktree clean。

## 残るgate

1. この進捗同期headのCI / review / parityを再確認する。
2. PR #21をPR #22へ通常mergeし、Calendar / Timer Capability Broker接続との統合CI / reviewを確認する。
3. 実Windows端末でinstalled Codex / microphone / WebRTC remote audioの1往復を確認する。
4. PRのmergeは人手gateを維持する。
