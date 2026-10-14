#!/usr/bin/env python3
# ============================================================
# decrypt_key.py — decrypt one Fernet token from stdin, print plaintext.
# Used by the R engine to recover per-question API keys at fetch time.
# Reads APP_SECRET_KEY from the environment. Prints nothing on failure.
#   echo "<token>" | python3 decrypt_key.py
# ============================================================
import os, sys
try:
    from cryptography.fernet import Fernet, InvalidToken
except Exception:
    sys.exit(1)

key = os.environ.get("APP_SECRET_KEY", "")
token = sys.stdin.read().strip()
if not key or not token:
    sys.exit(0)
try:
    sys.stdout.write(Fernet(key.encode()).decrypt(token.encode()).decode())
except (InvalidToken, Exception):
    sys.exit(0)
