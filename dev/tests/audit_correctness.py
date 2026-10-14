#!/usr/bin/env python3
"""Audit pass — correctness probes not already covered by a phase test:
ingest-seam parity with R's dedup keys, the instant-alert tier, and signals
in the digest. Probes 1-10 are covered by the phase suites (see AUDIT_LOG)."""
import json, os, pathlib, re, sqlite3, subprocess, sys
from datetime import datetime, timedelta, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
TMP = ROOT / "dev" / "state" / "tmp"; TMP.mkdir(parents=True, exist_ok=True)
DB = TMP / "audit_c.sqlite"
for suf in ("", "-wal", "-shm"):
    pathlib.Path(str(DB) + suf).unlink(missing_ok=True)

from cryptography.fernet import Fernet
os.environ.update(DB_PATH=str(DB), APP_SECRET_KEY=Fernet.generate_key().decode(),
                  SECURE_COOKIE="0", API_TOKEN="a-token", INGEST_TOKEN="i-token",
                  SMTP_HOST="smtp.invalid", SMTP_FROM="p@x", SMTP_USER="p@x",
                  EMAIL_PW="pw", SMTP_TLS="starttls")

from fastapi.testclient import TestClient
from web.app import app, INGEST_MAX_SCORE
from web import scheduler as sch

fails = []
def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if (detail and not ok) else ""))
    if not ok: fails.append(name)

c = TestClient(app, follow_redirects=False)
ING = {"Authorization": "Bearer i-token"}
con = sqlite3.connect(DB)
con.execute("INSERT INTO questions(id,label,email_enabled,email_cron,email_to)"
            " VALUES('q','Q',1,'0 7 * * *',?)", (json.dumps(["a@example.org"]),))
con.execute("INSERT INTO signal_config(question_id,min_confidence,instant_alerts)"
            " VALUES('q','reported',1)")
con.commit(); con.close()

# ---------------------------------------------------- 11. ingest seam parity
print("11. ingest seam parity with the R dedup keys")
check("no token -> 401", c.post("/api/ingest", json={"records": []}).status_code == 401)

DOI, TITLE, YEAR = "https://doi.org/10.1000/ABC", "GLP-1 in MASH", "2026"
r = c.post("/api/ingest", headers=ING, json={"records": [
    {"question_id": "q", "title": TITLE, "doi": DOI, "pub_date": "2026-01-10",
     "source": "ingest:scholar", "score": 999.0},
    {"question_id": "q", "title": "No DOI here", "pub_date": "2026-02-01",
     "source": "ingest:scholar"},
    {"question_id": "nope", "title": "Wrong question", "pub_date": "2026-01-01"}]})
check("valid payload accepted", r.status_code == 200, r.text[:200])
body = r.json()
check("two records inserted", body["records"]["inserted"] == 2, json.dumps(body))
check("an unknown question_id is skipped with a reason",
      any("unknown question_id" in s["reason"] for s in body.get("skipped", [])),
      json.dumps(body.get("skipped")))

con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
got = {r["title"]: dict(r) for r in con.execute("SELECT * FROM records")}
con.close()
check("the posted score is capped", got[TITLE]["score"] == INGEST_MAX_SCORE,
      str(got[TITLE]["score"]))
check("ingested records land unclassified for R to classify",
      got[TITLE]["study_type"] == "unclassified", got[TITLE]["study_type"])

# The key must be byte-identical to what R/03_dedup.R computes, or an
# ingested Scholar alert and the PubMed hit for the same paper never collapse.
r_key = subprocess.run([str(ROOT / "dev" / "tests" / "Rrun.sh"), "-e",
    'source("R/00_utils.R"); source("R/03_dedup.R");'
    'a <- commandArgs(TRUE);'
    'd <- .norm_doi(a[1]); t <- .norm_title(a[2]);'
    'cat(if (nzchar(d)) paste0("doi:", d) else paste0("ti:", t, "|", a[3]), "\\n", sep="")',
    DOI, TITLE, YEAR], cwd=ROOT, capture_output=True, text=True)
check("R and the ingest endpoint compute the SAME dedup key for a DOI record",
      r_key.stdout.strip() == got[TITLE]["dedup_key"],
      f"R={r_key.stdout.strip()!r} ingest={got[TITLE]['dedup_key']!r}")
r_key2 = subprocess.run([str(ROOT / "dev" / "tests" / "Rrun.sh"), "-e",
    'source("R/00_utils.R"); source("R/03_dedup.R");'
    'a <- commandArgs(TRUE); cat(paste0("ti:", .norm_title(a[1]), "|", a[2]), "\\n", sep="")',
    "No DOI here", "2026"], cwd=ROOT, capture_output=True, text=True)
check("...and for a DOI-less record (title+year fallback)",
      r_key2.stdout.strip() == got["No DOI here"]["dedup_key"],
      f"R={r_key2.stdout.strip()!r} ingest={got['No DOI here']['dedup_key']!r}")

# the same paper, posted in a different surface form, must collapse
r = c.post("/api/ingest", headers=ING, json={"records": [
    {"question_id": "q", "title": TITLE, "doi": "10.1000/abc",
     "pub_date": "2026-01-10", "source": "ingest:ir"}]})
check("the same DOI in a different case/prefix is a duplicate, not a new row",
      r.json()["records"]["duplicates"] == 1 and r.json()["records"]["inserted"] == 0,
      json.dumps(r.json()))
con = sqlite3.connect(DB)
check("...and no second row was written",
      con.execute("SELECT COUNT(*) FROM records").fetchone()[0] == 2)
con.close()

r = c.post("/api/ingest", headers=ING, json={"signals": [
    {"question_id": "q", "title": "Bad type", "signal_type": "not_a_type"},
    {"question_id": "q", "title": "Bad confidence", "signal_type": "sec_filing",
     "confidence": "gossip"},
    {"question_id": "q", "title": "Good signal", "signal_type": "sec_filing",
     "confidence": "authoritative", "ext_id": "8K-1", "score": 999.0}]})
sk = {s["title"]: s["reason"] for s in r.json().get("skipped", [])}
check("an invalid signal_type is skipped with a reason",
      any("signal_type" in v for v in sk.values()), json.dumps(sk))
check("an invalid confidence is skipped with a reason",
      any("confidence" in v for v in sk.values()), json.dumps(sk))
check("the valid signal is inserted", r.json()["signals"]["inserted"] == 1, json.dumps(r.json()))
con = sqlite3.connect(DB)
check("the posted signal score is capped too",
      con.execute("SELECT score FROM signals WHERE title='Good signal'").fetchone()[0]
      == INGEST_MAX_SCORE)
con.close()

# ------------------------------------------------------------ 12. alert tier
print("\n12. the instant-alert tier")
SENT = []
sch.send_email = lambda to, s, h: (SENT.append({"to": list(to), "subject": s, "html": h}), True)[1]
con = sqlite3.connect(DB)
con.execute("INSERT INTO signals(dedup_key,question_id,signal_type,source,title,"
            "signal_date,confidence,score,emailed) VALUES"
            "('lo','q','press_release','t','Unverified rumour','2026-08-10','unverified',5,0)")
con.commit(); con.close()
sch.run_alerts()
check("a high-priority signal at confidence >= reported triggers an instant alert",
      len(SENT) == 1 and "ALERT" in SENT[0]["subject"], json.dumps([m["subject"] for m in SENT]))
if SENT:
    check("the alert contains the authoritative signal", "Good signal" in SENT[0]["html"])
    check("an unverified signal never triggers an instant alert",
          "Unverified rumour" not in SENT[0]["html"])
con = sqlite3.connect(DB)
check("the alerted signal is marked emailed",
      con.execute("SELECT emailed FROM signals WHERE title='Good signal'").fetchone()[0] == 1)
check("the unverified one is untouched",
      con.execute("SELECT emailed FROM signals WHERE title='Unverified rumour'").fetchone()[0] == 0)
con.close()
SENT.clear(); sch.run_alerts()
check("a second tick does not re-alert", len(SENT) == 0, str(len(SENT)))

# -------------------------------------------------------- 13. digest signals
print("\n13. signals in the digest, honouring min_confidence")
con = sqlite3.connect(DB)
con.execute("INSERT INTO signals(dedup_key,question_id,signal_type,source,title,"
            "signal_date,confidence,score,emailed) VALUES"
            "('rep','q','trial_result','t','Reported topline','2026-08-11','reported',7,0)")
con.execute("UPDATE questions SET email_last_sent=? WHERE id='q'",
            ((datetime.now().astimezone() - timedelta(days=2)).isoformat(),))
con.commit(); con.close()
SENT.clear(); sch.run_once()
check("a digest was sent", len(SENT) == 1, str(len(SENT)))
if SENT:
    html = SENT[0]["html"]
    check("the digest has a signals section", "Signals (early intelligence)" in html)
    check("it includes signals at or above min_confidence", "Reported topline" in html)
    check("it excludes signals below min_confidence (min_confidence='reported')",
          "Unverified rumour" not in html)
    check("the subject counts papers and signals separately",
          re.search(r"\d+ papers, \d+ signals", SENT[0]["subject"]) is not None,
          SENT[0]["subject"])
con = sqlite3.connect(DB)
check("digested signals are marked emailed",
      con.execute("SELECT emailed FROM signals WHERE title='Reported topline'").fetchone()[0] == 1)
check("the below-threshold signal stays unemailed, so raising the floor later "
      "still delivers it",
      con.execute("SELECT emailed FROM signals WHERE title='Unverified rumour'").fetchone()[0] == 0)
con.close()
SENT.clear(); sch.run_once()
check("the digest does not resend what the alert tier already sent", len(SENT) == 0)

# ------------------------------- source health tells broken from quiet
print("\nsource health distinguishes a BROKEN source from a QUIET one")
con = sqlite3.connect(DB)
con.execute("INSERT INTO fetch_log(question_id,track,source,n_fetched,ok)"
            " VALUES('q','lit','pubmed',12,1)")
con.execute("INSERT INTO fetch_log(question_id,track,source,n_fetched,ok)"
            " VALUES('q','lit','europepmc',0,0)")     # errored
con.execute("INSERT INTO fetch_log(question_id,track,source,n_fetched,ok)"
            " VALUES('q','lit','crossref',0,1)")      # ran, found nothing
con.commit(); con.close()
sh = {x["source"]: x for x in c.get("/api/v1/source_health",
      headers={"Authorization": "Bearer a-token"}).json()["sources"]}
check("a broken source records an error run", sh["europepmc"]["error_runs"] == 1,
      json.dumps(sh["europepmc"]))
check("...and never advances last_ok", sh["europepmc"]["last_ok"] is None,
      json.dumps(sh["europepmc"]))
check("a source that ran but found nothing advances last_ok",
      sh["crossref"]["last_ok"] is not None and sh["crossref"]["error_runs"] == 0,
      json.dumps(sh["crossref"]))
check("...but not last_nonempty, so a silently-narrowing query is visible",
      sh["crossref"]["last_nonempty"] is None, json.dumps(sh["crossref"]))
check("a healthy source advances both",
      sh["pubmed"]["last_ok"] and sh["pubmed"]["last_nonempty"],
      json.dumps(sh["pubmed"]))

print()
if fails:
    print(f"FAILED: {len(fails)} check(s):"); [print("   -", f) for f in fails]; sys.exit(1)
print("ALL AUDIT CORRECTNESS PROBES PASSED"); sys.exit(0)
