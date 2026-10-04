#!/bin/sh
set -eu
cd "$(dirname "$0")/../backend"
if [ ! -f .env ]; then
  echo 'Run python3 scripts/init_backend.py from the project root first.' >&2
  exit 1
fi
umask 077
set -a
. ./.env
set +a
exec cargo run --locked
