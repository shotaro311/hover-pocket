---
project_slug: hover-menu-preview
date: 2026-08-24
status: macos-transition-passed; current-release-monitor-passed; local-operations-contract-passed; windows-formal-pending
updated_by: codex
---

# AN8 Operations Readback

## 対象

- stack code head: `b95ef1681510781a38ccbb0b95cbf51384faa594`
- verification branch: `codex/ai-native-an3b3-realtime-provider`
- branch上のstack head以降の差分は進捗文書だけで、製品source差分はない。
- local verifier binary SHA-256: `e4dbba2b5095ba0aafef435df6645f547507b67b0a851c26aa467c95e1bddfc6`

## 公開release transition

- [Run 32664697767](https://github.com/shotaro311/hover-pocket/actions/runs/32664697767)で、macOS `v0.1.0-161 -> v0.1.0-168`のinstall、upgrade、rollback、uninstall、reinstallとuser data保持が成功した。
- receipt SHA-256: `7d72c7221dc7dc6ca9dcb8df1f22ee60817fab5e353f201c036ee8a25d4080ea`。
- Windows実行と未署名beta許可は無効のままにした。

## 公開release monitor

- [Run 32664908332](https://github.com/shotaro311/hover-pocket/actions/runs/32664908332)で、現在の週次監視と同じbeta readbackをexact stack headから実行した。
- macOS 6 asset、Sparkle Ed25519、manual ZIP / appcast parity、Developer ID、stapled notarization、Gatekeeper acceptedを確認した。
- Windows `win-v0.2.7`の8 asset、Setup / Portable / full packageのversion / runtime / payload identityを確認した。
- 3 report artifactのSHA-256は以前のreadbackと同一だった。Windows formal Authenticodeは未署名版のためskipを維持した。

## ローカル運用契約

- `.build/debug/HoverPocket --verify-broker`: 成功。21 descriptor / 20 handler、retention governance、approval、Today Focus、Pocket App、idempotency、negative caseを確認した。
- `.build/debug/HoverPocket --verify-pocket-app`: 成功。package / lifecycle / generation / capability migration / health / workspace backupを確認した。
- `.build/debug/HoverPocket --verify-pocket-surface`: 成功。有限Surfaceと15 negative case、render digestを確認した。
- `python3 script/verify_pocket_contracts.py`を2回実行し、15 schema / 71 fixtureが成功した。reportはbyte一致し、SHA-256は`6bb149dec5d24014c21115b7be580a683af970cf99d8523d98aa203c28631d04`だった。
- `git diff --check`成功、worktree cleanをreadbackした。

## 未完了

- Windowsの正規コード署名証明書、publisher certificate SHA-256 variable、正式署名済み旧版 / 新版が未準備である。
- Windows formal Authenticode、Velopack install / upgrade / rollback / reinstallは正式成果物が揃った後に実行する。
- Windows実機sleep / wake、両OSproduction Voiceと実音声E2E、実時間soak、人手stack mergeは別gateとして残る。
