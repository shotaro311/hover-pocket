# HoverPocket AI-native Controls Capability

## 結果

Built-in Capability ExpansionのControls単位として、macOS / Windows共通の6 Capabilityを追加した。既存Controls UIと同じOS service / bridgeを使うが、AI、Voice、Pocket AppからはProvider StoreやWebView bridgeへ直接触れず、`CapabilityRegistry → CapabilityBroker → ControlsCapabilityHandler → OS adapter`だけを通す。

この単位だけではExpansion全体は未完了である。後続はClipboardのID / digest中心Capability、Calendar update / delete、既存UI mutationのBroker移行を行い、Core Integration Gateでまとめて閉じる。

## 実装したCapability

- `controls.availability.get@1`: volume、brightness、mediaの利用可否とbounded display IDを返す。
- `controls.volume.get@1`: volume levelとmute状態を返す。
- `controls.volume.set@1`: volume levelを書き込み、元のmute状態が維持されたことをreadbackする。
- `controls.mute.set@1`: mute状態を書き込み、実OS状態をreadbackする。
- `controls.brightness.set@1`: allowlisted display IDへ5〜100%を書き込み、対象ID・値・controllable状態をreadbackする。
- `controls.media.command@1`: `play_pause`、`next`、`previous`だけを許可し、再生状態またはtrack identityの変化をreadbackする。

readは`controls.read`、writeは`controls.write`を要求する。すべてのwriteはidempotency keyが必須で、Brokerのapproval、rate limit、audit、receipt、`os_state` readback policyを共有する。raw artwork data URL、media URL、window handle、AUMID、device名はCapability出力と監査へ出さない。

## セキュリティ修正

差分監査で次の2点を再現した。

1. next / previousのreadbackがtitle変更に加えて1秒超のposition変更も成功条件にしており、失敗したskipでも通常再生が進むだけで成功receiptになり得た。
2. macOSのvolume setが正の値で自動的にmute解除していたが、Capability planはlevelだけを承認しており、表示と実行に差があった。

修正後は、next / previousでtitleが変化しなければfail closedにする。sourceやdurationは遅れて更新される場合があり、track変更の確実な証拠にしない。volume setは実行前のmute状態を取得して保持し、handlerでも実行後muteが変わっていないことを検査する。外部DDCのmuteが音量0で表現される場合は、正の音量を書いて無断で音を出さず、記憶値だけ更新してreadback不一致として失敗させる。

Codex Security diff scan `27dc0225-9797-4d2f-b8eb-0eb111210182`はexact working-tree content digest `codex-security-snapshot/v1:sha256:b626229b09e5c4b5fa8cc455fe0711a56ae24dde65f636a8d72277565d686c56`を対象に変更source 15 / 15を確認した。現行productionではAI-nativeがdefault-offで、Today Focus、Voice、MCP、generated Pocket AppからControls handlerへ到達する経路がないためreportable findingは0件となった。ただし公開条件が変わればmedium相当になるため、上記2点はPR前に修正した。

## 検証

- `swift build -Xswiftc -warnings-as-errors`: 成功。
- `HoverPocket --verify-capabilities`: 成功。20 handler、Controls readbackとnegative caseを確認。
- `HoverPocket --verify-broker`: 成功。21 descriptor / 20 handler、approval、`os_state` readbackを確認。
- `verify_pocket_contracts.py`: 12 schema / 63 fixtureが2回成功し、report byte一致。
- Media、Timer、Clipboard、Pocket Surface、Pocket App、Panel layout verifier: 成功。
- Windows UI JavaScript全fileのsyntax check: 成功。
- `git diff --check`: 成功。
- Codex Security scan: sealed complete、coverage 15 / 15、finding 0。
- Windows .NET SDKは現Macにないため、Windows Release build、Capability / Broker verifier、3 OS contract byte一致はPR CIで確認する。

## 残り

- branchをpushし、Ready PRでWindows / macOS / Pocket contract / PR Routerを通す。
- Windows実機またはCIでvolume / mute / brightness / mediaのCapability verifierを確認する。
- Controlsの既存手操作UIをBrokerへ移す段階では、連続slider操作用のHost-owned approval policyとrate制御を別途設計する。
- Built-in Capability ExpansionはClipboard、Calendar update / delete、既存UI parityが残るため未完了。
