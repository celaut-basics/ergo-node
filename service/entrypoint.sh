#!/usr/bin/env bash
# Bring up an Ergo node whose peers are the ones this instance was *resolved* onto.
#
# The whole service, in order: read the peers out of `__config__`, write an `ergo.conf`
# from them and from the environment, start the jar, wait for its REST API, optionally
# restore a wallet through that API, and then stay out of the way while the node runs.
#
# The first step is the one this service exists for. A `pow:ergo` network
# (`.service/service.json`) does not name hosts -- it names a property: peers whose main
# chain contains a given block and carries at least a given amount of cumulative work.
# The node running this instance turns that property into addresses and hands them over
# in the instance's own `__config__`, a binary `celaut.ConfigurationFile`, as the
# `network_resolution` entry whose tags contain `pow:ergo`. Every
# `peer_instances[].uri_slot[].uri` in it becomes one `scorex.network.knownPeers` entry.
#
# Four things it is careful about, because each one is a way to get this quietly wrong:
#
# * It always writes `knownPeers`, even when the list is empty. Ergo's own
#   `mainnet.conf` ships thirteen hardcoded peers, and it is a *fallback* under the
#   user's config -- so a config that omits the key does not get "no peers", it gets
#   those thirteen. Omitting it would mean a service that claims to dial only what it
#   was resolved onto and in fact dials a list baked into the jar.
# * An empty resolution is not an error. "Nobody meets that requirement right now" is a
#   statement about the world and a transient one; the node starts, says so plainly, and
#   is still reachable on its REST API. A later launch gets a fresh resolution.
# * It shuts the node down properly. SIGTERM is forwarded and waited on: Ergo's
#   shutdown hook closes RocksDB, and a killed JVM can leave a store that has to be
#   resynced -- which on a snapshot-bootstrapped node means downloading the snapshot
#   again.
# * It never logs the secret. Not the mnemonic, not the API key, not the spending
#   password. What it prints is what an operator needs: which network, which peers, the
#   height it reached, and the wallet's first address.
#
# On that last point, in a shell specifically: `set -x` is never turned on; the API key
# and every wallet request body are passed to `curl` through mode-0600 files rather than
# through `argv`, where any process on the same machine can read them out of `/proc`;
# the JSON bodies are built by `jq` from the *environment* (`env.NAME`) rather than from
# `--arg`, for the same reason; and no failure message quotes what it was given.

set -euo pipefail

DATA_DIR="${ERGO_DATADIR:-/data}"
CONF_PATH="${DATA_DIR}/ergo.conf"
CURL_RC="${DATA_DIR}/.curlrc"

SERVICE_DIR="$(dirname "$(readlink -f "$0")")"

# The JVM and the node, by full path. The guest does not get the ENV of the
# Dockerfile: nodo exports only the filesystem, and its /init sets PATH to the
# standard directories, which do not contain /opt/java/bin.
JAVA_BIN=/opt/java/bin/java
ERGO_JAR=/opt/ergo/ergo.jar

# Where the node writes this instance's configuration. `__config__` at the root of the
# filesystem is the packer's default (`config_declaration.path`, PACKING.md), and
# `.service/service.json` does not override it.
CONFIG_FILE="${ERGO_CONFIG_FILE:-/__config__}"

# The REST API, on the same port on every network, so whatever launches this has one
# endpoint to talk to and does not have to know which chain it asked for. It is the port
# `.service/service.json` declares.
REST_PORT=9053

# The tag whose resolution carries this service's peers. It is the tag declared in
# `.service/service.json`, and the resolution is matched on it rather than on position:
# a `__config__` carries one `network_resolution` per declared network, in no promised
# order, and this service may one day declare more than one.
POW_TAG='pow:ergo'

ERGO_PID=''
STOPPING=''
# The jar's own exit status, once something has collected it. A node that stopped
# cleanly and one that was killed have to be distinguishable from outside the container,
# so this is what the script exits with rather than the signal that began the shutdown.
ERGO_STATUS=''

log() {
    printf '[ergo-node] %s\n' "$1"
}

fail() {
    log "FATAL: $1"
    stop_node 'startup'
    exit 1
}

# ------------------------------------------------------------------ environment
# What the node passed in, validated. The contract is documented in the README.
read_environment() {
    NETWORK="${ERGO_NETWORK:-}"
    NETWORK="${NETWORK#"${NETWORK%%[![:space:]]*}"}"
    NETWORK="${NETWORK%"${NETWORK##*[![:space:]]}"}"
    NETWORK="${NETWORK:-mainnet}"
    case "$NETWORK" in
        mainnet|testnet) : ;;
        *) fail "ERGO_NETWORK='${NETWORK}' is not one of mainnet, testnet" ;;
    esac

    if [ -z "${ERGO_API_KEY:-}" ]; then
        fail "ERGO_API_KEY is empty. Ergo's REST API refuses every authenticated route without one, and this service has no other way to reach the wallet; a node with no key is a node nothing can use."
    fi

    # BLAKE2b-256, hex, which is what `scorex.restApi.apiKeyHash` holds. `b2sum -l 256`
    # is coreutils', from the base image: OpenSSL 3.0 offers BLAKE2b at 512-bit output
    # only, and a 256-bit BLAKE2b is a different hash rather than a truncated one.
    # `tests/test_entrypoint.sh` pins this against the node's own documented vector.
    #
    # The key goes in on stdin, so it is never in `argv`.
    API_KEY_HASH=$(printf '%s' "${ERGO_API_KEY}" | b2sum -l 256 | awk '{print $1}')
    if [ "${#API_KEY_HASH}" -ne 64 ]; then
        fail "the API key hash did not come out 64 hex characters; b2sum is not behaving as expected"
    fi

    NODE_NAME="${ERGO_NODE_NAME:-}"
    NODE_NAME="${NODE_NAME:-celaut-ergo-node}"

    # The JVM heap. Empty means a share of the RAM of the guest, which is the
    # `at_init.mem_limit` of service.json. nodo boots the microVM with that RAM and does
    # not add more unless the service asks for it, so a fixed default would be too
    # large on a small instance and too small on a large one. The rest of the RAM is
    # for RocksDB, the JIT and the threads, which are outside the heap.
    MAX_HEAP="${ERGO_MAX_HEAP:-}"
    HEAP_FLAG='-XX:MaxRAMPercentage=60.0'
    if [ -n "$MAX_HEAP" ]; then
        case "$MAX_HEAP" in
            *[!0-9MmGg]*|[!1-9]*|*[0-9]|*[MmGg]*[MmGg]*) fail "ERGO_MAX_HEAP='${MAX_HEAP}' is not a JVM heap size such as 3G or 2048M" ;;
        esac
        HEAP_FLAG="-Xmx${MAX_HEAP}"
    fi

    BLOCKS_TO_KEEP="${ERGO_BLOCKS_TO_KEEP:-1440}"
    case "$BLOCKS_TO_KEEP" in
        -1|0|[1-9]*) : ;;
        *) fail "ERGO_BLOCKS_TO_KEEP='${BLOCKS_TO_KEEP}' is not -1 or a whole number of blocks" ;;
    esac
    case "$BLOCKS_TO_KEEP" in
        -1) : ;;
        *[!0-9]*) fail "ERGO_BLOCKS_TO_KEEP='${BLOCKS_TO_KEEP}' is not -1 or a whole number of blocks" ;;
    esac

    MNEMONIC="${ERGO_WALLET_MNEMONIC:-}"
    if [ -n "$MNEMONIC" ] && [ -z "${ERGO_WALLET_PASSWORD:-}" ]; then
        fail "ERGO_WALLET_MNEMONIC is set but ERGO_WALLET_PASSWORD is not. The node encrypts its keystore with that password and asks for it on every unlock; it is required by /wallet/restore and cannot be defaulted to something guessable."
    fi

    # A wallet and a pruned node are mutually exclusive, and it is Ergo that says so,
    # not this service:
    #
    #   isFullBlocksPruned = blocksToKeep >= 0 || utxoSettings.utxoBootstrap
    #   if (settings.nodeSettings.isFullBlocksPruned)
    #     Failure(new IllegalArgumentException("Unable to restore wallet when pruning is enabled"))
    #                             -- NodeConfigurationSettings.scala, ErgoWalletService.scala
    #
    # So the snapshot bootstrap that makes this service fit in 8 GB is exactly what makes
    # /wallet/restore return 400. The two cannot both be had, and the choice is the
    # operator's rather than this script's: silently turning the bootstrap off would sign
    # a node declaring 8 GB of disk up for the full chain, and silently ignoring the
    # mnemonic would leave a service that was asked for a wallet running without one.
    #
    # Refused here, before the JVM starts, rather than discovered forty seconds later as
    # an HTTP 400 -- which is how this was found.
    FAST_BOOTSTRAP=true
    if [ -n "$MNEMONIC" ]; then
        if [ "$BLOCKS_TO_KEEP" != "-1" ]; then
            fail "ERGO_WALLET_MNEMONIC needs an unpruned node, and ERGO_BLOCKS_TO_KEEP=${BLOCKS_TO_KEEP} prunes. Ergo refuses /wallet/restore whenever blocksToKeep >= 0 or utxoBootstrap is on (isFullBlocksPruned). Set ERGO_BLOCKS_TO_KEEP=-1 -- which also turns the UTXO snapshot bootstrap off, means a full sync from genesis, and needs the instance's declared disk raised well past the 8 GB in service.json. A service that only reads the chain should leave the mnemonic unset instead."
        fi
        # blocksToKeep = -1 alone is not enough: utxoBootstrap is the other half of
        # isFullBlocksPruned, and it defaults to on in this service. NiPoPoW goes with
        # it -- Ergo refuses to start with `nipopowBootstrap` on unless the node is
        # pruned in one of those two senses:
        #
        #   nipopowBootstrap && !(utxoBootstrap || blocksToKeep >= 0) -> failWithError
        #                                        -- ErgoSettingsReader.consistentSettings
        #
        # which is why this is ONE flag and not two. "Bootstrap fast" and "keep
        # everything" are the two configurations Ergo actually has; a mix of them is a
        # config it stops on, and this service found that out by being stopped by it.
        FAST_BOOTSTRAP=false
    fi
}

# ------------------------------------------------------------- peers from __config__
# The `pow:ergo` peers this instance was resolved onto, as `ip:port`, one per line.
#
# `__config__` is a serialized `celaut.ConfigurationFile`, so something has to parse
# protobuf. The choice here is `protoc --decode`, with the schema vendored beside this
# script, and `awk` over its text output:
#
# * It is the *same* schema the node serialized with -- vendored, so a drift shows up as
#   a diff in this repository rather than as a field silently read at the wrong number.
#   A hand-rolled varint reader in `bash` would be a second, unreviewed implementation
#   of protobuf's wire format guarding the list of hosts this node connects to.
# * `protoc` costs one Debian package. The alternative that needs no package is that
#   hand-rolled parser; the alternative that needs a language runtime is Python, which
#   this image deliberately does not have.
# * The text output is line-oriented, indentation-free at the token level and stable
#   across protobuf versions, which is what makes `awk` an honest tool for it rather
#   than a clever one.
#
# The `awk` program tracks brace depth so that only a top-level `network_resolution`
# block is considered -- `gateway` carries `uri` blocks too, and they are not peers --
# and within one such block it emits an address only for a `uri` that had both an `ip`
# and a `port`. Proto3 omits fields at their default, so a `uri` with no `port` line is
# one whose port is 0, which is not an address to dial.
#
# Everything this function says goes to stderr, because its STDOUT IS THE PEER LIST: the
# caller reads it with `$(...)`, and a log line on the same stream would be parsed as an
# address and written into `knownPeers`.
read_pow_peers() {
    if [ ! -f "$CONFIG_FILE" ]; then
        # A dev run outside nodo, or a node that wrote no configuration for this
        # instance. Neither is a reason not to start: what is lost is the peer list.
        log "no ${CONFIG_FILE}: nothing resolved this instance onto a network" >&2
        return 0
    fi

    local decoded
    # Decoded first and separately, so that a `__config__` this service cannot read is a
    # loud failure with a name on it rather than a pipeline that quietly yields no
    # peers. Those two have to look different: "nobody qualified" is normal and
    # "I could not read what I was given" is not.
    if ! decoded=$(protoc --proto_path="$SERVICE_DIR" \
                          --decode=celaut.ConfigurationFile \
                          "${SERVICE_DIR}/celaut.proto" < "$CONFIG_FILE" 2>/dev/null); then
        fail "${CONFIG_FILE} is not a celaut.ConfigurationFile this service can decode. The schema it is read with is service/celaut.proto, vendored from celaut-project/nodo; a node writing a newer one than this copy is the first thing to check." >&2
    fi

    printf '%s\n' "$decoded" \
        | awk -v want="$POW_TAG" '
            # Depth of the block we are inside, counting braces as protoc prints them:
            # one opening or closing brace per line, always the last token.
            /\{[[:space:]]*$/ {
                depth++
                if (depth == 1) {
                    inres = ($1 == "network_resolution" || $1 == "network_resolution:")
                    matched = 0
                }
                if (inres && $1 == "uri") { ip = ""; port = "" }
                next
            }
            /^[[:space:]]*\}[[:space:]]*$/ {
                if (inres && depth == 1) { inres = 0; matched = 0 }
                depth--
                next
            }
            !inres { next }
            # tags is field 1 of NetworkResolution and peer_instances is field 2, so a
            # tag is always printed before the peers it qualifies. The match is on the
            # whole tag, never a prefix: `pow:ergo-testnet` is a different domain.
            $1 == "tags:" {
                v = $0
                sub(/^[^"]*"/, "", v); sub(/"[^"]*$/, "", v)
                if (v == want) matched = 1
                next
            }
            $1 == "ip:" {
                v = $0
                sub(/^[^"]*"/, "", v); sub(/"[^"]*$/, "", v)
                ip = v
                next
            }
            $1 == "port:" {
                port = $2
                if (matched && ip != "" && port != "" && port != "0") {
                    # Ergo writes an IPv6 literal bracketed, as its own mainnet.conf
                    # does. A resolver that produced a bare v6 address would otherwise
                    # give `scorex.network.knownPeers` a string it cannot split.
                    if (index(ip, ":") > 0 && substr(ip, 1, 1) != "[") ip = "[" ip "]"
                    print ip ":" port
                }
                ip = ""; port = ""
                next
            }
        ' \
        | awk '!seen[$0]++'
}

# --------------------------------------------------------------- configuration
# `ergo.conf`, written at every start from the resolution and the environment.
#
# The file is a *user* config in Ergo's terms, which means it is layered over the
# network's own (`mainnet.conf` / `testnet.conf`) and then over `application.conf`. Keys
# set here win; keys not set here fall through. That is why `knownPeers` is written
# unconditionally -- see the note at the top of this file.
write_configuration() {
    local peers="$1"

    mkdir -p "$DATA_DIR"

    # The file holds the API key's hash; it is no one else's business on a shared
    # filesystem, and the same umask covers the curl config written next to it.
    local previous_umask
    previous_umask=$(umask)
    umask 077
    {
        printf '%s\n' '# Written at every start from this service'"'"'s environment and from the'
        printf '%s\n' '# network_resolution in this instance'"'"'s __config__. Editing it by hand has no'
        printf '%s\n' '# lasting effect: the next start overwrites it.'
        printf '\n'
        printf '%s\n' 'ergo {'
        printf '  directory = "%s"\n' "$DATA_DIR"
        printf '%s\n' '  node {'
        printf '%s\n' '    mining = false'
        # A snapshot bootstrap plus a suffix of full blocks: full-node security without
        # the full history. See the README for what this costs and what it gives up.
        printf '    blocksToKeep = %s\n' "$BLOCKS_TO_KEEP"
        printf '%s\n' '    utxo {'
        printf '      utxoBootstrap = %s\n' "$FAST_BOOTSTRAP"
        # 0: do not keep snapshots of our own. Serving them is a service to the network
        # this instance is not sized for, and each one is state on a disk this service
        # declared as modest.
        printf '%s\n' '      storingUtxoSnapshots = 0'
        printf '%s\n' '      p2pUtxoSnapshots = 2'
        printf '%s\n' '    }'
        printf '%s\n' '    nipopow {'
        printf '      nipopowBootstrap = %s\n' "$FAST_BOOTSTRAP"
        printf '%s\n' '      p2pNipopows = 2'
        printf '%s\n' '    }'
        printf '%s\n' '  }'
        printf '%s\n' '}'
        printf '\n'
        printf '%s\n' 'scorex {'
        printf '%s\n' '  restApi {'
        # The REST API is this service's whole interface, and the only thing that can
        # reach it is what the node running this instance exposes: an instance's network
        # is the node's firewall, not this file's business.
        printf '    bindAddress = "0.0.0.0:%s"\n' "$REST_PORT"
        printf '    apiKeyHash = "%s"\n' "$API_KEY_HASH"
        printf '%s\n' '  }'
        printf '%s\n' '  network {'
        printf '    nodeName = "%s"\n' "$NODE_NAME"
        # ALWAYS written, empty list included. Ergo's mainnet.conf ships thirteen
        # hardcoded peers as a fallback under this file, so omitting the key would
        # silently dial those instead of the ones this instance was resolved onto.
        if [ -z "$peers" ]; then
            printf '%s\n' '    knownPeers = []'
        else
            printf '%s\n' '    knownPeers = ['
            printf '%s\n' "$peers" | while IFS= read -r peer; do
                [ -n "$peer" ] || continue
                printf '      "%s",\n' "$peer"
            done
            printf '%s\n' '    ]'
        fi
        printf '%s\n' '  }'
        printf '%s\n' '}'
    } > "$CONF_PATH"

    # curl's own config file, so the API key is in a mode-0600 file and never in `argv`.
    printf 'header = "api_key: %s"\n' "${ERGO_API_KEY}" > "$CURL_RC"
    printf '%s\n' 'silent' >> "$CURL_RC"
    printf '%s\n' 'show-error' >> "$CURL_RC"
    umask "$previous_umask"

    local count=0
    if [ -n "$peers" ]; then
        count=$(printf '%s\n' "$peers" | grep -c . || true)
    fi
    log "configuration written for ${NETWORK}: ${count} peer(s) from ${POW_TAG}, blocksToKeep=${BLOCKS_TO_KEEP}"
    if [ "$count" -eq 0 ]; then
        log "knownPeers is empty: no peer in this instance's network_resolution met the requirement declared in service.json. The node starts anyway and its REST API is reachable; a later launch gets a fresh resolution."
    else
        # Addresses, not secrets: an operator has to be able to see who this dialled.
        printf '%s\n' "$peers" | while IFS= read -r peer; do
            [ -n "$peer" ] && log "  peer: ${peer}"
        done
    fi
}

# ---------------------------------------------------------------------- the API
# The node's own REST API on loopback. The API key rides in `$CURL_RC`, never in `argv`.
api() {   # method, path
    curl -K "$CURL_RC" -X "$1" --max-time 30 "http://127.0.0.1:${REST_PORT}$2"
}

# A POST whose body is a secret: written to a mode-0600 file and removed straight after,
# so it is neither in `argv` nor left behind. The body is built by the caller.
#
# Returns non-zero on an HTTP error, which `curl` on its own does NOT: a 400 is a
# perfectly successful transfer of an error document, and `curl` exits 0 having printed
# it. That is how a silently-failed /wallet/restore came to be reported as a success
# during this service's own smoke test -- the node answered `{"error": 400, "detail":
# "Unable to restore wallet when pruning is enabled"}` and the script said "wallet
# restored". The status code is asked for explicitly and checked.
#
# The body is discarded rather than returned: an Ergo error for a malformed request can
# quote the request, and here the request is the mnemonic.
api_post_file() {   # path, file
    local status
    status=$(curl -K "$CURL_RC" -X POST --max-time 60 \
                  -H 'Content-Type: application/json' \
                  --data-binary "@$2" \
                  -o /dev/null -w '%{http_code}' \
                  "http://127.0.0.1:${REST_PORT}$1" 2>/dev/null) || return 1
    case "$status" in
        2??) return 0 ;;
        *) API_LAST_STATUS="$status"; return 1 ;;
    esac
}

# Until the node answers. It loads its stores and starts its network layer first, which
# is not instant, and on a snapshot bootstrap the first phase can look idle for a while.
wait_for_api() {
    local timeout="${1:-600}" deadline=$(( SECONDS + ${1:-600} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if curl -sS --max-time 10 "http://127.0.0.1:${REST_PORT}/info" >/dev/null 2>&1; then
            return 0
        fi
        # Polling rather than waiting blind, so a jar that has already died is not
        # waited on for the whole timeout.
        if [ -n "$ERGO_PID" ] && ! kill -0 "$ERGO_PID" 2>/dev/null; then
            fail "the node exited while starting up"
        fi
        sleep 2
    done
    fail "the node did not answer its REST API within ${timeout}s"
}

# ---------------------------------------------------------------------- wallet
# Restore the wallet from the mnemonic, once, through the node's own API.
#
# Through the API and not by writing a keystore: the node owns that file's format and
# its encryption parameters, and a second implementation of them in `bash` would be a
# second thing to keep in step with a format this service does not define. It also means
# the derivation is Ergo's own (EIP-3, `m/44'/429'/0'/0/0`), so the same words open the
# same funds in any other Ergo wallet.
#
# Idempotent, because this runs at every start and the keystore outlives none, some or
# all of them depending on what the node did with this instance's filesystem. An already
# initialized wallet is unlocked and left alone.
ensure_wallet() {
    [ -n "$MNEMONIC" ] || { log "no ERGO_WALLET_MNEMONIC: running without a wallet"; return 0; }

    local status initialized unlocked
    status=$(api GET /wallet/status) || fail "the node would not answer /wallet/status"
    initialized=$(printf '%s' "$status" | jq -r '.isInitialized // false')

    local body="${DATA_DIR}/.wallet-request"
    local previous_umask
    previous_umask=$(umask)
    umask 077

    API_LAST_STATUS=''

    if [ "$initialized" != "true" ]; then
        # Built from the *environment* rather than from `--arg`: jq's arguments are this
        # process's `argv`, which is world-readable on `/proc` for anything running as
        # the same user. `env.NAME` reads the same value without it ever being one.
        #
        # usePre1627KeyDerivation is false: the pre-EIP-3 derivation was the default
        # before node 4.0.105 and restoring under it gives a *different*, silently wrong
        # wallet for anything generated since. A service that has no way to know which
        # era a mnemonic came from should take the one every current tool produces.
        ERGO_WALLET_MNEMONIC="$MNEMONIC" \
        ERGO_WALLET_PASSWORD="${ERGO_WALLET_PASSWORD}" \
        ERGO_WALLET_MNEMONIC_PASSPHRASE="${ERGO_WALLET_MNEMONIC_PASSPHRASE:-}" \
        jq -n '{
            pass: env.ERGO_WALLET_PASSWORD,
            mnemonic: env.ERGO_WALLET_MNEMONIC,
            mnemonicPass: (env.ERGO_WALLET_MNEMONIC_PASSPHRASE // ""),
            usePre1627KeyDerivation: false
        }' > "$body"

        if ! api_post_file /wallet/restore "$body"; then
            rm -f "$body"
            umask "$previous_umask"
            # The status code, never the response body: an Ergo error for a malformed
            # request can quote the request, and the request is the mnemonic.
            fail "the node refused to restore the wallet (HTTP ${API_LAST_STATUS:-no answer}). The words, the optional passphrase and the spending password are all it was given; none of them is quoted here. An HTTP 400 here is most likely the pruning rule -- see ERGO_BLOCKS_TO_KEEP in the README."
        fi
        log "wallet restored from the mnemonic"
    else
        log "a wallet was already initialized here; left as it is"
    fi

    # Unlocked only if it is locked. `/wallet/restore` leaves the wallet *unlocked* --
    # it has just been handed the password -- and `/wallet/unlock` on an unlocked wallet
    # is an HTTP 400 "Wallet already unlocked", not a no-op. Asking unconditionally
    # therefore turns the ordinary first start into a startup failure, which is what it
    # did here before the status code was being checked at all.
    #
    # The state is re-read rather than inferred from which branch ran above: an
    # already-initialized wallet from a previous start is locked, a freshly restored one
    # is not, and `/wallet/status` is the node's own answer to which of those this is.
    status=$(api GET /wallet/status) || fail "the node would not answer /wallet/status"
    unlocked=$(printf '%s' "$status" | jq -r '.isUnlocked // false')
    if [ "$unlocked" != "true" ]; then
        ERGO_WALLET_PASSWORD="${ERGO_WALLET_PASSWORD}" \
        jq -n '{pass: env.ERGO_WALLET_PASSWORD}' > "$body"
        if ! api_post_file /wallet/unlock "$body"; then
            rm -f "$body"
            umask "$previous_umask"
            fail "the node would not unlock the wallet (HTTP ${API_LAST_STATUS:-no answer}). If a keystore from a different mnemonic or a different password is on this instance's filesystem, that is what this is."
        fi
    fi
    rm -f "$body"
    umask "$previous_umask"

    # Proof rather than assumption: the wallet is asked whether it is actually
    # initialized and unlocked, and an address is read back out of it. `/wallet/restore`
    # answering 200 is the node saying it accepted the request; this is the node saying
    # it has a wallet.
    status=$(api GET /wallet/status) || fail "the node would not answer /wallet/status"
    if [ "$(printf '%s' "$status" | jq -r '.isInitialized // false')" != "true" ] \
       || [ "$(printf '%s' "$status" | jq -r '.isUnlocked // false')" != "true" ]; then
        fail "the node reports no unlocked wallet after restoring and unlocking one. Nothing has been served; a wallet that is not there is not a state to serve an API on."
    fi

    local address
    address=$(api GET /wallet/addresses | jq -r '.[0] // ""' 2>/dev/null || true)
    if [ -n "$address" ]; then
        log "wallet unlocked, first address: ${address}"
    else
        # Addresses come from the wallet's own derivation and are there as soon as it is
        # unlocked, so this is worth saying rather than passing over.
        log "wallet unlocked, but the node returned no address"
    fi
}

# ------------------------------------------------------------------- lifecycle
# What the node is, in its own words. Addresses and heights, never secrets.
report() {
    local info height headers chain
    info=$(curl -sS --max-time 15 "http://127.0.0.1:${REST_PORT}/info" || true)
    [ -n "$info" ] || return 0
    chain=$(printf '%s' "$info" | jq -r '.network // "?"')
    height=$(printf '%s' "$info" | jq -r '.fullHeight // 0')
    headers=$(printf '%s' "$info" | jq -r '.headersHeight // 0')
    log "ready: ${chain}, REST on :${REST_PORT}, full height ${height}, headers ${headers}"
}

# Forward a stop, and let the node close its stores.
#
# Ergo installs a JVM shutdown hook that closes RocksDB and its network layer, and
# SIGTERM is what runs it. A killed JVM can leave a store that has to be rebuilt, which
# on a snapshot-bootstrapped node means fetching the snapshot again.
stop_node() {
    local reason="${1:-signal}"
    [ -n "$ERGO_PID" ] || return 0
    [ -z "$STOPPING" ] || return 0
    STOPPING=1
    kill -0 "$ERGO_PID" 2>/dev/null || return 0

    log "${reason}: asking the node to stop"
    kill -TERM "$ERGO_PID" 2>/dev/null || true

    local deadline=$(( SECONDS + 300 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! kill -0 "$ERGO_PID" 2>/dev/null; then
            # `wait` on a child this shell started still reports the status it exited
            # with, which is the one worth carrying out of here -- the signal that asked
            # for the shutdown says nothing about whether the stores were closed.
            #
            # The `||` is not decoration: under `set -e` a non-zero `wait` would end this
            # handler on the spot, and the status it was called to collect would be lost.
            wait "$ERGO_PID" 2>/dev/null && ERGO_STATUS=0 || ERGO_STATUS=$?
            return 0
        fi
        sleep 1
    done
    log "the node did not stop in 300s; killing it"
    kill -KILL "$ERGO_PID" 2>/dev/null || true
    wait "$ERGO_PID" 2>/dev/null && ERGO_STATUS=0 || ERGO_STATUS=$?
    return 0
}

on_signal() {
    stop_node "signal $1"
}

main() {
    read_environment

    local peers
    peers=$(read_pow_peers)
    write_configuration "$peers"

    # `--mainnet` / `--testnet` is what selects the network's own config, which carries
    # the genesis id, the magic bytes and the P2P port (9030 / 9023). Those are the
    # chain's constants and not this service's business; what this service overrides is
    # in the file named by `-c`.
    "$JAVA_BIN" "$HEAP_FLAG" -jar "$ERGO_JAR" "--${NETWORK}" -c "$CONF_PATH" &
    ERGO_PID=$!

    trap 'on_signal TERM' TERM
    trap 'on_signal INT' INT

    wait_for_api
    ensure_wallet
    report

    # `wait` returns when a signal is handled as well as when the node exits, so it is
    # asked again until the process is really gone. Whichever of the two collected the
    # status -- this loop or the signal handler -- that status is what leaves this
    # script, so that a node which shut down cleanly reports as one from outside the
    # container.
    local status=0
    while kill -0 "$ERGO_PID" 2>/dev/null; do
        wait "$ERGO_PID" && status=0 || status=$?
    done
    if [ -n "$ERGO_STATUS" ]; then
        return "$ERGO_STATUS"
    fi
    return "$status"
}

# `tests/test_entrypoint.sh` sources this file to call its functions directly rather than
# re-implementing them, and sourcing it would otherwise start a JVM. One variable, read
# in one place, and nothing above it behaves differently.
if [ -z "${__ERGO_NODE_TEST:-}" ]; then
    main "$@"
fi
