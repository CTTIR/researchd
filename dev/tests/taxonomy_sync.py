#!/usr/bin/env python3
"""ACCEPTANCE A2: the study-type taxonomy and its ORDER must be identical in
R/06_classify.R, web/app.py and web/scheduler.py. Ordering is load-bearing
(systematic_review before rct, review after systematic_review), and the three
files carry independent copies of it."""
import ast, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
fails = []

def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        fails.append(name)

def py_names(path, order_name, label_name):
    tree = ast.parse((ROOT / path).read_text())
    order = labels = None
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if getattr(t, "id", "") == order_name:
                    order = ast.literal_eval(n.value)
                if getattr(t, "id", "") == label_name:
                    labels = ast.literal_eval(n.value)
    return order, labels

def r_names():
    src = (ROOT / "R" / "06_classify.R").read_text()
    blk = re.search(r"STUDY_TYPE_ORDER <- c\((.*?)\)", src, re.S).group(1)
    order = re.findall(r'"([a-z_]+)"', blk)
    blk = re.search(r"STUDY_TYPE_LABEL <- c\((.*?)\n\)", src, re.S).group(1)
    labels = dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', blk))
    return order, labels

r_order, r_labels = r_names()
a_labels, _ = py_names("web/app.py", "STUDY_LABELS", "__none__")
a_order = list(a_labels) if a_labels else None
s_order, s_labels = py_names("web/scheduler.py", "STUDY_ORDER", "STUDY_LABEL")

check("R/06_classify.R exposes STUDY_TYPE_ORDER", bool(r_order), str(r_order))
check("web/app.py exposes STUDY_LABELS", bool(a_labels))
check("web/scheduler.py exposes STUDY_ORDER", bool(s_order))

# THE acceptance criterion: same buckets, same sequence, in all three files.
# (app.py carries the order implicitly, as STUDY_LABELS' insertion order --
# that dict is what /feed/{id}/{stype}.xml validates against.)
check("R order == app.py order (same buckets, same sequence)", r_order == a_order,
      f"R={r_order} app={a_order}")
check("R order == scheduler.py order", r_order == s_order,
      f"R={r_order} sch={s_order}")
check("every ordered bucket has a label in every file",
      set(r_order or []) == set(r_labels) == set(a_labels or {}) == set(s_labels or {}),
      f"R={sorted(set(r_order or []) - set(r_labels))} "
      f"app={sorted(set(r_order or []) - set(a_labels or {}))} "
      f"sch={sorted(set(r_order or []) - set(s_labels or {}))}")

# Label TEXT deliberately differs: app.py renders one label per RSS <category>
# (singular, per item), while R and the scheduler use them as digest section
# headings (plural). Same buckets, different voice -- shown, not enforced.
check("R and scheduler.py agree on digest section headings", r_labels == s_labels,
      str({k: (r_labels.get(k), s_labels.get(k))
           for k in set(r_labels) | set(s_labels) if r_labels.get(k) != s_labels.get(k)}))
print("\n  note — per-item RSS category labels in app.py differ in wording by design:")
for k in (r_order or []):
    if r_labels.get(k) != (a_labels or {}).get(k):
        print(f"      {k:18} digest={r_labels.get(k)!r}  rss={(a_labels or {}).get(k)!r}")
print()

# the two load-bearing precedence rules, asserted directly
if r_order:
    i = {k: n for n, k in enumerate(r_order)}
    check("systematic_review precedes rct", i["systematic_review"] < i["rct"])
    check("rct precedes clinical_trial", i["rct"] < i["clinical_trial"])
    check("narrative review follows systematic_review", i["review"] > i["systematic_review"])
    check("unclassified is last (recall safety net)", r_order[-1] == "unclassified")

print()
if fails:
    print(f"FAILED: {len(fails)} check(s): " + "; ".join(fails)); sys.exit(1)
print("TAXONOMY IS IN SYNC ACROSS ALL THREE FILES"); sys.exit(0)
