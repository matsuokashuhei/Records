#!/usr/bin/env python3
"""Store Shelf の壁用の紙テクスチャを生成する。

生成物は Sleeves/Assets.xcassets/paper-<variant>.imageset/ に書き出す。
テクスチャは texture-generator (https://github.com/nmpowell/texture-generator)
の paper バリアントを使う。creases=0.0 にするとシームレスにタイルできる
(生成されるすべてのフィールドが周期化される)。

使い方:

    # Python 3.12+ が必要
    python3 -m venv .venv-texture
    .venv-texture/bin/pip install texture-generator
    .venv-texture/bin/python tools/generate-paper-textures.py

実行すると各 imageset の PNG を上書きする(Contents.json は上書きしない)。
seed を固定してあるので同じバージョンなら同じ画像が再現できる。
"""

import json
from pathlib import Path

from texture_generators import generate

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS = REPO_ROOT / "Sleeves" / "Assets.xcassets"

# 1024px のタイルを @2x アセットにして 512pt 幅で敷き詰める。
# mm_across は紙ごとの描画範囲(reference.md)の上限側に固定して、
# 壁面スケールで繊維が見えるようにする。
SIZE_PX = 1024
SEED = 42
SPECS = {
    "white": 22.0,      # 範囲 12-22 mm
    "kraft": 30.0,      # 範囲 16-30 mm
    "recycled": 24.0,   # 範囲 13-24 mm
    "newsprint": 26.0,  # 範囲 14-26 mm
    "laid": 44.0,       # 範囲 26-44 mm
    "coated": 22.0,     # 範囲 12-22 mm
}

CONTENTS = {
    "images": [
        {
            "idiom": "universal",
            "scale": "2x",
        }
    ],
    "info": {"author": "xcode", "version": 1},
}


def main() -> None:
    for variant, mm_across in SPECS.items():
        name = f"paper-{variant}"
        imageset = ASSETS / f"{name}.imageset"
        imageset.mkdir(parents=True, exist_ok=True)
        image = generate(
            "paper",
            size=SIZE_PX,
            seed=SEED,
            variant=variant,
            mm_across=mm_across,
            creases=0.0,  # シームレスタイルにする(折り目を入れない)
        )
        png = imageset / f"{name}.png"
        image.save(png)
        contents = json.loads(json.dumps(CONTENTS))
        contents["images"][0]["filename"] = png.name
        contents_path = imageset / "Contents.json"
        if not contents_path.exists():
            contents_path.write_text(
                json.dumps(contents, indent=2) + "\n", encoding="utf-8"
            )
        print(f"{name}: {image.size[0]}x{image.size[1]} -> {png}")


if __name__ == "__main__":
    main()
