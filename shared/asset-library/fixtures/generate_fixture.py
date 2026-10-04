"""Regenerate the tiny, redistributable cross-platform v1 backup fixture."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).parent / "v1"
(root / "originals").mkdir(parents=True, exist_ok=True)
asset_id = "11111111-1111-4111-8111-111111111111"
folder_id = "22222222-2222-4222-8222-222222222222"
tag_id = "33333333-3333-4333-8333-333333333333"
content = "HoverPocket 共通の復元fixture\n".encode("utf-8")
(root / "originals" / (asset_id + ".txt")).write_bytes(content)
manifest = {
    "version": 1, "createdAt": "2026-10-02T00:00:00Z",
    "assets": [{"id": asset_id, "name": "ＡＢＣ_猫.txt", "extension": "txt", "kind": "other",
                "sha256": hashlib.sha256(content).hexdigest(), "sizeBytes": len(content),
                "createdAt": "2026-10-02T00:00:00Z", "favorite": True, "trashed": True,
                "internetOrigin": True, "folderIds": [folder_id], "tagIds": [tag_id]}],
    "folders": [{"id": folder_id, "name": "資料", "parentId": None}],
    "tags": [{"id": tag_id, "name": "Ｈａｌｆ幅", "parentId": None}],
    "searches": [{"id": "44444444-4444-4444-8444-444444444444", "name": "猫の素材",
                  "filter": {"text": "猫", "view": "recent", "kind": None, "folderId": None,
                             "tagId": None, "offset": 0, "limit": 80}}]
}
manifest["searches"].append({"id": "55555555-5555-4555-8555-555555555555", "name": "テキストを名前順",
    "filter": {"version": 2, "text": "", "view": "trash", "offset": 0, "limit": 80,
               "extension": "txt", "sortBy": "name", "descending": False}})
(root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
