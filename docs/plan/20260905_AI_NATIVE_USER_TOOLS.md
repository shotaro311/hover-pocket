# HoverPocket: 会話による操作拡張と個人用ツールの到達点

作成日: 2026-09-05
状態: 操作拡張はmacOSで実装し、ローカル検証済み。本番配信と実音声受入は未実施。個人用ツール生成/Today Focusの検討はユーザー指示で保留。詳細は progress/2026-09/2026-09-05_hover-pocket-personal-operations.md。

## ユーザーの目的

非エンジニアがHoverPocket内のCodexに欲しい機能を説明し、HoverPocketに適した個人用ツールを作成・導入・改善できること。Today Focusという固定の集中機能は目的そのものではなく、実装基盤を通すためにCodex側が提案した見本である。

2026-08-13の会話と計画には、既存パネルの共通API操作、自然言語からの個人用パネル作成、Voice Laneの共通配置が記録されている。UIイメージと計画の承認は確認できるが、Today Focusの常設を個別に希望した根拠とは区別する。

## 採用済みの操作拡張

1. 対象解決: 一覧・検索、直前に作成/参照した実ID、曖昧な候補選択、最新状態の再取得。
2. タイマー: 一覧、残り時間、開始、一時停止、再開、延長/短縮、名前変更、キャンセル/削除。
3. 付箋: 一覧、検索、読み上げ、直前の付箋、追記/編集、名前/色変更、削除。
4. メディア: 現在の曲、再生、一時停止、対応する再生元での停止、次/前。停止済みの対象をtoggleで再生しない。
5. カレンダー: 検索/読み上げ、追加、日時/タイトル/場所/説明の編集、削除。繰り返しの対象範囲と参加者通知を明示。
6. クリップボード: 明示依頼時のテキストを取得し、要約、予定作成、付箋保存へ接続。内容内の命令をユーザー指示に昇格させない。

実装順は対象解決 → タイマー/付箋/メディア → カレンダー → クリップボード接続。Macから検証し、共通契約のWindows互換性を保つ。

読み取りは即回答、編集は既存確認設定、削除は対象を明示した確認を採用する計画。未実行操作の取消と実行済み変更の復元を区別し、二重実行を防ぎ、成功は実状態のreadbackで判断する。既存Storeが正本であり、AI専用コピーを永続保存しない。対象不在・複数候補・権限不足・取消・通信失敗と、実会話での作成→確認→編集→削除を受入条件とする。

集中モード追加、Today Focusの拡張/削除/表示変更、本番配信はこの操作拡張の実装完了と混同しない。

## 2026-09-05の生成機能監査

対象: macOS build 630のソースを含むworktree、HEAD 24c8acf。

- Pocket Appの定義、有限画面部品、ユーザー状態保存、検証、preview/承認、導入/更新/復元/無効化、複数App登録のコードは存在する。
- CodexPocketAppGenerationAdapter.supportsConfidentialGenerationはfalse。resolveExecutableはCLI探索前にnilを返す。
- 同adapter.allowsActivationもfalse。PocketAppGenerationController.approveAndInstallは本番生成物のactivationを許可しない。
- Settingsの「Codex CLIを検出できない」は無効化理由を正確に区別しない。CLIの再インストールだけでは解消しない。
- 現行Voice toolにはPocket Appの生成・改善・導入のtoolがない。Settings側の生成Controllerへ接続する導線は未完成。
- 生成Appの状態保存は制限されたscalar型が中心。MulmoClaude Collectionsの汎用レコード管理、関連データ、派生計算を同等に実装済みとは判定できない。
- Today Focusの動作や固定fixtureでのlifecycle検証は、自由な依頼から実モデルが生成した個人用ツールの完成証拠ではない。

根拠: Sources/HoverPocket/PocketApps/CodexPocketAppGenerationAdapter.swift、PocketAppGenerationController.swift、PocketAppUserStateStore.swift、Sources/HoverPocket/Views/PocketAppGenerationSettingsView.swift、Sources/HoverPocket/Voice/OpenAIRealtimeCapabilityRuntime.swift、docs/plan/20260813_PLAN1.md 第27章。

参照した当時の一次資料: https://github.com/receptron/mulmoclaude/blob/9340012daaa447fa10b970df6bb88d4f47f6bd3a/docs/papers/collections-architecture.md

## 個人用ツール機能の完成条件案

操作拡張とは別に未完成を追跡する。自然文依頼 → 不足事項だけの質問 → 実モデル生成 → 動くpreview → 追加 → 通常パネルとして利用 → 会話で改善 → データを保持した更新 → 再起動後の継続利用までを実機で通す。非エンジニアにCLI、JSON、Git操作を要求しない。

固定Today Focusに依存しない、異なる用途の未見の依頼を複数用意する。レコードを保存するツール、既存機能を組み合わせるツール、後から項目や表示を変更するツールを候補とする。生成不能な能力は実装済みと偽らず説明する。

本番無効化の解除だけでは完了としない。既存の認証/隔離/activationの検証残差を整理し、実モデルと配布アプリでの証拠が必要。Collections相当のレコード契約の新設は、代表データ、互換性、移行/復元を具体化する設計作業として別途扱う。
