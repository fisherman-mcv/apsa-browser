#!/usr/bin/env python3
# Compares outputs by the words they keep. Unknown sites only. Prints no page text.
import csv, json, re, sys, os, collections
dest = sys.argv[1]
threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
MIN_CHARS = 180
pages = json.load(open(os.path.join(dest, "pages.json")))
ok = [p for p in pages if p["status"] == "ok"]
index = {i: p for i, p in enumerate(pages) if p["status"] == "ok"}
scores = collections.defaultdict(dict)
if os.path.exists(os.path.join(dest, "scores.csv")):
    for row in csv.DictReader(open(os.path.join(dest, "scores.csv"))):
        scores[int(row["page"])][int(row["block"])] = float(row["score"])
def bag(text): return collections.Counter(re.findall(r"\w+", (text or "").lower()))
def metrics(output, gold):
    a, b = bag(output), bag(gold)
    hit = sum((a & b).values()); na, nb = sum(a.values()), sum(b.values())
    r = hit / nb if nb else 0; p = hit / na if na else 0
    return p, r, (2 * p * r / (p + r) if p + r else 0)
def model_output(i, p, t=threshold):
    kept = [p["texts"][b] for b, s in scores[i].items() if s >= t and b < len(p["texts"]) and p["kinds"][b] != "image"]
    text = " ".join(kept)
    return text if len(text) >= MIN_CHARS else ""
def report(name, output):
    rows, refuse_right, refuse_total, cats = [], 0, 0, collections.defaultdict(list)
    for i, p in index.items():
        text = output(i, p)
        if p["refuse"]:
            refuse_total += 1
            refuse_right += 1 if len(text) < MIN_CHARS else 0
            continue
        m = metrics(text, p["gold"]); rows.append(m); cats[p["category"]].append(m[2])
    if not rows: return
    f = sum(m[2] for m in rows) / len(rows)
    good = sum(1 for m in rows if m[2] >= 0.9) / len(rows)
    failed = sum(1 for m in rows if m[2] < 0.5) / len(rows)
    print(f"{name:12} F1 {f:.3f} | P {sum(m[0] for m in rows)/len(rows):.3f} R {sum(m[1] for m in rows)/len(rows):.3f} | F1>=.9: {good:.0%} | F1<.5: {failed:.0%} | correct refusal {refuse_right}/{refuse_total}")
    print("             " + " ".join(f"{c}:{sum(v)/len(v):.2f}" for c, v in sorted(cats.items())))
print("pages", len(ok), "with gold", sum(1 for p in ok if not p["refuse"]))
report("old reader", lambda i, p: p["old"])
report("Readability", lambda i, p: p["readability"])
if scores:
    for t in (0.3, 0.5, 0.7):
        report(f"model@{t}", lambda i, p, t=t: model_output(i, p, t))
    # Readability covers pages where the model finds nothing, and only long results,
    # so that a home page the model refused does not come back through the fallback.
    def hybrid(i, p, t=0.5, need=1500):
        text = model_output(i, p, t)
        return text if text else (p["readability"] if len(p["readability"] or "") >= need else "")
    for t in (0.5, 0.7):
        for need in (800, 1500, 3000):
            report(f"hybrid@{t}/{need}", lambda i, p, t=t, need=need: hybrid(i, p, t, need))
    # Paired comparison by site, the unit that is independent here.
    import random
    def by_site(output):
        sites = collections.defaultdict(list)
        for i, p in index.items():
            if not p["refuse"]:
                host = re.sub(r"^https?://", "", p["url"]).split("/")[0]
                sites[host].append(metrics(output(i, p), p["gold"])[2])
        return {h: sum(v) / len(v) for h, v in sites.items()}
    a_, b_ = by_site(lambda i, p: hybrid(i, p, 0.5, 1500)), by_site(lambda i, p: p["readability"])
    hosts = sorted(a_); random.seed(1)
    diffs = sorted(sum(a_[h] - b_[h] for h in random.choices(hosts, k=len(hosts))) / len(hosts) for _ in range(5000))
    print(f"hybrid@0.5/1500 minus Readability, by site: mean {sum(a_[h]-b_[h] for h in hosts)/len(hosts):+.3f}, 95% interval {diffs[125]:+.3f} to {diffs[4875]:+.3f}, sites {len(hosts)}")
    # Readability first. The model replaces it only when Readability lost most of what
    # the model is sure about, and a page both find weak is refused.
    def guarded(i, p, t=0.7, ratio=1.5, need=500):
        model = model_output(i, p, t); readable = p["readability"] or ""
        mw, rw = len(model.split()), len(readable.split())
        if mw < 40: return readable if len(readable) >= 1500 else ""
        if rw < 40 or mw >= ratio * rw: return model
        return readable
    for ratio in (1.25, 1.5, 2.0):
        report(f"guarded/{ratio}", lambda i, p, ratio=ratio: guarded(i, p, 0.7, ratio))
    def site_compare(name, chosen):
        c_, r_ = by_site(chosen), by_site(lambda i, p: p["readability"])
        hs = sorted(c_); random.seed(1)
        ds = sorted(sum(c_[h] - r_[h] for h in random.choices(hs, k=len(hs))) / len(hs) for _ in range(5000))
        print(f"{name} minus Readability, by site: mean {sum(c_[h]-r_[h] for h in hs)/len(hs):+.3f}, 95% interval {ds[125]:+.3f} to {ds[4875]:+.3f}")
    site_compare("guarded/1.5", lambda i, p: guarded(i, p, 0.7, 1.5))
    site_compare("guarded/2.0", lambda i, p: guarded(i, p, 0.7, 2.0))
    switched = [p["url"][:60] for i, p in index.items() if not p["refuse"] and guarded(i, p, 0.7, 1.5) != (p["readability"] or "")]
    print("switched away from Readability:", len(switched), "of", sum(1 for p in index.values() if not p["refuse"]))
    worst = sorted(((metrics(model_output(i, p), p["gold"]), p["url"]) for i, p in index.items() if not p["refuse"]), key=lambda x: x[0][2])[:8]
    print("worst for model@0.5:")
    for m, url in worst: print(f"  F1 {m[2]:.2f} P {m[0]:.2f} R {m[1]:.2f} {url[:72]}")
print("median extract ms", sorted(p["ms"] for p in ok)[len(ok)//2], "max", int(max(p["ms"] for p in ok)))
