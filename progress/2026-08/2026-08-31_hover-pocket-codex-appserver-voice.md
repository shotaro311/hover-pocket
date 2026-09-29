# 2026-08-31 HoverPocket Codex app-server Voice

## Voice Lane設定のruntime伝播修正

- build 618で、Settingsの`Voice Laneを有効化`はON、Providerは`codex_app_server`、ChatGPTログイン済みとAccessibilityで読める一方、同一processの隔離receiptは`featureEnabled=false / providerId=off`のままで、Panel下段のVoice Laneが表示されないことを再現した。
- 原因は、`@Published`が新値をpropertyへ格納する前に通知するにもかかわらず、Settings observerが通知値を捨て、`AppSettings`を同期的に読み直していたためである。Voice enable、Compact / Expanded、Provider変更の1回目に旧値をruntimeへ渡していた。
- `voiceRuntimeSettingsPublisher`が発行する`featureEnabled / preferredLayout / providerID`をimmutable configurationとしてそのまま`VoiceLaneRuntime.configure`へ渡すよう修正した。Codex app-server adapter factoryは同じSettings instanceと通知されたProvider IDを使い、Voice hot pathへ新しいpolling、file I/O、network処理は追加していない。
- 回帰テストはProviderをCodex app-serverへ変更、VoiceをON、表示をExpandedへ変更した3通知が、順に新値を発行することを固定した。

## Timerだけが表示される理由

- build 618 / 619は通常版ではなく、macOS物理Voice E2E専用の隔離候補である。`requirements.md` 4.9の要件どおりProvider RegistryとUIをTimerだけへ限定し、Updater、Google OAuth、Camera、Clipboard、生成Pocket Appおよび本番データへ接続しない。
- 通常版HoverPocketの`ProviderRegistry.builtIn`はMirror、Controls、Calculator、Calendar、Today Focus、Clipboard、Sticky Notes、Timerを維持している。今回の修正で通常版Providerを削除・非表示にはしていない。

## 検証

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift build -c release -Xswiftc -warnings-as-errors`: PASS
- `.build/debug/HoverPocket --verify-voice-foundation`: PASS
- `python3 script/verify_voice_foundation.py`: PASS、42 contract cases
- `.build/debug/HoverPocket --verify-panel-layout`: PASS、128 cases
- `.build/debug/HoverPocket --verify-voice-e2e-isolation`: PASS
- `git diff --check`: PASS
- 独立エージェントレビューはP0 / P1 / P2すべて0件。設定変更時の発火回数は従来と同じで、音声hot pathへ処理を追加せず、抽象化も回帰検証に必要な最小範囲と判定された。
- 実装commit `f6633dcd894abbc42f0b53f815e1adf40b1ad4c3`をDraft PR #39へpushした。同一SHAのCIは11 SUCCESS / 8 expected SKIPPED / failure 0 / pending 0で、macOS、Windows、3 OS共通契約、release readback routerを確認した。PRはDraft / OPEN / MERGEABLEのまま、merge、release、公開は行っていない。
- fresh修正版候補`ホバーポケット Voice E2E 619`をbuild 619、session `HoverPocketVoiceE2ESession-XWor5t`、runtime `HoverPocketVoiceE2E-3xMDYN`、PID `52065`として起動した。strict ad-hoc codesignとHarness `ValidateIsolation`はPASSした。
- build 619は初期状態でVoice OFF、Provider receipt OFF、mic / remote audio / Timer readbackなし、CPU readback 0.1%であり、ユーザーの明示操作前にVoiceやマイクを開始していない。SettingsにはCodex app-server、Voice toggle、専用ChatGPT login導線が表示される。
- 旧build 618はHarness Stopで`safe_close`、process停止、mic / remote audio / credential currentなしをreadbackした。session / runtimeは回収前のため保持している。

## 残る人手gate

- build 619のSettingsでVoiceをONにし、Panel下段へCompactが表示されることを目視確認する。
- build 619の隔離profileでChatGPTへログインし、マイクbuttonを明示操作して、実マイク、remote audio、user / assistant transcript、Timer承認 / readback、物理確認、Stop後のsafe closeを同一attemptで確認する。
- この候補はTimer限定の物理Voice証拠用であり、全Provider表示は通常版候補で別途確認する。
