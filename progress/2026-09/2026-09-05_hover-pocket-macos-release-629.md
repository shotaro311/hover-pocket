# macOS 0.1.0 (629) 本番配信

- ユーザーがAIネイティブ化途中のmacOS版を本番へ配信するよう明示依頼した。
- 対象は9月4日に作成済みのDeveloper ID署名・公証済みZIP。SHA-256: `627ad8d7d833221757f860946f3aca5f54506b716e15f3a13e1c0ba7044a1f42`、7,633,805 bytes。
- 既存final-integration worktreeのHEAD `38ec6f308bff55d44b57a26938857d061b5e0680`と未コミット変更を専用release worktreeへ複写し、元worktreeを変更せず配信時点のソースを保存した。作成済みartifactは再buildしていない。
- ZIP展開後のstrict codesign、stapler、Gatekeeper、Info.plist build 629 / macOS専用feed、Sparkle Ed25519署名を再検証してPASS。
- 配布binaryのVoice Foundation、Voice E2E isolation、Panel layout、Capability、Broker、Pocket Surface、Pocket App、TimerがPASS。ソース静的Voice検証、15 schema / 72 fixture共通契約、git diff --checkもPASS。
- 実機確認済みの音声会話・付箋・明るさ・音量は9月4日build 628の記録に基づく。build 629の非表示時音声継続（既定OFF）と操作確認省略（確認は既定ON）の実機確認は未完了と明記する。
- 過去ログの公開保留は当時の状態であり、今回の明示配信依頼で公開を進める。PR #39の全体mergeやWindows公開は行わず、macOS中間版だけを配信する。
- 公開操作・公開後readback: 準備完了、実行待ち。
