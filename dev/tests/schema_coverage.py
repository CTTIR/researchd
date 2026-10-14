#!/usr/bin/env python3
"""
Phase 2 check: every SQL statement in the Python services and the R engine
prepares cleanly against db/schema.sql.

SQLite validates table and column names at prepare time, so preparing each
statement against a schema-only database is a real coverage test: a column
the code reads but the schema lacks fails here with "no such column".

Usage: python3 dev/tests/schema_coverage.py [repo_root]
"""
import ast, os, re, sqlite3, sys, pathlib

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
SQL_START = re.compile(r"^\s*(SELECT|INSERT|UPDATE|DELETE|REPLACE|WITH)\b", re.I)


def schema_db():
    con = sqlite3.connect(":memory:")
    con.executescript((ROOT / "db" / "schema.sql").read_text())
    # additive migrations from web/app.py must be applied too: an existing
    # deployment gains these columns there, not from schema.sql.
    src = (ROOT / "web" / "app.py").read_text()
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            getattr(t, "id", "") == "_MIGRATIONS" for t in node.targets
        ):
            for tup in ast.literal_eval(node.value):
                table, col, coldef = tup
                cols = {r[1] for r in con.execute(f"PRAGMA table_info({table})")}
                if col not in cols:
                    con.execute(f"ALTER TABLE {table} ADD COLUMN {col} {coldef}")
    return con


def py_statements(path):
    """SQL string constants and f-strings, with interpolations neutralised."""
    out = []
    tree = ast.parse(path.read_text())
    # Constants that are *parts* of an f-string are fragments, not statements.
    inner = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.JoinedStr):
            for v in node.values:
                if isinstance(v, ast.Constant):
                    inner.add(id(v))
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if id(node) in inner or not SQL_START.match(node.value):
                continue
            out.append((node.lineno, node.value))
        elif isinstance(node, ast.JoinedStr):
            parts = []
            for v in node.values:
                if isinstance(v, ast.Constant):
                    parts.append(v.value)
                else:
                    # every runtime interpolation in this codebase expands to
                    # either a parameter list ("?,?") or a fixed identifier.
                    parts.append("?")
            s = "".join(parts)
            if SQL_START.match(s):
                out.append((node.lineno, s))
    # printf-style placeholders are parameter lists too ("... IN (%s)" % marks)
    return [(ln, s.replace("%s", "?")) for ln, s in out]


R_SQL = re.compile(r'"((?:SELECT|INSERT|UPDATE|DELETE|REPLACE)[^"]*)"', re.I | re.S)


def r_statements(path):
    txt = path.read_text()
    out = []
    for m in R_SQL.finditer(txt):
        line = txt.count("\n", 0, m.start()) + 1
        out.append((line, m.group(1)))
    return out


def prepare(con, sql):
    """Prepare (not run) a statement; returns None on success or the error."""
    n = sql.count("?")
    named = set(re.findall(r"(?<![:\w]):([a-zA-Z_]\w*)", sql))
    try:
        cur = con.cursor()
        if named and not n:
            cur.execute("EXPLAIN " + sql, {k: None for k in named})
        else:
            cur.execute("EXPLAIN " + sql, [None] * n)
        return None
    except Exception as e:
        return str(e)


def main():
    con = schema_db()
    targets = []
    for p in ["web/app.py", "web/scheduler.py", "web/security.py"]:
        targets += [(p, ln, s) for ln, s in py_statements(ROOT / p)]
    for p in sorted(os.listdir(ROOT / "R")):
        if p.endswith(".R"):
            targets += [(f"R/{p}", ln, s) for ln, s in r_statements(ROOT / "R" / p)]

    bad = []
    for path, ln, sql in targets:
        err = prepare(con, sql)
        if err:
            bad.append((path, ln, sql, err))

    print(f"prepared {len(targets)} statements from "
          f"{len({t[0] for t in targets})} files")
    if not bad:
        print("OK: every statement prepares against the schema")
        return 0
    print(f"\n{len(bad)} statement(s) FAILED to prepare:\n")
    for path, ln, sql, err in bad:
        one = " ".join(sql.split())
        print(f"  {path}:{ln}: {err}\n      {one[:160]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
