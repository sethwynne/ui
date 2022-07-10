#!/usr/bin/env bash
# Calls the CLI to peg gateway client into the federation

set -euxo pipefail

# Let's define some shortcuts for bitcoind and the mint client
POLL_INTERVAL=1
PEG_IN_AMOUNT=${PEG_IN_AMOUNT:-$1}

CONFIRMATION_TIME=$(cat $CFG_DIR/server-0.json | jq -r '.wallet.finalty_delay')
echo "Pegging in $PEG_IN_AMOUNT with confirmation time $CONFIRMATION_TIME"

# Get a peg-in address, which is derived from the federation's descriptor in which every key was tweaked with the same
# random value only known to our client.
ADDR="$($LN1 -H gw-address)"

# We send the amount we want to peg-in to this address
TX_ID="$($BTC_CLIENT sendtoaddress $ADDR $PEG_IN_AMOUNT)"

# Now we "wait" for confirmations
$BTC_CLIENT generatetoaddress 11 "$($BTC_CLIENT getnewaddress)"

function await_block_sync() {
  EXPECTED_BLOCK_HEIGHT="$(( $($BTC_CLIENT getblockchaininfo | jq -r '.blocks') - $CONFIRMATION_TIME ))"
  for ((ID=0; ID<FED_SIZE; ID++)); do
    MINT_API_URL="ws://127.0.0.1:500$ID"
    until [ "$($MINT_RPC_CLIENT $MINT_API_URL '/wallet/block_height')" == "$EXPECTED_BLOCK_HEIGHT" ]; do
      sleep $POLL_INTERVAL
    done
  done
}
await_block_sync

# We then get a proof from our bitcoind that we sent coins to the peg-in address. This proof can be evaluated by just
# looking at block headers. The federation uses this so that it only needs to be aware of valid block hashes and not
# entire blocks.
TXOUT_PROOF="$($BTC_CLIENT gettxoutproof "[\"$TX_ID\"]")"
TRANSACTION="$($BTC_CLIENT getrawtransaction $TX_ID)"

# With these proofs we can instruct the client to start the peg-in process. Our client will add the tweak used to derive
# the peg-in address to the request so that the federation can claim the funds later.
$LN1 gw-deposit "$TXOUT_PROOF" "$TRANSACTION"

# Since the process is asynchronous have to come back to fetch the result later. We choose to do this right away and
# just block till we get our tokens.
$MINT_CLIENT fetch
