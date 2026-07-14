#!/usr/bin/env bash
# Tear down the regtest stack started by regtest-up.sh.
set -uo pipefail

DIR="${HEIRLOOM_REGTEST_DIR:-/tmp/heirloom-regtest}"
BITCOIN_CLI="${BITCOIN_CLI:-bitcoin-cli}"

if [ -f "$DIR/electrs.pid" ]; then
  kill "$(cat "$DIR/electrs.pid")" 2>/dev/null || true
fi
"$BITCOIN_CLI" -regtest -datadir="$DIR/bitcoind" -rpcuser=heirloom -rpcpassword=heirloom -rpcport=18443 stop 2>/dev/null || true
sleep 1
echo ">> regtest stack stopped (data left in $DIR; delete manually if desired)"
