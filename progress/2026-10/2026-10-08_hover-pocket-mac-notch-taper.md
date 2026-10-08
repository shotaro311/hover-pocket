# 2026-10-08 Macのノッチ左右の微調整

## 変更と検証

- ユーザーの0.2.15画像では、ノッチの左右の角に小さな突起が残っていた。メニューバーを残す方式の接続上端を、物理ノッチの縁より左右各1ポイント内側へ寄せた。前回増やした上下の重なりと曲線の連続性を維持する。メニューバーを覆う方式とノッチなし画面の描画は維持する。
- Macのreleaseビルド、ノッチ幅185/246・表示倍率1/2/3で上端のはみ出し防止と下部の連続性を確認。両接続方式の実メニュー選択・取消、ホバー収納、100回開閉、サイズ切替、途中反転・復帰が成功した。
- 初回の実機検査は開き始めで停止。検査を最初の描画まで最大0.5秒待つ判定へ変更し、同じ形状の再検査が成功した。描画読戻しはprogress=0.0206、body_top=32、draw_top=31.877、join=0.123。失敗ログも保持した。
- 画面収録のOS権限がないため画面上のピクセル検査はスキップ。更新後のユーザー目視確認は依頼中。

## 公開・実機反映

- [PR #55](https://github.com/shotaro311/hover-pocket/pull/55)をmain `49429f7f266fcc6e943aed533af21a650a011ac5`へ統合。ビルド元 `27253f9c8b777428581994f56317854659eded84`とmainの製品ソース・配布スクリプトの一致を確認。
- [Mac 0.2.16 / build682](https://github.com/shotaro311/hover-pocket/releases/tag/v0.2.16-682)を署名・Apple公証して公開。公証はAccepted、submission `c20e1f70-abc8-450b-ae5f-132904883547`。公開ZIPのSHA256は `ebacefd403243826cb67f156b61b34b6d747a5d087a736d1937af581caac922c`。Windowsは0.2.14。
- 公開フィード・配布物99項目が成功。Mac実機でも公開物を別途取得し、署名・公証・Gatekeeperを検証した。
- 本番アプリを通常終了して旧アプリと全ユーザーデータを`startup-backup/`へ保存し、公開版から更新。`/Applications/HoverPocket.app` 0.2.16 / build682、PID25829の一意な起動と公開バイナリ・同梱メディア補助プログラムの一致を確認。旧アプリは`installed-old-moved.app`にも保持した。
- 素材30件、DB・原本・設定・チャットは更新前後で一致。Clipboard画像20件は一致。テキスト30件のうち既存の1件だけを同じ内容で最新位置へ取り込み直し、残る29件は一致。元の履歴はバックアップに保持した。初回の厳密比較はClipboardのハッシュ差を報告し、この通常取り込みと本文・お気に入りの保持を別検査で確認した。
- [最終PR CI](https://github.com/shotaro311/hover-pocket/actions/runs/37761069900)、[main統合後CI](https://github.com/shotaro311/hover-pocket/actions/runs/37762022703)、[公開物CI](https://github.com/shotaro311/hover-pocket/actions/runs/37762136647)、[0.2.15→0.2.16の更新・復元・再インストールCI](https://github.com/shotaro311/hover-pocket/actions/runs/37762141721)が成功。

証拠は独立worktreeの`artifacts/mac-notch-taper-20261008/`に保持する。元の未コミット変更とMac側の保存済み変更は保持した。
