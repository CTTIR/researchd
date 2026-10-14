#!/usr/bin/env python3
"""Phase 6 — the three services composing through the one shared database.

The services never call each other; they coordinate only through SQLite. So
integration here means driving the real web service, the real R engine (with
only its seven network fetchers mocked) and the real scheduler in sequence
over one database file, and checking the state contract between them.
"""
import json, os, pathlib, re, sqlite3, subprocess, sys, threading, time
from datetime import datetime, timedelta, timezone
from xml.etree import ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
TMP = ROOT / "dev" / "state" / "tmp"; TMP.mkdir(parents=True, exist_ok=True)
DB = TMP / "p6.sqlite"
for suf in ("", "-wal", "-shm"):
    pathlib.Path(str(DB) + suf).unlink(missing_ok=True)

from cryptography.fernet import Fernet
KEY = Fernet.generate_key().decode()
os.environ.update(DB_PATH=str(DB), APP_SECRET_KEY=KEY, SECURE_COOKIE="0",
                  BASE_URL="http://testserver", API_TOKEN="p6-token",
                  SMTP_HOST="smtp.invalid", SMTP_FROM="p@x", SMTP_USER="p@x",
                  EMAIL_PW="pw", SMTP_TLS="starttls")

import pyotp
from fastapi.testclient import TestClient
from web.app import app
from web import scheduler as sch

fails = []
def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if (detail and not ok) else ""))
    if not ok: fails.append(name)

def rows(sql, params=()):
    con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
    out = [dict(r) for r in con.execute(sql, params)]; con.close(); return out

def engine(batch="first"):
    """One real R engine cycle with the fetchers mocked."""
    return subprocess.run(
        [str(ROOT / "dev" / "tests" / "Rrun.sh"),
         "dev/tests/engine_step.R", str(DB), "glp1_mash", batch],
        cwd=ROOT, capture_output=True, text=True,
        env=dict(os.environ, APP_SECRET_KEY=KEY))

PLAIN_KEY = "NCBI-KEY-THAT-CROSSES-THE-SEAM"

# ---------------------------------------------------------------- a. web setup
print("a. web service: admin, 2FA, and a question")
c = TestClient(app, follow_redirects=False)
c.post("/setup", data={"username": "admin", "password": "correct-horse-battery",
                       "password2": "correct-horse-battery"})
c.post("/login", data={"username": "admin", "password": "correct-horse-battery"})
c.get("/2fa/enroll")
secret = rows("SELECT totp_secret FROM auth WHERE id=1")[0]["totp_secret"]
c.post("/2fa/enroll", data={"code": pyotp.TOTP(secret).now()})
check("the dashboard opens after enrollment", c.get("/").status_code == 200)

Q = {"id": "glp1_mash", "label": "GLP-1 in MASH",
     "concepts": [{"name": "drug", "terms": ["semaglutide", "tirzepatide"], "mesh": []},
                  {"name": "disease", "terms": ["steatohepatitis", "nash"], "mesh": []}],
     "study_filter": [], "from_days_back": 14, "enabled": True,
     "sources": {"pubmed": True, "europepmc": True, "clinicaltrials": True,
                 "biorxiv": True, "openalex": False, "crossref": False,
                 "semanticscholar": False},
     "api_keys": {"pubmed": PLAIN_KEY},
     "delivery": ["file"], "email_enabled": True, "email_cron": "0 7 * * *",
     "email_to": ["one@example.org", "two@example.org"],
     "digest_mode": "all", "min_score": 0.0}
check("the question is created through the web API",
      c.post("/api/questions", json=Q).status_code == 200)
enc = json.loads(rows("SELECT api_keys_enc FROM questions WHERE id='glp1_mash'")[0]["api_keys_enc"])
check("its API key is stored as ciphertext", enc["pubmed"].startswith("gAAAA"))

# ------------------------------------------------------- b/c. the engine runs
print("\nb. the R engine reads that question and writes records")
r = engine("first")
if r.returncode != 0:
    check("the engine run completed", False, (r.stderr or "")[-400:])
else:
    check("the engine run completed", True)
out = r.stdout

# THE KEY SEAM: encrypted by the web service, decrypted by the engine.
m = re.search(r"^DECRYPTED_KEY=(.*)$", out, re.M)
check("the engine decrypted the key the web service encrypted",
      m is not None and m.group(1) == PLAIN_KEY, m.group(1) if m else out[-200:])
m = re.search(r"^SOURCES_ON=(.*)$", out, re.M)
on = sorted(m.group(1).split(",")) if m else []
check("the engine sees exactly the sources the question enabled",
      on == ["biorxiv", "clinicaltrials", "europepmc", "pubmed"], str(on))

recs = rows("SELECT * FROM records WHERE question_id='glp1_mash'")
check("records were written", len(recs) > 0, str(len(recs)))
check("the cross-source DOI duplicate collapsed to one row",
      sum(1 for x in recs if (x["doi"] or "").lower() == "10.1/rct") == 1,
      str([x["doi"] for x in recs]))
check("the surviving duplicate is the higher-priority source",
      next(x["source"] for x in recs if (x["doi"] or "").lower() == "10.1/rct") == "pubmed")
buckets = {x["study_type"] for x in recs}
check("records span at least three study-type buckets", len(buckets) >= 3, str(buckets))
check("the preprint is flagged", any(x["is_preprint"] == 1 for x in recs))
check("the preprint kept its study type rather than becoming a bucket",
      next(x["study_type"] for x in recs if x["is_preprint"] == 1) == "rct",
      str([(x["study_type"], x["is_preprint"]) for x in recs]))
check("every record carries a score", all(x["score"] is not None for x in recs))
check("the fetch heartbeat was written for each enabled source",
      {x["source"] for x in rows("SELECT source FROM fetch_log")} ==
      {"pubmed", "epmc", "ct", "bio"},
      str({x["source"] for x in rows("SELECT source FROM fetch_log")}))

# --------------------------------------------------------------- d. the feeds
print("\nd. the web service serves what the engine wrote")
def feed(path):
    resp = c.get(path)
    if resp.status_code != 200:
        check(f"GET {path}", False, str(resp.status_code)); return None
    try:
        root = ET.fromstring(resp.text)
    except ET.ParseError as e:
        check(f"{path} parses as XML", False, str(e)); return None
    return root

root = feed("/feed/glp1_mash/all.xml")
check("the default feed serves the engine's records",
      root is not None and len(list(root.iter("item"))) == len(recs),
      str(len(list(root.iter("item")))) if root is not None else "")
by_type = {}
for st in buckets:
    r2 = feed(f"/feed/glp1_mash/{st}.xml")
    by_type[st] = len(list(r2.iter("item"))) if r2 is not None else -1
check("the by-type feeds partition the record set exactly",
      sum(by_type.values()) == len(recs), json.dumps(by_type))
pre = feed("/feed/glp1_mash/preprints.xml")
check("the preprints feed returns exactly the preprint",
      pre is not None and len(list(pre.iter("item"))) == 1)

# ------------------------------------------------------------ e. the scheduler
print("\ne. the scheduler mails what the engine wrote")
SENT = []
sch.send_email = lambda to, subj, html: (SENT.append({"to": list(to), "subject": subj, "html": html}), True)[1]
con = sqlite3.connect(DB)
con.execute("UPDATE questions SET email_last_sent=? WHERE id='glp1_mash'",
            ((datetime.now().astimezone() - timedelta(days=2)).isoformat(),))
con.commit(); con.close()
sch.run_once()
check("one digest was sent", len(SENT) == 1, str(len(SENT)))
if SENT:
    check("to both recipients", SENT[0]["to"] == ["one@example.org", "two@example.org"])
    check("grouped by study type", "Randomized controlled trials" in SENT[0]["html"])
    check("the preprint marker survived the whole chain", ">preprint<" in SENT[0]["html"])
check("every record is now marked emailed",
      all(x["emailed"] == 1 for x in rows("SELECT emailed FROM records WHERE question_id='glp1_mash'")))

# --------------------------------------------------------- f. idempotency
print("\nf. re-running everything with no new upstream data")
before = len(recs)
r = engine("repeat")
after = rows("SELECT * FROM records WHERE question_id='glp1_mash'")
check("a second engine run over the identical batch adds nothing",
      len(after) == before, f"{before} -> {len(after)}")
check("...and reports 0 new", re.search(r"^NEW=0$", r.stdout, re.M) is not None,
      r.stdout[-200:])
r = engine("empty")
check("an engine run with every source empty is also harmless",
      len(rows("SELECT * FROM records WHERE question_id='glp1_mash'")) == before)
SENT.clear(); sch.run_once()
check("a second scheduler run sends nothing", len(SENT) == 0, str(len(SENT)))

# -------------------------------------------------- 3. concurrency under load
print("\n3. reads succeed while a write is held (WAL)")
holder = sqlite3.connect(DB, timeout=10)
holder.execute("PRAGMA busy_timeout=10000;")
holder.execute("BEGIN IMMEDIATE")
holder.execute("INSERT INTO records(dedup_key,question_id,title) VALUES('held','glp1_mash','held')")
results = {}
def reader():
    try:
        results["feed"] = TestClient(app).get("/feed/glp1_mash/all.xml").status_code
        results["api"] = TestClient(app).get(
            "/api/v1/records", headers={"Authorization": "Bearer p6-token"},
            params={"question_id": "glp1_mash"}).status_code
    except Exception as e:
        results["error"] = repr(e)
t = threading.Thread(target=reader); t.start(); time.sleep(0.6)
t.join(15)
holder.rollback(); holder.close()
check("a feed read succeeded while the write lock was held",
      results.get("feed") == 200, json.dumps(results))
check("an API read succeeded while the write lock was held",
      results.get("api") == 200, json.dumps(results))
check("no lock error surfaced to the reader", "error" not in results, results.get("error", ""))

print()
if fails:
    print(f"FAILED: {len(fails)} check(s):"); [print("   -", f) for f in fails]; sys.exit(1)
print("ALL PHASE 6 CHECKS PASSED"); sys.exit(0)
