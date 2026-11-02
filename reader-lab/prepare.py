#!/usr/bin/env python3
# Turns captures into training rows, grouped by site so a fold never sees its own site.
import csv, glob, hashlib, json, os, re, sys
out, dest = sys.argv[1], sys.argv[2]
FOLDS = 5
def host(url):
    h = re.sub(r"^https?://", "", url).split("/")[0].lower()
    return re.sub(r"^(www|old|en|ru|de|fr|docs|doc|blog)\.", "", h)
pages, rows, names = [], [], None
for path in glob.glob(os.path.join(out, "*.json")):
    row = json.load(open(path))
    blocks = json.loads(row["blocks"]) if row["blocks"] else []
    meta = json.loads(row["meta"]) if row["meta"] else {}
    labels = meta.get("labels") or []
    gold = meta.get("goldText") or ""
    refuse = bool(row.get("refuse"))
    if not blocks or len(labels) != len(blocks): pages.append({"url": row["url"], "status": "no blocks"}); continue
    if not refuse and len(re.sub(r"\s+", " ", gold)) < 300: pages.append({"url": row["url"], "status": f"gold too small: {len(gold)}"}); continue
    fold = int(hashlib.sha1(host(row["url"]).encode()).hexdigest(), 16) % FOLDS
    pages.append({"url": row["url"], "status": "ok", "category": row["category"], "fold": fold, "refuse": refuse, "blocks": len(blocks), "ms": row["extractMs"], "gold": gold, "old": row["old"], "readability": row["readability"], "texts": [b["text"] for b in blocks], "kinds": [b["kind"] for b in blocks]})
    for i, block in enumerate(blocks):
        names = names or sorted(block["features"])
        rows.append([fold, len(pages) - 1, i, labels[i]] + [block["features"][n] for n in names])
with open(os.path.join(dest, "rows.csv"), "w", newline="") as f:
    w = csv.writer(f); w.writerow(["fold", "page", "block", "label"] + names); w.writerows(rows)
json.dump(pages, open(os.path.join(dest, "pages.json"), "w"), ensure_ascii=False)
ok = [p for p in pages if p["status"] == "ok"]
print("pages ok", len(ok), "dropped", len(pages) - len(ok), "rows", len(rows), "positive", sum(r[3] for r in rows))
for p in pages:
    if p["status"] != "ok": print("  dropped", p["url"][:70], p["status"])
