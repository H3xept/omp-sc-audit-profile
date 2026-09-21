#!/usr/bin/env bash
# Install this repo as the omp "audit" profile.
#
# Copies the profile source into ~/.omp/profiles/audit/agent/ and leaves your
# local secrets and session history untouched. Re-run after every git pull.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${OMP_PROFILE_NAME:-audit}"
DEST="$HOME/.omp/profiles/$PROFILE/agent"

command -v rsync >/dev/null || { echo "error: rsync not found" >&2; exit 1; }

mkdir -p "$DEST/rules"

# --delete keeps the install exact: a prompt file removed upstream does not
# linger locally. Excluded paths are protected from deletion by rsync, so
# secrets and session history survive.
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.github/' \
  --exclude 'install.sh' \
  --exclude 'README.md' \
  --exclude '.gitignore' \
  --exclude '.env' \
  --exclude '.env.example' \
  --exclude 'mcp.json' \
  --exclude 'mcp.json.example' \
  --exclude 'mcp.json.lock' \
  --exclude 'sessions/' \
  --exclude 'terminal-sessions/' \
  --exclude 'cache/' \
  --exclude '*.db' \
  --exclude '*.db-shm' \
  --exclude '*.db-wal' \
  --exclude 'last-changelog-version' \
  "$SRC/" "$DEST/"

seeded=0
if [ ! -f "$DEST/.env" ]; then
  cp "$SRC/.env.example" "$DEST/.env"
  chmod 600 "$DEST/.env"
  seeded=1
fi
if [ ! -f "$DEST/mcp.json" ]; then
  cp "$SRC/mcp.json.example" "$DEST/mcp.json"
  seeded=1
fi

echo "Installed profile '$PROFILE' into $DEST"
if [ "$seeded" -eq 1 ]; then
  echo
  echo "Next: fill in your own credentials."
  echo "  \$EDITOR $DEST/.env        # OPENROUTER_API_KEY, EXA_API_KEY, ETHERSCAN_API_KEY"
  echo "  \$EDITOR $DEST/mcp.json    # paste your Etherscan key into the Authorization header"
fi
echo
echo "Then run once to get a shell shortcut:"
echo "  omp --profile=$PROFILE --alias=$PROFILE"
