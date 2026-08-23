# HoverPocket AI-native AN8 Capability互換・移行

## 目的

AN8完了条件のうち、古いCapabilityに廃止猶予を設け、ユーザー所有のPocket Appを旧版のまま破壊せず新しいCapabilityへ移行できるHost-owned経路をmacOS / Windowsへ追加する。

## 実装

- Capability lifecycleを`active` / `deprecated` / `removed`で管理する互換カタログを追加した。現行built-in catalogは空であり、既存Capabilityの動作は変更しない。
- `deprecatedInHostVersion < removalNotBeforeHostVersion`、明示置換先、migration ID、重複・自己置換・removed target・循環禁止を両OSと共有contractで強制する。
- deprecated Capabilityは猶予中も実行可能とし、removed CapabilityはRegistryで全入力経路をfail closedにする。移行元packageだけは専用read pathから検査できる。
- migratorはinstalled packageを直接編集しない。manifestのrequested Capability、Workflowの`use`、Surfaceの`query`を新しいapp versionへ決定論的に置換し、state schema bytesと`user-data://...` storeを維持する。
- Lifecycle Managerへ「互換更新を準備」を接続した。新versionを一時draftへ生成後、既存のpreview、staging tests、permission / Capability grant差分、Host承認、immutable install、readbackを通す。
- Settingsは互換問題と推奨patch versionを表示し、macOS / Windows双方から移行案を準備できる。承認前は旧版がactiveのままで、承認後も旧version snapshotをrollback用に保持する。
- 共有契約へ`capability-compatibility.schema.json`とvalid / zero-window / cycle fixture、stable error codeを追加した。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: 成功。
- `.build/debug/HoverPocket --verify-pocket-app`: package / lifecycle / generation / capability migrationがすべて`ok`。
- Today Focus実packageで、deprecated検知、grant差分、承認前の1.0.0維持、承認後の1.0.1 readback、1.0.0 / 1.0.1 snapshot保持、issue解消を確認した。
- `python3 script/verify_pocket_contracts.py`: `14 schemas / 69 fixtures / 69 matched`。report 2回のbyte一致を確認した。
- `node --check windows/ui/settings/settings.js`: 成功。
- `git diff --check`: 成功。
- このMacには.NET SDKがないため、Windows C# Release build / native verifier / Settings bridge / rendered WebViewはDraft PR CIを受入gateにする。

## 安全境界

- 移行は自動installしない。Host-owned native approvalを必須とする。
- permission / Capability grant差分はapproval bindingへ含め、移行後に再計算して一致確認する。
- installed source、state schema、user dataをin-place変更しない。
- removed宣言は予定versionより前に行えず、移行規則がない廃止を受理しない。
- 任意コード、外部Connector、新しいnative権限のhot installには拡張していない。

## 外部委譲と残件

- ChatGPT Pro OrchestratorのAN8-C backup / export / restore runは正式delivery待ちである。未claim成果物を先読み・再送していない。
- 本branchは`codex/ai-native-an8-retention-governance`へstackし、Draft PRでWindows / macOS / 3OS contract / Routerを確認する。mainへ自動mergeしない。
- AN8全体ではApp health、unused App disable提案、offline / sleep-wake / soak、署名配布、OS別feed readback、backup / export / restoreの統合が残る。
