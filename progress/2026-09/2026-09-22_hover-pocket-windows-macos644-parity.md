# Windows版のMac build 644相当への対応

## 依頼と基準

- 現在のMac版と同等の機能をWindowsでも使えるようにする。ミラー（カメラ）とマイクチェックはユーザーの回答により対象外。Voiceの会話機能は対象。
- Macのインストール済み `/Applications/HoverPocket.app` を独立して読み戻し、CFBundleVersion=644、CFBundleShortVersionString=0.1.0を確認。
- 644のソースは `ad17aa21eaaaef519a67ddc77325d887d6578368`。既存のMac配布worktreeは編集せず、このcommitから専用worktreeと `codex/windows-macos644-parity` を作成。
- 旧mainを基準にするとVoice・Pocket Tools v2・付箋リマインダーを見落とすため、644を基準にmainの配布設定とアイコンを統合した。統合commitは `08ef2f1`。

## 完了したローカル実装

- Windows Calendarへ今日と7日先までの天気、現在の気温、天候、最高/最低気温、降水確率、取得し直し、帰属表示を追加。
- 設定へ世界の都市検索、47都道府県、現在地の明示取得、自動/摂氏/華氏を追加。位置情報拒否時は都市選択を案内する。
- 保存する予報は地点ID・座標・単位で分離し、20分以内は再利用する。API応答をサイズ・深さ・値で検証し、通信失敗時は同じ条件の保存済み予報を明示する。
- パネルと文字サイズへ特大を追加。パネル780×560 DIPs、文字倍率1.36、Voiceの展開高さ280 DIPs。
- カレンダーの月末行と予報が小さいパネル・特大文字でも重ならないように調整。
- 天気コアの共通CLIテストとCI、設定の保存後読み戻し・呼出し元制限・不正値拒否の検証を追加。

## 検証済み

- .NET SDK 10.0.401でWindows Release solutionをMac上クロスビルド: 警告0、エラー0。
  `dotnet build windows/HoverPocket.Windows.sln --configuration Release --no-restore --nologo -p:EnableWindowsTargeting=true -p:NuGetAudit=false`
- `dotnet run --project windows/tests/Weather.Core/Weather.Core.csproj --configuration Release`: 18項目PASS。
- `node windows/script/verify_settings_generation_target.mjs`: PASS。
- `python3 script/verify_voice_foundation.py`: 42項目PASS。
- `python3 script/verify_pocket_contracts.py`: schema 15、fixture 72/72 PASS。
- `python3 script/verify_pocket_tools_contracts.py`: v2契約62項目PASS、付箋リマインダー契約18項目PASS。
- `git diff --check HEAD`: PASS。
- 一時Playwrightハーネスで実UIへWebView2 bridgeのfixtureを注入し、パネル4段階×文字4段階の16組合せ、保存済み予報、予報なし、都市検索・選択、温度単位、位置情報拒否を確認。pageerror=0。
- Open-Meteoの実HTTPで東京の8日予報とLondonの都市検索が成功。

ブラウザーのfixture検証とMac上クロスビルドはWindows実機受入とは別。画面の証拠は元Mac作業フォルダーの `output/windows-parity-20260922/integrated/`、一時ハーネスは `/tmp/hoverpocket-ui-integrated-verify.cjs`。

## 続行中・未検証

- ユーザーがS311-winの専用タスク作成を承認。WindowsのタスクIDは `01a0c95b-23bc-70b0-9ad9-1690b7d87b96`。
- Windows保存済みプロジェクトにHoverPocketがないため、Downloadsを受け取り地点として作成。実装対象は既存 `C:\Users\shotaro\code\shared\hover-pocket` から分離する専用worktree。
- Windowsの既存Voiceと生成基盤を引き継ぎ、644相当のVoice・Pocket Tools v2・付箋リマインダーを実装してWindows実機で確認する。元Macタスクは天気変更と引き継ぎを担当する。
- `BrokerOnlyToolPolicyProductionApproved=false`、生成用sandboxなどの互換性・隔離ゲートは、Macの実証済み経路と現行公式仕様を根拠に対応する。根拠なく解除しない。
- Windowsネイティブ `--verify weather/settings/ui`、位置情報権限、Voiceの物理マイク、署名済み配布と導入はこの時点では未検証。
- このローカル変更は依頼範囲として追加確認なしで実施。Releaseの公開、push、外部への送信、課金はしていない。

## 参照

- `docs/plan/20260906_POCKET_TOOLS_PLATFORM.md`
- `docs/plan/20260907_CODEX_APP_OS_ARCHITECTURE.md`
- `docs/plan/20260907_CODEX_APP_OS_CONTRACT.md`
- `docs/plan/20260908_POCKET_LIBRARY_ARCHITECTURE.md`
- `progress/2026-09/2026-09-11_hover-pocket-sticky-reminders.md`
