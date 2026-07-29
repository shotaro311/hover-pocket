# 2026-07-29 HoverPocket Calendar Save Button

## 依頼

- Calendarの新規予定作成画面で、下へスクロールしなくても保存できるようにする。
- 下端にある保存ボタンを上部へ配置する。

## 変更

- `CalendarEventEditorView`の保存ボタンを、画面タイトルとキャンセルボタンがある上部ヘッダーへ移動した。
- 保存中の`ProgressView`、保存可否の無効化条件、`Command + Return`ショートカットは変更していない。
- 編集時だけ表示される削除ボタンは、破壊的操作としてフォーム下部に残した。

## 検証

- `git diff --check`: 成功
- `swift build`: 成功
- `./script/build_and_run.sh --verify`: 成功、Apple Development署名後にアプリ起動
- `./dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-panel-layout`: `panel_layout_verify=ok`、63ケース成功

## Readback

- `git diff`で保存ボタンが上部ヘッダーへ移動し、下部から削除されたことを再確認した。
- ビルド出力で`GoogleCalendarPreviewView.swift`の再コンパイルとアプリのリンク成功を確認した。
- Computer Useではホバー専用のアクセスウィンドウからCalendarフォームを開けず、実画面の目視readbackは未確認。
- 公開リリース、GitHub Release、appcast、Windows版は変更していない。
