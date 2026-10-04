# 2026-10-03 Windows撮影クラッシュの修正と全体レビュー

対象は、チャット「Windows版の液体アニメーションを移植」で追加したWindows開発版の撮影・収録、素材ライブラリ、上端パネルと既存機能の連携。前の作業場所 `C:\Users\shotaro\Downloads\hover-pocket-windows-liquid-20261002` を継続し、別のdirty checkoutを保持した。macOSの実装・実機評価は今回の対象に含めていない。

## 修正したクラッシュ

2026-10-03 09:58 JSTのWindows Applicationイベント1026で、`ScreenshotSelectionWindow.Crop` の `CroppedBitmap.Freeze()` から `BitmapDecoder.IsDownloading` へ進み、`InvalidOperationException`（別スレッドの所有オブジェクトへのアクセス）で終了したことを確認した。障害実行ファイルは開発版 `asset-local-8-capture-complete`。

`CaptureDesktop` はワーカースレッドでPNGをデコードし、その `BitmapFrame` をUIへ渡していた。フレームをFreezeしてもdecoderへの参照が残るため、UIで切り抜きをFreezeすると失敗する。従来の検査は、UI上で生成した画像の切り抜きとワーカーでの画面取得を別々に試しており、この組み合わせを通していなかった。

- 実際のワーカー画面取得→UI切り抜き→ワーカーPNG保存を回帰検査に追加し、修正前に同じ例外・exit 1を再現した。
- GDIから取得した画素を独立した `BitmapSource` へコピーしてFreezeする方式へ変更した。途中のPNG圧縮・再デコードを除き、画面の不定なアルファ値を使わないBgr32とした。
- 範囲確定のイベント内で処理失敗を受け止め、撮影画面へ失敗を返す。編集画面の画像生成失敗も、その場で案内し編集内容を保持する。
- 開発版を `0.2.9-local.9` に更新した。

実画像での選択3回、注釈描画と保存PNGの画素照合、元画像保存、ネイティブのマウスドラッグ、Enter全画面、Esc取消、不正な切り抜き範囲のエラー処理が成功した。検査の入力は自分の生成ウィンドウであり、物理キーボードを人が押す手動受入とは区別する。

参照した一次情報: [Microsoft BitmapSource.Create](https://learn.microsoft.com/en-us/dotnet/api/system.windows.media.imaging.bitmapsource.create?view=windowsdesktop-10.0)、[WPF Freezable](https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/freezable-objects-overview)。原因の確定根拠は端末の例外記録と修正前の再現である。

## レビューで発見した4件（local.10で修正）

以下はlocal.9の全体レビュー時点で見つけた別の不具合。追加依頼を受け、local.10で4件とも修正した。[修正内容と回帰検証](20261003-windows-review-fixes-response.md)。以下の再現結果と修正案は、発見時点の記録として保持する。保存コアは生成データ専用のSQLiteライブラリ、UIは本物のWebView2とJavaScriptに対して検証した。UIのbridge応答だけをfixtureへ置き換え、ユーザーの素材に変更を加えていない。

### 1. P1: 原本が欠けても重複を保存成功として扱う

[AssetStore.cs](../../windows/src/HoverPocket.Assets/AssetStore.cs) の124–131行。DBに同じSHA-256があれば、既存原本の存在・整合性を確認せず `duplicate` を返す。新しい入力をコピーした一時ファイルもゴミ箱へ移す。さらに撮影の `ImportCompletedAsync` は `duplicate` を成功と解釈して、完成した撮影フォルダまでゴミ箱へ移す。

生成ファイルを取り込み、その管理原本だけを検証用の退避先へ移してから、同じ内容の撮影を取り込んだ。`reported_saved=1`、`managed_original_missing=true`、`new_capture_recycled=true` を確認した。アプリには閲覧・取り出しができる原本が残らない。新しい画像はWindowsのゴミ箱から取り戻せるが、「保存成功」とするのは不正確。

修正案は、重複確定前に既存原本を検証し、欠損・変更時は新しい撮影ファイルを保存待ちとして保持して復旧を案内すること。管理原本の無断置換は避ける。優先して修正する。

### 2. P2: 絞り込みで見えなくなった素材が一括操作へ残る

[assets.js](../../windows/ui/providers/assets/assets.js) の34–37行および141行。絞り込み後に検証しているのは最後の `selectedAsset` だけで、複数選択の `selection` 全体ではない。

お気に入りのAと通常のBを選び、Aを最後の選択にしてからお気に入りへ絞ると、画面はAだけになるがBも選択に残る。この状態で「ゴミ箱」を押すと、Bを含むIDが `assets.update` へ渡ることをWebView2で再現した。分類や名前変更も同じ集合を使う。[AL-13](../requirement/asset-library-v1.md)の対象外選択の解除に反する。

修正案は、検索条件変更時に選択ID全体の適合を確認し、条件から外れた選択を解除してから一括操作を受け付けること。現在のページ外にあるだけの適合項目とは区別する。

### 3. P2: 選択中のフォルダが撮影設定へ渡らない

[assets.js](../../windows/ui/providers/assets/assets.js) の22行、68–71行、211行。フォルダ選択は `query.folderIds` に保存し `query.folderId` をnullにする一方、撮影ボタンは `query.folderId` を渡す。

通常のフォルダクリック後も撮影へ渡る値はnullであることをWebView2で再現した。CaptureControllerはこれを明示的な「分類なし」と解釈する。撮影設定で手動選択すれば回避できるが、[AL-38](../requirement/asset-library-v1.md)の現在フォルダの引き継ぎを満たさない。従来の検査はControllerへフォルダIDを直接渡していたため、JavaScript側の不一致を検出できていなかった。

修正案は、単一の選択フォルダを共通の取得処理で解決して撮影へ渡し、実際のフォルダクリック→撮影ボタンまでを検査すること。複数フォルダ選択から任意の一つを勝手に選ばない。

### 4. P2: 一つの壊れた保存待ち記録が後続の再試行を止める

[CaptureFiles.cs](../../windows/src/HoverPocket.Shell/Capture/CaptureFiles.cs) の37–41行。再試行ループで項目ごとの例外を扱わず、最初のJSON破損・読み取り失敗などで全体を終了する。

壊れた `complete.json` の次に正常な完成済みPNGを置くと、`JsonException` で停止し、正常なPNGの登録も0件のままだった。ファイルは保持されるが、同じ「再試行」を繰り返しても後続へ進まない。ゴミ箱に重複がある場合の失敗も、後続を止める。

修正案は、完成待ちフォルダごとに失敗を保持・集計し、他の正常な項目の取り込みは続けること。

## 検証と範囲

検査ログ、再現コード、通常起動の読み戻しはgit除外の `artifacts/capture-fix-20261003/` へ保存する。既存の51件の保存コア検査・18件の天気検査と、16ファイルのJavaScript構文検査は成功。Debug/Releaseビルドは警告0・エラー0。

最終 `.9` 成果物で、撮影・素材UI・既存UI・100回開閉・画面配置・設定・UIモデル・天気・Voice・タイマー・カレンダー・Controls・クリップボード・付箋・計算機・updater・capabilities・broker・pocket-surfaceの19種類がすべてexit 0。100回開閉は最初の待機上限180秒では終了コードを回収できず、完了ログを保持して360秒の上限で再実行し、183.46秒でexit 0を確認した。

10:17 JSTに修正版を通常起動し、実行パス・版・応答、設定と撮影設定のハッシュ、ライブラリの件数・未完了操作・schema・quick_checkを読み戻した。起動前後の設定とライブラリは不変。詳細は[作業記録](../../progress/2026-10/2026-10-03_hover-pocket-capture-crash-review.md)を参照。

前回の未コミット実装を含む保存・復元・ゴミ箱・プレビュー・動画配信・注釈・収録のコードと、shell/bridge/tray/update連携、要件・回帰検査をレビューした。既存検査が成功しても上記4件の条件は網羅していないため、「全体の不具合なし」とは判定しない。

長時間の映像と音声の同期、実複数モニターと混在DPI、HDR/保護映像、マイクの許可拒否と物理切断、実ディスク満杯、Windows再ログイン、macOS、公開インストーラーと更新配布は未検証。起動登録はインストール版 `0.2.9-local.2` を指しており、今回の開発版の手動起動とは別である。
