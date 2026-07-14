#!/usr/bin/env bash
# Start a local Bitcoin regtest node + electrs Electrum server for the
# integration test suite (RegtestLifecycleTests).
#
# Requirements: bitcoind/bitcoin-cli (brew install bitcoin),
#               electrs (cargo install electrs).
#
# Ports (regtest defaults / test-suite expectations):
#   bitcoind RPC:      127.0.0.1:18443  (user: heirloom, pass: heirloom)
#   bitcoind p2p:      127.0.0.1:18444
#   electrs Electrum:  127.0.0.1:60401
set -euo pipefail

DIR="${HEIRLOOM_REGTEST_DIR:-/tmp/heirloom-regtest}"
BITCOIND="${BITCOIND:-bitcoind}"
BITCOIN_CLI="${BITCOIN_CLI:-bitcoin-cli}"
ELECTRS="${ELECTRS:-$HOME/.cargo/bin/electrs}"

rm -rf "$DIR"
mkdir -p "$DIR/bitcoind" "$DIR/electrs"

echo ">> starting bitcoind (regtest) in $DIR"
"$BITCOIND" -regtest -daemon \
  -datadir="$DIR/bitcoind" \
  -rpcuser=heirloom -rpcpassword=heirloom \
  -rpcbind=127.0.0.1:18443 -rpcallowip=127.0.0.1 \
  -fallbackfee=0.0001 -txindex=1

CLI=("$BITCOIN_CLI" -regtest -datadir="$DIR/bitcoind" -rpcuser=heirloom -rpcpassword=heirloom -rpcport=18443)

for i in $(seq 1 60); do
  if "${CLI[@]}" getblockchaininfo >/dev/null 2>&1; then break; fi
  sleep 0.5
done
"${CLI[@]}" getblockchaininfo >/dev/null || { echo "bitcoind did not come up"; exit 1; }

echo ">> creating miner wallet + mining 101 blocks"
"${CLI[@]}" createwallet miner >/dev/null 2>&1 || "${CLI[@]}" loadwallet miner >/dev/null
ADDR=$("${CLI[@]}" -rpcwallet=miner getnewaddress)
"${CLI[@]}" generatetoaddress 101 "$ADDR" >/dev/null

echo ">> starting electrs"
cat > "$DIR/electrs.toml" <<EOF
auth = "heirloom:heirloom"
EOF
nohup "$ELECTRS" \
  --conf "$DIR/electrs.toml" \
  --skip-default-conf-files \
  --network regtest \
  --daemon-dir "$DIR/bitcoind" \
  --daemon-rpc-addr 127.0.0.1:18443 \
  --daemon-p2p-addr 127.0.0.1:18444 \
  --db-dir "$DIR/electrs" \
  --electrum-rpc-addr 127.0.0.1:60401 \
  --log-filters INFO \
  > "$DIR/electrs/electrs.log" 2>&1 &
echo $! > "$DIR/electrs.pid"

for i in $(seq 1 60); do
  if nc -z 127.0.0.1 60401 2>/dev/null; then
    echo ">> regtest stack is up (RPC :18443, Electrum :60401)"
    exit 0
  fi
  sleep 0.5
done
echo "electrs did not come up; see $DIR/electrs/electrs.log"
exit 1
