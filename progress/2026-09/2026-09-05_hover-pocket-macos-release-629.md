# macOS 0.1.0 (629) 本番配信

- ユーザーがAIネイティブ化途中のmacOS版を本番へ配信するよう明示依頼した。
- 対象は9月4日に作成済みのDeveloper ID署名・公証済みZIP。SHA-256: `627ad8d7d833221757f860946f3aca5f54506b716e15f3a13e1c0ba7044a1f42`、7,633,805 bytes。
- 既存final-integration worktreeのHEAD `38ec6f308bff55d44b57a26938857d061b5e0680`と未コミット変更を専用release worktreeへ複写し、元worktreeを変更せず配信時点のソースを保存した。作成済みartifactは再buildしていない。
- ZIP展開後のstrict codesign、stapler、Gatekeeper、Info.plist build 629 / macOS専用feed、Sparkle Ed25519署名を再検証してPASS。
- 配布binaryのVoice Foundation、Voice E2E isolation、Panel layout、Capability、Broker、Pocket Surface、Pocket App、TimerがPASS。ソース静的Voice検証、15 schema / 72 fixture共通契約、git diff --checkもPASS。
- 実機確認済みの音声会話・付箋・明るさ・音量は9月4日build 628の記録に基づく。build 629の非表示時音声継続（既定OFF）と操作確認省略（確認は既定ON）の実機確認は未完了と明記する。
- 過去ログの公開保留は当時の状態であり、今回の明示配信依頼で公開を進める。PR #39の全体mergeやWindows公開は行わず、macOS中間版だけを配信する。
- 公開完了: https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-629 （2026-09-05 12:53 JST）。tagはsource snapshot commit `b0bcf31d66a5861a6f106d273c33088afebcc8a1`と一致する。
- macOS専用appcastを168から629へ更新した。versioned ReleaseはDraft=false / Prerelease=false、GitHub latestもv0.1.0-629。
- 公開URLからZIP / appcastを再downloadし、SHA-256、size、embedded version、Sparkle署名、strict codesign、stapler、GatekeeperがすべてPASS。
- 実際の利用者環境でのSparkleインストール・再起動は未実施。通常版は既に629を起動していたため、この配信作業ではアプリを再起動しない。
- 証拠: `progress/evidence/2026-09-05_macos-release-629.json`。

- WindowsのReleaseは既存`win-v0.2.7`、公開日時は8月12日のまま。公開RELEASES、releases.win.json、release-manifest.win.json、SHA256SUMS-win.txtの取得がPASS。
- 両OS全asset verifierはmacOSのdownload / hash / signature検証後、Windows約86MB packageの低速downloadで中断した（exit 130）。Windows全payload再検証はスキップ。今回対象のmacOSは別途公開URLから全ZIPを取得・完全検証済み。

## インストール済み旧版からの実更新

- ユーザーの「アップデート配信が未設定です」という画面を調査。起動中は`/Applications/HoverPocket.app` build 168だったが、Info.plistにはmacOS専用SUFeedURLとSUPublicEDKeyが存在した。未設定という表示だけでは設定欠落を断定できない。
- 旧版の「アップデートを確認」からSparkleが168→629を提示。Install Update、Install and Relaunchを実行した。
- 更新後は同じインストール先がbuild 629、PID 50005で再起動。strict codesign / staplerがPASS。設定画面で「アップデートはありません」をreadbackした。既存の表示・Voice設定とChatGPTログイン表示も保持されている。
- 先の「利用者側のインストール・再起動は未実施」は、この実更新で解消した。未設定表示の発生原因そのものは未特定で、ソース修正は行っていない。
