#!/usr/bin/env python3
"""Phase 2 checks: idempotency, WAL, busy_timeout contention, FK cascade."""
import json, os, pathlib, sqlite3, sys, threading, time

ROOT = pathlib.Path(__file__).resolve().parents[2]
TMP = ROOT / "dev" / "state" / "tmp"
TMP.mkdir(parents=True, exist_ok=True)
SCHEMA = (ROOT / "db" / "schema.sql").read_text()
fails = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        fails.append(name)


def fresh(name):
    p = TMP / name
    for suf in ("", "-wal", "-shm"):
        pathlib.Path(str(p) + suf).unlink(missing_ok=True)
    return p


print("1. schema idempotency")
p = fresh("p2_idem.sqlite")
con = sqlite3.connect(p)
con.executescript(SCHEMA)
try:
    con.executescript(SCHEMA)
    check("applying schema.sql twice raises nothing", True)
except Exception as e:
    check("applying schema.sql twice raises nothing", False, repr(e))
import re as _re
creates = [l for l in SCHEMA.splitlines() if _re.match(r"\s*CREATE\s", l, _re.I)]
noguard = [l.strip() for l in creates if "IF NOT EXISTS" not in l.upper()]
check("every CREATE is guarded by IF NOT EXISTS", not noguard, "; ".join(noguard))

print("\n2. WAL")
mode = con.execute("PRAGMA journal_mode").fetchone()[0]
check("journal_mode is wal after applying schema.sql", mode.lower() == "wal", mode)
con.close()

print("\n3. busy_timeout contention (writer holds, second writer waits)")
p = fresh("p2_busy.sqlite")
a = sqlite3.connect(p, timeout=10)
a.executescript(SCHEMA)
a.execute("INSERT INTO questions(id,label) VALUES('q1','Q1')")
a.commit()
a.execute("BEGIN IMMEDIATE")
a.execute("INSERT INTO questions(id,label) VALUES('q2','Q2')")  # write lock held

result = {}
def second_writer():
    b = sqlite3.connect(p, timeout=0.1)          # deliberately short
    b.execute("PRAGMA busy_timeout=5000;")       # ...then the real setting
    t0 = time.time()
    try:
        b.execute("INSERT INTO questions(id,label) VALUES('q3','Q3')")
        b.commit()
        result["ok"], result["waited"] = True, time.time() - t0
    except Exception as e:
        result["ok"], result["err"], result["waited"] = False, repr(e), time.time() - t0
    finally:
        b.close()

t = threading.Thread(target=second_writer); t.start()
time.sleep(1.0)          # hold the lock for a second
a.commit(); a.close()    # release
t.join(10)
check("second writer waits out the lock and succeeds",
      result.get("ok") is True,
      f"waited {result.get('waited', 0):.2f}s" + (f" err={result.get('err')}" if not result.get("ok") else ""))
check("it really blocked rather than racing through",
      result.get("waited", 0) >= 0.5, f"{result.get('waited', 0):.2f}s")

print("\n4. foreign-key cascade")
p = fresh("p2_fk.sqlite")
c = sqlite3.connect(p)
c.executescript(SCHEMA)
c.execute("PRAGMA foreign_keys=ON;")
c.execute("INSERT INTO questions(id,label) VALUES('q1','Q1')")
c.execute("INSERT INTO concepts(question_id,name) VALUES('q1','drug')")
c.execute("INSERT INTO records(dedup_key,question_id,title) VALUES('doi:1','q1','T')")
c.execute("INSERT INTO signals(dedup_key,question_id,signal_type) VALUES('sig:1','q1','grant')")
c.execute("INSERT INTO signal_config(question_id) VALUES('q1')")
c.commit()
c.execute("DELETE FROM questions WHERE id='q1'")
c.commit()
left = {t: c.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        for t in ("concepts", "records", "signals", "signal_config")}
check("deleting a question cascades to all child tables",
      all(v == 0 for v in left.values()), json.dumps(left))

print("\n5. foreign keys are enforced (orphan rejected)")
try:
    c.execute("INSERT INTO records(dedup_key,question_id,title) VALUES('doi:2','ghost','T')")
    c.commit()
    check("orphan record is rejected", False, "insert succeeded")
except sqlite3.IntegrityError:
    check("orphan record is rejected", True)
c.close()

print("\n6. connections that mutate set foreign_keys / busy_timeout")
app = (ROOT / "web" / "app.py").read_text()
sch = (ROOT / "web" / "scheduler.py").read_text()
run = (ROOT / "R" / "run_all.R").read_text()
check("web/app.py sets busy_timeout", "busy_timeout" in app)
check("web/app.py sets foreign_keys=ON", "foreign_keys=ON" in app)
check("web/scheduler.py sets busy_timeout", "busy_timeout" in sch)
check("R/run_all.R sets journal_mode=WAL", "journal_mode=WAL" in run)
check("R/run_all.R sets busy_timeout", "busy_timeout" in run)

print()
if fails:
    print(f"FAILED: {len(fails)} check(s): " + "; ".join(fails)); sys.exit(1)
print("ALL PHASE 2 CHECKS PASSED"); sys.exit(0)
