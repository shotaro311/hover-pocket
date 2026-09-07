# 共通コントローラーの接続契約

承認済みアーキテクチャの具体化。macOSの既存音声toolに `hoverpocket_control` を追加する。既存toolの名前、引数、承認経路は維持する。

- `operation` は catalog / screen / generate / job / cancel / install_prepare / remove_prepare / confirm / collections / records / record_prepare / restore_prepare / inspect / workflow_prepare / weather。
- provider_id、package_id、collection_id、record_id はHostが返したIDを使う。表示名では変更対象を決めない。calendar_date は利用者のタイムゾーンの YYYY-MM-DD。
- 読み取り結果は status=succeeded、未実行は awaiting_confirmation または accepted、失敗は failed と code。画面の表示確認とデータ取得状態を分ける。
- 生成jobはセッション中のみHostが管理する。生成中はIDを即時返す。生成結果自体のcheckpointは既存履歴ストアが正本。切断時は承認を失効し、生成は取消要求する。新しいjob用のディスク形式は導入しない。
- 変更のprepareは該当区分の確認設定がOFFなら直接実行し、ONなら一回限りの confirmation_id を返す。確認を尋ねた後の利用者の返答を受けてconfirmを呼ぶ。確認は会話session・対象・版/digest・record revisionに結び付き、5分で失効する。要求後の新しい利用者発話が未観測の場合、要求時と同じcallからの再利用、切断後、別session、対象変更後は拒否する。取消後に承認を復活させない。
- 標準機能の所有区分はProviderRegistry.builtInとHostの標準package集合が正本。生成manifestの区分宣言を信用しない。
- collectionは既存schemaとrevisionを返し、既存HostModelを通じて変更する。保存形式の移行なし。削除はデータ保持のアンインストールのみ。完全削除は既存設定画面からの別操作。
- calendarの月・選択日・hover・編集中draftは共有ObservableObjectに集約する。編集中は音声による日付切替を拒否する。
- 声の設定はUserDefaultsの codexVoiceSelection（未設定/空文字は接続先の既定）。実際に取得したlistVoicesのv1群（現在のV3音声セッションが使用する群）の候補だけを表示・採用する。次回の明示的な接続開始から適用する。既存会話を設定変更で切断しない。

ロールバックでは追加の入口と設定UIを外す。未設定の声は従来と同じ接続要求となる。ツール定義・レコード・既存checkpoint・導入receiptは既存形式を保持する。

## 追加の実装境界

- 追加ツールのsurface modelをactivation単位で共有し、入力と選択を保持する。画面を再表示するときは未保存入力を保護しつつqueryを更新する。定義更新・削除時は既存activationのモデルを無効化する。
- 生成HTMLの操作検査では data-pocket-action、data-pocket-field、data-pocket-record の通常のDOM属性を使う。既存パッケージの読み込み形式は変更せず、新しく生成するUIのガイドへ検査可能なマークアップを追加する。属性は権限を与えない。
- WebKitの試用データ、保存・取消・検索操作、幅520/300・文字15pxの検査を生成完了時に実施。失敗の固定コードだけを生成workerへ戻す。既存の最大3ターンを維持する。native表示は描画とHost保存を検査し、クリック操作・実音声・主観的な見た目の受入は別に残す。
- 声のAPIは2026-09-07の実機Codex CLI 0.153.4が生成したschemaと、OpenAIの公式実装で確認。V3がv1の声を使う仕様は [公式realtime実装](https://github.com/openai/codex/blob/main/codex-rs/core/src/realtime_conversation.rs) の validate_realtime_voice と一致する。Maple指定で実WebRTC接続・終了を検証。

## 2026-09-07 音声だけで完結する確認設定と天気（追加承認）

- 通常操作は既存UserDefaults `voiceActionConfirmationEnabled` を保持。削除・取消操作には新しいBool `voiceDestructiveConfirmationEnabled`（未設定はtrue）を使う。両者は独立し、両方falseなら追加確認なし。新しいキーを旧版は無視するため、ロールバック時は旧来の削除確認へ戻る。既存データの移行は不要。
- before: 確認OFFでも削除がnative dialogを表示。after: 通常/削除の該当設定がOFFなら同じBroker承認・実行・readbackを自動で進める。ONならnative dialogを開かず、awaiting_confirmationと一回限りIDを音声へ返す。
- 新しい `voice_action_confirm` はconfirmation_idとconfirmed=trueだけを受け、後続の利用者発話・同じsession・期限内に限り、保持していた同じ実行計画を再開する。確認待ちのtool呼出しは先に応答を返すので会話を妨げない。取消・切断・5分経過で待機中の計画を拒否する。引数・対象revision・Brokerのplan digestは再生成しない。
- 追加ツールの既存prepare/confirmも同じ2区分へ接続。workflowの区分はHostが許可されたcapabilityのeffectから判定し、生成物の自己申告を使わない。完全削除の範囲拡張はしない。
- `hoverpocket_control operation=weather` は既存の設定地域・温度単位・WeatherForecastStoreを正本に読み取る。新規の位置情報権限や位置の保存は追加しない。現在の天気と8日分の日付、気温、降水確率、地域名、タイムゾーン、取得時刻、キャッシュ警告を返す。温度の単位と降水確率のpercentを明示し、古いキャッシュと最新取得を区別する。座標は音声モデルへ渡さない。
- 本番反映はユーザーが追加依頼と同時に承認。macOS feed/公開ZIP/署名公証を別途readbackし、Windows feedを維持する。
