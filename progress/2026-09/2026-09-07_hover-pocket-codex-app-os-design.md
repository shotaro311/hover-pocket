# 2026-09-07 音声・画面・ツール開発の設計更新

ユーザーの採用内容を設計文書と要件へ反映。音声側と生成側を別セッションにし、既存音声操作を維持する。追加・更新・削除前の音声確認、標準機能の削除禁止、声の選択、生成物の実preview検証を含む。

設計正本: [Codex App OS](../../docs/plan/20260907_CODEX_APP_OS_ARCHITECTURE.md)。既存Pocket Tools設計と現行generator/voice/controllerのコードを照合した。Markdownリンクの実在、役割分担と採用要件、git diff --checkを検証。文書変更のためビルド・実音声試験は未実施。アプリ実装・契約schema・公開は変更していない。ノッチ伸縮案の不採用は維持する。
