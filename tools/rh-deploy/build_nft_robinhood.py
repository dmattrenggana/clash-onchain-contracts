#!/usr/bin/env python3
"""Build the Robinhood NFT level images + metadata JSONs.

Pipeline (reverse-engineered from the existing knight/archer sets):
  - The NFT image is the FULL card art (512x512 RGBA) plus a level badge.
  - Badge = white disc r46 + tier-coloured disc r40, centred at (66, 66) on
    the canvas (NOT offset with the card).
  - Tier canvases: L1-L2 512 (transparent), L3-L5 528, L6-L8 536, L9-L10 552.
    For the framed tiers the card is pasted centred (inset 8 / 12 / 20) on a
    solid tier-coloured background.
  - Tier colours: rare blue (60,130,245), epic purple (168,85,247),
    legendary gold (250,191,36). L1-L2 badge = grey (155,163,174).
"""

import json
import math
import os
from PIL import Image, ImageDraw

REPO = os.environ.get("CLASH_REPO", "/workspace/Clash-Onchain")
CARD_SRC = os.path.join(REPO, "public/cards/card-robinhood.webp")
OUT_DIR = os.environ.get("NFT_OUT_DIR", "/workspace/output/nft-robinhood")
BASE_URI = "https://ktrwdkrxsttdadqvudco.supabase.co/storage/v1/object/public/nft-assets/cards-generated"

CARD_TYPE_ID = 12
CARD_NAME = "Robinhood"
CARD_SLUG = "robinhood"
BASE_HP = 150
BASE_ATK = 30
BASE_ELIXIR = 3

TIERS = {
    1: dict(canvas=512, bg=None, badge=(155, 163, 174), rarity="common"),
    2: dict(canvas=512, bg=None, badge=(155, 163, 174), rarity="common"),
    3: dict(canvas=528, bg=(60, 130, 245), badge=(60, 130, 245), rarity="rare"),
    4: dict(canvas=528, bg=(60, 130, 245), badge=(60, 130, 245), rarity="rare"),
    5: dict(canvas=528, bg=(60, 130, 245), badge=(60, 130, 245), rarity="rare"),
    6: dict(canvas=536, bg=(168, 85, 247), badge=(168, 85, 247), rarity="epic"),
    7: dict(canvas=536, bg=(168, 85, 247), badge=(168, 85, 247), rarity="epic"),
    8: dict(canvas=536, bg=(168, 85, 247), badge=(168, 85, 247), rarity="epic"),
    9: dict(canvas=552, bg=(250, 191, 36), badge=(250, 191, 36), rarity="legendary"),
    10: dict(canvas=552, bg=(250, 191, 36), badge=(250, 191, 36), rarity="legendary"),
}

SS = 4  # supersampling for the badge edges


def scaled_stat(base: int, level: int) -> int:
    """stat_L = base * (1 + 0.2 * (L - 1)) — matches the existing card sets."""
    return int(round(base * (1 + 0.2 * (level - 1))))


def build_image(card: Image.Image, level: int) -> Image.Image:
    tier = TIERS[level]
    size = tier["canvas"]
    inset = (size - card.width) // 2

    if tier["bg"] is None:
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    else:
        canvas = Image.new("RGB", (size, size), tier["bg"])
    canvas.paste(card, (inset, inset), card)

    # badge
    big = Image.new("RGBA", (size * SS, size * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    cx = cy = 66 * SS
    d.ellipse([cx - 46 * SS, cy - 46 * SS, cx + 46 * SS, cy + 46 * SS], fill=(255, 255, 255, 255))
    d.ellipse([cx - 40 * SS, cy - 40 * SS, cx + 40 * SS, cy + 40 * SS], fill=(*tier["badge"], 255))
    badge = big.resize((size, size), Image.LANCZOS)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), badge)
    return canvas


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    card = Image.open(CARD_SRC).convert("RGBA")
    assert card.size == (512, 512), card.size

    for level in range(1, 11):
        tier = TIERS[level]
        img = build_image(card, level)
        path = os.path.join(OUT_DIR, f"{CARD_SLUG}-l{level}.webp")
        if tier["bg"] is None:
            img.save(path, "WEBP", quality=90, method=6)
        else:
            img.convert("RGB").save(path, "WEBP", quality=90, method=6)

        token_id = CARD_TYPE_ID * 256 + (level - 1)
        metadata = {
            "name": f"{CARD_NAME} #{token_id}",
            "description": f"Level {level} {CARD_SLUG} in Clash Onchain",
            "image": f"{BASE_URI}/{CARD_SLUG}-l{level}.webp",
            "attributes": [
                {"trait_type": "Card", "value": CARD_NAME},
                {"trait_type": "Card Type ID", "value": CARD_TYPE_ID},
                {"trait_type": "Level", "value": level},
                {"trait_type": "Rarity", "value": tier["rarity"]},
                {"trait_type": "Card Pool", "value": "epic"},
                {"trait_type": "HP", "value": scaled_stat(BASE_HP, level), "display_type": "number"},
                {"trait_type": "Attack", "value": scaled_stat(BASE_ATK, level), "display_type": "number"},
                {"trait_type": "Elixir Cost", "value": BASE_ELIXIR, "display_type": "number"},
                {"trait_type": "Edition", "value": "Genesis"},
                {"trait_type": "Type", "value": "Troop"},
            ],
        }
        with open(os.path.join(OUT_DIR, f"{token_id}.json"), "w") as f:
            json.dump(metadata, f, indent=2)
        print(f"  L{level:<2} {tier['canvas']}px {tier['rarity']:<10} hp={scaled_stat(BASE_HP,level):<4} "
              f"atk={scaled_stat(BASE_ATK,level):<3} -> {os.path.basename(path)} + {token_id}.json")

    print(f"\nwrote {len(os.listdir(OUT_DIR))} files to {OUT_DIR}")


if __name__ == "__main__":
    main()
