#!/usr/bin/env python3
"""Bundle the fixed, dependency-free asset modules for WKWebView file loading."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
paths = [
    "Sources/HoverPocket/Resources/AssetUI/js/bridge.js",
    "windows/ui/providers/assets/locale.js",
    "windows/ui/providers/assets/assets.js",
    "windows/ui/providers/assets/assets.verify.js",
    "Sources/HoverPocket/Resources/AssetUI/mac.js",
]
allowed_imports = {
    'import { on } from "../../js/bridge.js";',
    'import { assetTranslator, translateAssetTree } from "./locale.js";',
    'import { renderAssetsProvider } from "./assets.js";',
    "import { renderAssetsProvider } from './providers/assets/assets.js';",
    "import { request } from './js/bridge.js';",
}
chunks = ["(() => {\n'use strict';\n"]
for name in paths:
    lines = (root / name).read_text().splitlines()
    for line in lines:
        if line.startswith("import "):
            if line not in allowed_imports:
                raise SystemExit(f"Unsupported module import in {name}")
            continue
        line = re.sub(r"^export (?=(?:async )?function )", "", line)
        if line.startswith("export "):
            raise SystemExit(f"Unsupported module export in {name}")
        chunks.append(line + "\n")
chunks.append("window.verifyAssetSelection = verifyAssetSelection;\n})();\n")
Path(sys.argv[1]).write_text("".join(chunks))
