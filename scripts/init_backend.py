"""Create local development credentials without printing or replacing secrets."""
import os
from pathlib import Path
import secrets

destination = Path(__file__).resolve().parents[1] / "backend" / ".env"
try:
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    raise SystemExit("backend/.env already exists; kept existing credentials.")
with os.fdopen(descriptor, "w") as output:
    output.write(f"SAGE_TOKEN={secrets.token_hex(32)}\n")
    output.write(f"SAGE_DATA_KEY={secrets.token_hex(32)}\n")
    output.write("SAGE_BIND=127.0.0.1:8787\nSAGE_DB=data/sage.sqlite\n")
print("Created backend/.env with owner-only permissions. Keep its encryption key.")
