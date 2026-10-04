#!/usr/bin/env bash
# The two things this service does that nothing else checks: turning a `__config__` into
# a peer list, and turning an API key into the hash the node authenticates against.
#
# Both are worth testing on their own because both fail *quietly* in production. A
# `knownPeers` the node silently fell back to is a node connected to the wrong set and
# running perfectly; an `apiKeyHash` computed with the wrong BLAKE2b output length is a
# 64-character hex string that simply never matches, on a node that started fine.
#
# What is under test is `service/entrypoint.sh` itself -- sourced, not re-implemented.
# It runs `main "$@"` at the bottom, so it is sourced with `__ERGO_NODE_TEST=1` in the
# environment, which the script reads to stop short of starting a JVM. Testing a copy of
# the logic would test the copy.
#
# The fixtures in `tests/fixtures/` are real serialized `celaut.ConfigurationFile`
# messages, built with nodo's own `protos/celaut_pb2.py` -- see `tests/fixtures/README.md`
# for the exact command. They are bytes, committed, so this test needs no Python and no
# nodo checkout: `bash`, `protoc`, `awk`, and `b2sum` from coreutils, which is what the
# image has.
#
# Run with `bash tests/test_entrypoint.sh`. Nothing is started, nothing is fetched, and
# no network is touched.

# Most of the bare assignments below are the entrypoint's own globals, set here to stand
# in for what `read_environment` would have put there before the function under test ran.
# A linter cannot see that a sourced file reads them, so SC2034 is off for this file
# rather than silenced eight times. `source-path` is what lets `-x` follow the `source=`
# directive from whatever directory this is run from.
#
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SERVICE="${HERE}/../service"

# One line per check, in a file and not in a variable: several checks run in a
# subshell, and a counter that a subshell increments is lost when it exits. A failure
# there was not counted.
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

ok() {
    echo ok >> "$RESULTS"
    printf '  ok    %s\n' "$1"
}

no() {
    echo no >> "$RESULTS"
    printf '  FAIL  %s\n' "$1"
    printf '        expected: %s\n' "$2"
    printf '        got:      %s\n' "$3"
}

is() {   # got, want, what
    if [ "$1" = "$2" ]; then ok "$3"; else no "$3" "$2" "$1"; fi
}

contains() {   # haystack, needle, what
    case "$1" in
        *"$2"*) ok "$3" ;;
        *) no "$3" "something containing '$2'" "$1" ;;
    esac
}

lacks() {   # haystack, needle, what
    case "$1" in
        *"$2"*) no "$3" "nothing containing '$2'" "$1" ;;
        *) ok "$3" ;;
    esac
}

for tool in protoc awk b2sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'this test needs %s and cannot find it.\n' "$tool" >&2
        printf 'On Debian: apt-get install protobuf-compiler coreutils\n' >&2
        printf 'On macOS:  brew install protobuf coreutils  (b2sum arrives as gb2sum)\n' >&2
        exit 2
    fi
done

# The entrypoint, with its `main` suppressed. Everything below calls its real functions.
__ERGO_NODE_TEST=1
export __ERGO_NODE_TEST
# shellcheck source=../service/entrypoint.sh
. "${SERVICE}/entrypoint.sh"

SERVICE_DIR="$SERVICE"

# ------------------------------------------------------------------- the peer list
echo 'reading pow:ergo peers out of a __config__'

CONFIG_FILE="${HERE}/fixtures/config-three-peers"
peers=$(read_pow_peers)

is "$peers" '213.239.193.208:9030
159.65.11.55:9030
[2001:41d0:700:6662::1]:29031' 'three peers, in the order the resolution listed them'

# The same fixture carries a `dns:example.com` resolution and a `gateway` -- both of
# which contain `uri { ip, port }` blocks of exactly the shape a peer has. A reader that
# matched on the shape rather than on the enclosing tag would pick them up, and the node
# would then try to speak Ergo's P2P protocol to the gateway it reports to.
lacks "$peers" '93.184.216.34' 'a peer of another network is not read as one of ours'
lacks "$peers" '10.0.0.1' 'the gateway instance is not read as a peer'

CONFIG_FILE="${HERE}/fixtures/config-no-peers"
is "$(read_pow_peers)" '' 'a pow:ergo resolution with no peers yields nothing'

CONFIG_FILE="${HERE}/fixtures/config-other-network"
is "$(read_pow_peers)" '' 'a __config__ with no pow:ergo resolution at all yields nothing'

CONFIG_FILE="${HERE}/fixtures/config-duplicate-peers"
is "$(read_pow_peers)" '213.239.193.208:9030
159.65.11.55:9030' 'the same address twice is one peer'

CONFIG_FILE="${HERE}/fixtures/config-similar-tag"
is "$(read_pow_peers)" '198.51.100.7:9030' 'the tag is matched whole: pow:ergo-testnet is a different domain'

CONFIG_FILE="${HERE}/fixtures/config-multi-uri"
is "$(read_pow_peers)" '203.0.113.5:9030
203.0.113.6:9030' 'every uri of a peer instance is read, not just the first'

# stdout only. The caller reads this function with `$(...)`, so anything it says about
# itself has to be on stderr -- a log line on stdout would be parsed as an address and
# written into knownPeers, which is the quietest possible way to dial the wrong host.
CONFIG_FILE="${HERE}/does-not-exist"
is "$(read_pow_peers 2>/dev/null)" '' 'a missing __config__ is not fatal -- a dev run outside nodo still starts'
contains "$(read_pow_peers 2>&1 >/dev/null)" 'nothing resolved this instance' \
         'and it says so, on stderr, where it cannot become a peer'

CONFIG_FILE="${HERE}/fixtures/config-three-peers"
is "$(read_pow_peers 2>&1 | grep -c '^\[ergo-node\]' || true)" '0' \
   'nothing this function logs can end up in the peer list'

# ------------------------------------------------------------- the rendered config
echo
echo 'rendering ergo.conf'

DATA_DIR=$(mktemp -d)
CONF_PATH="${DATA_DIR}/ergo.conf"
CURL_RC="${DATA_DIR}/.curlrc"
NETWORK=mainnet
NODE_NAME=celaut-ergo-node
BLOCKS_TO_KEEP=1440
API_KEY_HASH='324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf'
ERGO_API_KEY='hello'
FAST_BOOTSTRAP=true

write_configuration '213.239.193.208:9030
159.65.11.55:9030' >/dev/null
rendered=$(cat "$CONF_PATH")

contains "$rendered" '"213.239.193.208:9030"' 'the first peer is in knownPeers'
contains "$rendered" '"159.65.11.55:9030"' 'the second peer is in knownPeers'
contains "$rendered" 'bindAddress = "0.0.0.0:9053"' 'the REST API binds on every interface, on 9053'
contains "$rendered" "apiKeyHash = \"${API_KEY_HASH}\"" 'the api key hash is written, and only the hash'
lacks "$rendered" 'hello' 'the API KEY ITSELF is nowhere in ergo.conf'
contains "$rendered" 'utxoBootstrap = true' 'the UTXO snapshot bootstrap is on'
contains "$rendered" 'nipopowBootstrap = true' 'the NiPoPoW bootstrap is on'
contains "$rendered" 'blocksToKeep = 1440' 'blocksToKeep comes from the environment'
contains "$rendered" 'mining = false' 'this is not a miner'

is "$(stat -c '%a' "$CURL_RC" 2>/dev/null || stat -f '%Lp' "$CURL_RC")" '600' \
   'the curl config holding the API key is not readable by anyone else'
is "$(stat -c '%a' "$CONF_PATH" 2>/dev/null || stat -f '%Lp' "$CONF_PATH")" '600' \
   'ergo.conf is not readable by anyone else'

# The point of the whole service: an empty resolution must produce an EMPTY list and not
# an absent key. Ergo's own mainnet.conf ships thirteen hardcoded peers as a fallback
# under the user's config, so a missing `knownPeers` is not "no peers" -- it is those
# thirteen, silently, on a service whose spec says it dials only what it was resolved
# onto.
write_configuration '' >/dev/null
empty_rendered=$(cat "$CONF_PATH")
contains "$empty_rendered" 'knownPeers = []' 'an empty resolution writes knownPeers = [] rather than omitting the key'
lacks "$empty_rendered" '213.239.193.208' 'and carries nothing over from the previous write'

# The bootstrap settings follow the wallet, because Ergo will not have both.
FAST_BOOTSTRAP=false
BLOCKS_TO_KEEP=-1
write_configuration '' >/dev/null
unpruned=$(cat "$CONF_PATH")
contains "$unpruned" 'utxoBootstrap = false' 'a wallet-bearing node writes utxoBootstrap = false'
# Ergo refuses to start with nipopowBootstrap on unless utxoBootstrap is on or
# blocksToKeep >= 0, so the two bootstrap settings move together or the node does not
# come up at all. Found the same way: by the real image refusing to start.
contains "$unpruned" 'nipopowBootstrap = false' 'and nipopowBootstrap = false, which Ergo requires alongside it'
contains "$unpruned" 'blocksToKeep = -1' 'and keeps every block, which is what unpruned means'
FAST_BOOTSTRAP=true
BLOCKS_TO_KEEP=1440

rm -rf "$DATA_DIR"

# ---------------------------------------------------------------- the api key hash
echo
echo 'the api key hash (BLAKE2b-256)'

hash_of() {
    printf '%s' "$1" | b2sum -l 256 | awk '{print $1}'
}

# The vector in Ergo's own application.conf, mainnet.conf and testnet.conf, all three of
# which ship `apiKeyHash` as the hash of the string "hello" with a comment saying so.
# It is also what the node's `/utils/hash/blake2b` returns for "hello":
#
#   curl -s -X POST https://node.sigmaspace.io/utils/hash/blake2b \
#        -H 'Content-Type: application/json' -d '"hello"'
#   "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf"
is "$(hash_of 'hello')" '324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf' \
   'blake2b-256("hello") is the vector Ergo ships in its own config'

# BLAKE2b's published vector for the empty input at 256-bit output. It is here to pin
# the *output length*: BLAKE2b keys its own parameter block with the digest size, so a
# 256-bit digest is not a truncated 512-bit one, and `openssl dgst -blake2b512 | cut`
# would produce a plausible 64-character string that never matches.
is "$(hash_of '')" '0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8' \
   'blake2b-256("") is the published vector, so the output length is right'

long_hash=$(hash_of 'a-much-longer-api-key-than-anyone-would-type')
is "${#long_hash}" '64' 'the hash is 64 hex characters whatever the key length'

# ---------------------------------------------------------------- the environment
echo
echo 'the environment contract'

# Run in a subshell: read_environment calls `fail`, which exits.
env_error() {   # runs read_environment with the given assignments, prints its message
    (
        unset ERGO_API_KEY ERGO_NETWORK ERGO_MAX_HEAP ERGO_BLOCKS_TO_KEEP \
              ERGO_WALLET_MNEMONIC ERGO_WALLET_PASSWORD
        eval "$1"
        ERGO_PID=''
        read_environment 2>&1
    ) | tr '\n' ' '
}

contains "$(env_error "ERGO_API_KEY=''")" 'ERGO_API_KEY is empty' \
         'a missing API key is refused with a reason'
contains "$(env_error "ERGO_API_KEY=k; ERGO_NETWORK=signet")" 'is not one of mainnet, testnet' \
         'an unknown network is refused'
contains "$(env_error "ERGO_API_KEY=k; ERGO_MAX_HEAP=lots")" 'is not a JVM heap size' \
         'a malformed heap size is refused before the JVM sees it'
for bad in 3 3GB 1G2G G 0G '3 G'; do
    contains "$(env_error "ERGO_API_KEY=k; ERGO_MAX_HEAP='${bad}'")" 'is not a JVM heap size' \
             "the heap size '${bad}' is refused"
done
(
    unset ERGO_MAX_HEAP
    ERGO_API_KEY=k read_environment
    is "$HEAP_FLAG" '-XX:MaxRAMPercentage=60.0' 'with no heap size, the heap is a share of the RAM of the guest'
)
(
    ERGO_API_KEY=k ERGO_MAX_HEAP=2048m read_environment
    is "$HEAP_FLAG" '-Xmx2048m' 'a heap size is given to the JVM as -Xmx'
)
contains "$(env_error "ERGO_API_KEY=k; ERGO_BLOCKS_TO_KEEP=some")" 'whole number of blocks' \
         'a malformed blocksToKeep is refused'
contains "$(env_error "ERGO_API_KEY=k; ERGO_WALLET_MNEMONIC='a b c'")" 'ERGO_WALLET_PASSWORD is not' \
         'a mnemonic with no spending password is refused rather than defaulted'

is "$(env_error "ERGO_API_KEY=k")" '' 'the minimal environment -- an API key -- is accepted'

# Ergo refuses /wallet/restore on any pruned node:
#
#   isFullBlocksPruned = blocksToKeep >= 0 || utxoSettings.utxoBootstrap
#       -- NodeConfigurationSettings.scala, checked by ErgoWalletService.restoreWallet
#
# so the snapshot bootstrap that makes this service fit in 8 GB is exactly what makes a
# wallet impossible. This was found by running the real image: the node answered HTTP 400
# "Unable to restore wallet when pruning is enabled", and the entrypoint -- which was not
# checking the status code, because `curl` exits 0 on a 400 -- logged "wallet restored
# from the mnemonic". Both halves of that are pinned, here and in the rendered config.
contains "$(env_error "ERGO_API_KEY=k; ERGO_WALLET_MNEMONIC='a b c'; ERGO_WALLET_PASSWORD=p")" \
         'needs an unpruned node' \
         'a wallet on a pruned node is refused BEFORE the JVM starts, not as an HTTP 400 later'

is "$(env_error "ERGO_API_KEY=k; ERGO_WALLET_MNEMONIC='a b c'; ERGO_WALLET_PASSWORD=p; ERGO_BLOCKS_TO_KEEP=-1")" \
   '' 'a wallet with ERGO_BLOCKS_TO_KEEP=-1 is accepted'

# `blocksToKeep = -1` is only half of `isFullBlocksPruned`. `utxoBootstrap` is the other
# half and is on by default here, so the same check has to turn it off -- otherwise the
# configuration written is still a pruned one and the restore still fails.
(
    ERGO_API_KEY=k ERGO_BLOCKS_TO_KEEP=-1 \
    ERGO_WALLET_MNEMONIC='a b c' ERGO_WALLET_PASSWORD=p read_environment
    is "$FAST_BOOTSTRAP" 'false' \
       'and it turns the fast bootstrap off, which is the other half of that rule'
)
(
    unset ERGO_WALLET_MNEMONIC ERGO_WALLET_PASSWORD
    ERGO_API_KEY=k read_environment
    is "$FAST_BOOTSTRAP" 'true' 'with no wallet asked for, the fast bootstrap stays on'
)

# A mnemonic must not appear in anything read_environment prints, ever. It is the one
# value in this contract whose disclosure is unrecoverable.
lacks "$(env_error "ERGO_API_KEY=k; ERGO_WALLET_MNEMONIC='abandon abandon about'")" 'abandon' \
      'the mnemonic is never quoted back, not even in the error about it'

echo
PASSED=$(grep -c '^ok$' "$RESULTS" || true)
FAILED=$(grep -c '^no$' "$RESULTS" || true)
printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
