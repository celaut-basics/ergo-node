# ergo-node

An Ergo reference node that finds its peers through the network it was *resolved* onto,
packaged as a Celaut service so a [nodo](https://github.com/celaut-project/nodo) can run
one itself.

## Why this exists

nodo already needs an Ergo node. It reads reputation proofs off the chain, it verifies
deposits, it signs payments — and all of that goes through `ledgers.ergo.NODE_URL`,
which today points at somebody else's node. That is one host deciding what this node
believes about the ledger it is paid in, and it is a URL in a config file rather than
anything the node verified.

So: the node runs the node. It hands this service an API key, the service comes up on
`:9053` speaking Ergo's ordinary REST API, and `ledgers.ergo.NODE_URL` points at
something the operator runs.

The interesting part is not the jar — it is **how it finds peers**.

## The network it asks for

An Ergo node needs a list of peers to dial. Every other packaging of one solves that by
hardcoding a list: Ergo's own `mainnet.conf` ships thirteen addresses, and every Docker
image built on it inherits them. That works, and it means the node's first act is to
trust a list somebody wrote down in 2021.

This service declares a network instead. `.service/service.json`:

```json
{
    "tags": ["pow:ergo"],
    "formal": {
        "pow.chain": "ergo",
        "pow.consensus": "autolykos-v2",
        "pow.target_block_time_s": "120",
        "ledger.model": "extended-utxo",
        "ledger.scripting": "ergoscript-sigma",
        "ledger.emission": "finite-linear-reduction",
        "ledger.native_asset": "ERG",
        "ledger.token_standard": "eip-4",

        "pow.block_id": "${ERGO_BLOCK_ID}",
        "pow.min_cumulative_difficulty": "${ERGO_MIN_CUMULATIVE_DIFFICULTY}",
        "pow.min_height": "${ERGO_MIN_HEIGHT}",
        "pow.max_tip_age_s": "3600"
    }
}
```

That is not a list of hosts, and the blank line in it is the whole design. The keys
above it say **what Ergo is**; the keys below it say **which Ergo network to join**, and
this file does not answer that second question.

### Above the line: what Ergo is

These are fixed by this service and no instantiation may change them. Each one is a
property that distinguishes Ergo from Bitcoin, or from a plain peer-to-peer protocol
like BitTorrent, and each is sourced from nodo's own description of the chain in
[`src/payment_system/contracts/ergo/interface.py`](https://github.com/celaut-project/nodo/blob/dev/src/payment_system/contracts/ergo/interface.py)
— the informal PROSE that
[nodo#385](https://github.com/celaut-project/nodo/issues/385) asked for a more formal
version of:

| key | value | what it says | where it comes from |
|---|---|---|---|
| `pow.chain` | `ergo` | The chain. The one key that can never be templated — it must agree with the `pow:ergo` tag the operator's `service_networks` policy vetted. | `interface.py:59` (`LEDGER = "ergo"`) |
| `pow.consensus` | `autolykos-v2` | The mining puzzle. Not SHA-256d: Autolykos is memory-hard and was designed to be ASIC-resistant and pool-resistant, which is a different security story from Bitcoin's. | `interface.py:50-55` PROSE, *"PoW blockchain using Autolykos"*; v2 is the version live on mainnet since the v5.0 hard fork |
| `pow.target_block_time_s` | `120` | One block every two minutes. | `src/payment_system/contracts/ergo/donation_scan.py:25-29` — *"Ergo's target block time… `SECONDS_PER_BLOCK = 120`"*, with the comment "it is a property of the chain" |
| `ledger.model` | `extended-utxo` | Boxes carrying a value, a guarding script and typed registers, spent whole and replaced — not accounts with mutable balances. Bitcoin is UTXO but not *extended*: it has no registers and no typed data on an output. | `interface.py:51` PROSE, *"verifiable eUTXO model"* |
| `ledger.scripting` | `ergoscript-sigma` | Guarding scripts are ErgoScript compiled to Sigma propositions — statements in sigma protocols, deliberately **non-Turing-complete**, so the cost of verifying a spend is knowable before running it. | `interface.py:52` PROSE, *"non-Turing-complete Sigma scripts"*; the raw form is visible as `propositionBytes` in `src/payment_system/contracts/ergo/ergo_tree.py` |
| `ledger.emission` | `finite-linear-reduction` | A capped supply whose per-block emission steps down linearly — not Bitcoin's halvings. | `interface.py:52-53` PROSE, *"finite emission with linear reduction"* |
| `ledger.native_asset` | `ERG` | What the chain's own unit is called. | `interface.py:69` (`NATIVE_ASSET = "ERG"`) |
| `ledger.token_standard` | `eip-4` | Other assets ride in the **same boxes** as ERG rather than in separate token contracts — which is why one Ergo address is paid in ERG and in every token at once. | `src/payment_system/contracts/envs.py:15`, *"the same script paid in ERG and in every EIP-4 token at the same address"* |

**On the key vocabulary.** Two prefixes, and the split is not decorative. `pow.` is the
vocabulary nodo's `src/manager/pow_networks.py` already defines and *interprets*;
`ledger.` is a neighbouring vocabulary this file introduces and **nobody enforces** —
nodo preserves and round-trips keys outside the one it reads
([`NETWORKS.md`](https://github.com/celaut-project/nodo/blob/dev/docs/NETWORKS.md)), and
that is deliberate: none of these five is checkable from an Ergo node's REST API, so a
resolver that pretended to verify them would be lying. What they are for is *identity* —
they are compared byte for byte by `match_networks`, so a network declaring a different
ledger model is a different domain even under the same tag. The set is kept small on
purpose: every key here is one more thing that must be true of any future Ergo, and a
vocabulary that describes the chain in thirty keys is one that breaks on the next hard
fork.

### Below the line: which Ergo network

`pow.block_id`, `pow.min_cumulative_difficulty` and `pow.min_height` say *which concrete
chain state* to join. **Mainnet, testnet and a private low-difficulty chain are all Ergo
by every key above** and are told apart only by these three — so hardcoding them, which
this file used to do, was this service choosing a chain on its instantiator's behalf.
That is the motivating problem in
[nodo#385](https://github.com/celaut-project/nodo/issues/385): an instance can otherwise
end up peered to an unrelated Ergo-compatible chain that nobody asked for.

So they are templates, and the instantiator fills them in:

| variable | what to put in it |
|---|---|
| `ERGO_BLOCK_ID` | A block id that is on the main chain of the network you mean. Peers are required to have it on **their** main chain, not merely to have stored it. |
| `ERGO_MIN_CUMULATIVE_DIFFICULTY` | The cumulative work (`/info` → `fullBlocksScore`) the chain had reached **at that block** — not at the current tip. Using the tip's figure makes the ask silently stricter every time the value is written, and a requirement whose meaning depends on when it was authored is one nobody can read. Written as a decimal string: Ergo's score passed 2⁶⁴ long ago. |
| `ERGO_MIN_HEIGHT` | That block's height. It restates the same fact in a form the resolver can check from `/info` alone, before spending two more requests on the block itself. |

Prefer **testnet** until you mean to join mainnet. Do not pass a mainnet mnemonic to a
test instance. A worked example for mainnet, which is what this file used to hardcode —
the values are *examples*, not defaults, and there is nothing in the service that
supplies them:

```sh
# A real block at a round height:
curl -s https://node.sigmaspace.io/blocks/at/1870000
# ["a7439dad316fc1f387871b9839660b3ad3ada657e6cb0a9a28d807b78346aba9"]

# The chain's score AT that block, derived by subtracting every block after it
# from a tip score:
curl -s https://node.sigmaspace.io/info
#   "fullHeight" : 1875916
#   "fullBlocksScore" : 2750033340952676925440
curl -s "https://node.sigmaspace.io/blocks/chainSlice?fromHeight=H&toHeight=H2" | jq -r '.[].difficulty'
# sum over 1870001..1875916 = 391512580402708480  (5916 blocks, no gaps, no duplicates)
# 2750033340952676925440 - 391512580402708480 = 2749641828372274216960
```

```yaml
ERGO_BLOCK_ID: "a7439dad316fc1f387871b9839660b3ad3ada657e6cb0a9a28d807b78346aba9"
ERGO_MIN_CUMULATIVE_DIFFICULTY: "2749641828372274216960"
ERGO_MIN_HEIGHT: "1870000"
```

**`pow.max_tip_age_s` is deliberately NOT templated.** It selects no chain: every Ergo
network produces blocks on the same 120-second target, so a peer stalled an hour behind
is useless for bootstrapping whichever one it is on. What it does is keep a pinned block
from decaying into a weaker and weaker ask as the chain grows past it — every node passes
a 2024 block eventually, and an hour's tip age is the condition that still means
something in 2030. Templating it would have handed an instantiator a knob whose only
use is to make the ask worse.

### What happens when they are not set

**The launch proceeds normally and the node starts with `knownPeers = []`.** With
[nodo#385](https://github.com/celaut-project/nodo/issues/385) the resolution policy is
per network and driven by whether its templates are answered:

| | |
|---|---|
| all three set | The node substitutes them, resolves `pow:ergo` at launch — verifying each candidate against exactly those conditions (`src/manager/pow_networks.py`) — and writes the survivors into this instance's `__config__`. For a guest that declares `ergo-p2p` and not `ergo-rest`, nodo keeps only the P2P slot (`pow_networks.narrow_instances_for_local_grant`). `service/entrypoint.sh` reads those P2P `uri` values into `scorex.network.knownPeers`. It skips a uri_slot whose port is an `ergo-rest` slot. |
| any of them unset | The node **defers** this network: it resolves nothing, omits the entry from `__config__`, logs which variables were missing, and **does not fail the launch**. The entrypoint's existing empty-resolution path takes over — `knownPeers = []`, said out loud in the log, node up on its REST API. It can be resolved later over `Gateway.ResolveNetwork`. |

A deferred network is not an error and not a fallback to a hardcoded list. **No address
is hardcoded anywhere in this repository**, which is why an unresolved network means no
peers rather than Ergo's thirteen.

**There is no `*` egress.** A Bitcoin node needs it, because it discovers peers through
DNS seeds and then dials whatever they hand back, so the set cannot be enumerated in
advance — [`celaut-basics/bitcoin-node`](https://github.com/celaut-basics/bitcoin-node)
says exactly that and asks for open egress. An Ergo node does not have to work that way:
given a peer list it starts from, `peerDiscovery` does the rest over the connections it
was granted. What this service asks to reach is a set the node verified, and the firewall
rule the node writes is for those peers and nothing else.

## The environment it reads

| variable | | what it is |
|---|---|---|
| `ERGO_API_KEY` | **required** | What callers authenticate to `:9053` with. Stored in `ergo.conf` as its BLAKE2b-256 hash, never in plaintext. |
| `ERGO_NETWORK` | `mainnet` | `mainnet` or `testnet`. |
| `ERGO_DATADIR` | `/data` | Where the node keeps its stores. Must be an absolute path. |
| `ERGO_NODE_NAME` | `celaut-ergo-node` | The name sent in the P2P handshake. Letters, digits, `.` `_` `:` `-` only. |
| `ERGO_MAX_HEAP` | (empty) | The JVM's `-Xmx`, for example `3G` or `2048M`. Empty means 60 % of the guest RAM (`-XX:MaxRAMPercentage=60.0`). nodo boots the microVM with `resources.at_init.mem_limit` and does not add more unless the service asks. |
| `ERGO_BLOCKS_TO_KEEP` | `1440` | Full blocks to retain — roughly a day. `-1` keeps all of them, turns the fast bootstrap off, and needs the disk raised accordingly. |
| `ERGO_WALLET_MNEMONIC` | — | Optional, and **requires `ERGO_BLOCKS_TO_KEEP=-1`** — see below. Restored through the node's own `/wallet/restore`. |
| `ERGO_WALLET_PASSWORD` | — | Required *if* a mnemonic is set: the keystore's encryption password. |
| `ERGO_WALLET_MNEMONIC_PASSPHRASE` | — | Optional BIP-39 passphrase. Unset and empty are **different wallets**. |

The REST API is on **9053 on both networks**, so whatever launches this has one endpoint
to talk to and does not have to know which chain it asked for.

### The three the *node* reads, not the service

| variable | | what it is |
|---|---|---|
| `ERGO_BLOCK_ID` | see below | A block on the main chain of the Ergo network you mean. |
| `ERGO_MIN_CUMULATIVE_DIFFICULTY` | see below | The chain's cumulative work at that block, as a decimal string. |
| `ERGO_MIN_HEIGHT` | see below | That block's height. |

These are **not read by `service/entrypoint.sh`**. The packer does not record `envs`
(`src/packers/zip_with_dockerfile.py`). Pass them with `nodo execute -e`. The nodo that
launches this instance substitutes them into the `pow:ergo` network `formal` before it
resolves the network. The entrypoint reads only the peers that ended up in `/__config__`.
The node always writes that file at `/__config__`. It ignores `config_declaration.path`.

They are therefore **not required, and have no defaults**. Leave any of them unset and
the network is *deferred*: the node resolves nothing for it, the launch succeeds, and
this service starts with `knownPeers = []`. Set all three and it starts peered. See
[The network it asks for](#the-network-it-asks-for) for what to put in them and why
this file does not decide it for you.

## The wallet

Optional, and off unless `ERGO_WALLET_MNEMONIC` is set — a node that only needs to *read*
the chain should not set it, and then this service holds no key at all.

When it is set, the mnemonic goes to the node's own `/wallet/restore` rather than into a
keystore this service wrote. That is the whole design: Ergo owns that file's format and
its encryption parameters, the derivation is Ergo's own EIP-3 path (`m/44'/429'/0'/0/0`),
and **any standard Ergo wallet opens the same funds from the same words**, with no
knowledge of this service. A second implementation of the keystore in `bash` would be a
second thing to keep in step with a format this service does not define.

`usePre1627KeyDerivation` is sent as `false`. The pre-EIP-3 derivation was the default
before node 4.0.105, and restoring under it gives a *different* wallet, silently, for
anything generated since — a service with no way to know which era a mnemonic came from
should take the one every current tool produces.

### A wallet and a fast bootstrap cannot both be had

This is Ergo's rule, not this service's, and it is worth stating plainly because it
decides how the service is configured:

```scala
val isFullBlocksPruned: Boolean = blocksToKeep >= 0 || utxoSettings.utxoBootstrap

if (settings.nodeSettings.isFullBlocksPruned)
  Failure(new IllegalArgumentException("Unable to restore wallet when pruning is enabled"))
```
<sub>`NodeConfigurationSettings.scala`, `ErgoWalletService.scala`, v6.0.5</sub>

So the UTXO-snapshot bootstrap that makes this service fit in 8 GB is exactly what makes
`/wallet/restore` return HTTP 400. Setting `ERGO_WALLET_MNEMONIC` therefore **requires**
`ERGO_BLOCKS_TO_KEEP=-1`, which also turns the fast bootstrap off and means a full sync
from genesis on a disk much larger than the declared 8 GB.

The entrypoint refuses that combination at startup, with the rule quoted, rather than
letting the JVM start and the restore fail forty seconds later. A node that only *reads*
the chain — which is what `ledgers.ergo.NODE_URL` needs — should leave the mnemonic unset
and keep the cheap bootstrap.

(Both halves of `isFullBlocksPruned` have to move together, and so does a third setting:
Ergo also refuses to *start* with `nipopowBootstrap` on unless the node is pruned in one
of those two senses. That is why `utxoBootstrap` and `nipopowBootstrap` are one flag in
the entrypoint and not two — "bootstrap fast" and "keep everything" are the two
configurations Ergo actually has, and a mix of them is one it stops on. Both of these
were found by running the image, not by reading the docs. On testnet, NiPoPoW is off
even without a wallet: `testnet.conf` does not set `ergo.chain.genesisId`, and Ergo
refuses `nipopowBootstrap` without it. The UTXO snapshot bootstrap stays on.)

And the related limitation, for the unpruned case: **a snapshot-bootstrapped node cannot
rescan history it never downloaded.** With `utxoBootstrap = true` the node's state begins
at the snapshot, so even setting the rule above aside, a mnemonic with older history
would not show those funds.

## What it costs to run

The declared numbers, and where they come from:

**Disk: 8 GB.** The node boots from a verified UTXO set snapshot plus a NiPoPoW header
proof rather than replaying the chain, so the ~95% of history before the snapshot is
never downloaded. What is actually on disk is the UTXO set, the header chain, and
`ERGO_BLOCKS_TO_KEEP` full blocks:

- headers — `221` bytes each at every height sampled (100k, 500k, 1M, 1.5M, 1.875M, via
  `/blocks/{id}/header`), × ~1.88M heights ≈ **0.42 GB**;
- the UTXO snapshot — ergodocs' pruned-node page puts a bootstrap at "~1-2GB + recent
  blocks";
- 1440 full blocks at a mean of **30398 bytes** (measured over the last 4000 blocks via
  the explorer's `/api/v1/blocks`) ≈ **0.04 GB**.

That is ~2.5 GB of content, and 8 GB is the headroom RocksDB's compaction and the
snapshot download need on top of it. For scale: the same measurement puts the chain's
own growth at **~8 GB/year** (30398 B × 720 blocks/day × 365), which is what
`ERGO_BLOCKS_TO_KEEP=-1` would be signing up for and why it is not the default.

**Memory: 4 GB at init and at most, two vCPUs.** nodo boots the guest with
`at_init.mem_limit`. This service never calls ModifyServiceSystemResources, so a 2 GB
start with a 3 GB heap lets the guest kernel kill the JVM. The default heap is 60 % of
that RAM. The rest is for RocksDB, the JIT and the threads.

**A Celaut instance has no persistent volume for its own data.** Stop the instance and
the stores go with it, so the next start bootstraps from a snapshot again — minutes
rather than the hours a full sync would take, which is most of the reason this service
bootstraps that way. Leave the instance running; the node only starts it when it is not
already up.

## Where the secret is

`ERGO_API_KEY` and, if set, `ERGO_WALLET_MNEMONIC` arrive in the environment. That means:

- they are in the node's `config.yaml`, and with a wallet configured that file is **the
  only backup of it** — this service stores no keys, it hands them to Ergo;
- the node records how each instance was launched and **redacts** these values, keeping
  the variable's name and not its contents;
- nothing here logs them. Not the mnemonic, not the API key, not the spending password.
  The API key reaches `curl` through a mode-0600 config file and the wallet request
  bodies through mode-0600 files built by `jq` from the environment — never through
  `argv`, which anything running as the same user can read out of `/proc`. The log says
  which network, which peers, what height it reached and the wallet's first address.

## Building it

There is no `nodo run` or `nodo stop`. Pack, start, open a tunnel, then kill.

```sh
nodo pack .
# prints: Service ID -> <hex>

# Testnet only until you mean to join mainnet. Do not pass a mainnet mnemonic.
nodo execute -e ERGO_API_KEY 'test-key' -e ERGO_NETWORK testnet \
  -e ERGO_BLOCK_ID '<testnet-block-id>' \
  -e ERGO_MIN_CUMULATIVE_DIFFICULTY '<score-at-that-block>' \
  -e ERGO_MIN_HEIGHT '<height>' \
  <id-or-tag>

nodo tunnel <instance> 9053
nodo kill <instance>
```

`nodo pack` accepts a directory or an `https://` git URL. It does not accept `--fast`
or `--arch`. The architecture comes from `.service/service.json`.

Then point the node at that id:

```yaml
core_services:
  ergo-node: "<the id nodo pack printed>"
```

The image is `linux/arm64`. The Ergo jar is JVM bytecode and is architecture-independent
— what `architecture` in `.service/service.json` describes is the base image and the JRE
tarball, so another architecture needs those two changed and nothing else. A typical
x86_64 nodo does not pack this tree unless QEMU TCG is on (`virtualizers.qemu.ENABLE`,
default false).

The packer build context is `.service/`. Project files land in `.service/service/`.
`COPY ./service` is rewritten to `service/service`. A bare `COPY service` is not
rewritten and the build fails. The guest does not get Dockerfile `ENV` or `PATH`.
The entrypoint calls `/opt/java/bin/java` by its full path.

Everything is pinned: the base image (`debian:bookworm-slim`) by digest, the Temurin 17
JRE by the SHA-256 Adoptium publishes, the Ergo 6.0.5 jar by a SHA-256 computed from the
published artifact, and the eight Debian packages on top to their exact versions.

Two of those deserve their caveat stated rather than glossed over. **Ergo publishes no
`SHA256SUMS` file**, so unlike Bitcoin Core's, the jar's checksum here has no upstream
document to be compared against: what is pinned is *an* artifact, in a reviewed file,
which cannot change without a diff. Verifying the release signature would be the
improvement. And **pinning packages to the patch version** means the build stops when one
of them leaves the mirror after a security update, until this file is edited — the same
trade `celaut-basics/bitcoin-node` already makes, and the one that keeps a key holder
from being "whatever the mirror served today".

## Tests

```sh
bash tests/test_entrypoint.sh
```

`bash`, `protoc`, `awk` and `b2sum` — the same four the service uses, which is what makes
the tests worth running on a workstation as well as in the image. On macOS:
`brew install protobuf coreutils`.

They cover the two things that fail *quietly* in production:

**Reading `__config__`.** Nine `.txtpb` fixtures. The test encodes each file with
`protoc --encode=celaut.ConfigurationFile` and the vendored `service/celaut.proto`.
That is the same schema the entrypoint uses to decode `/__config__`. The test needs no
Python and no nodo checkout. They check that a `pow:ergo` resolution's P2P peers are
read in order; that a REST slot is not a peer; that `pow:ergo` as a slot tag of another
network does not select it; that another network's peers and **the gateway instance**
are not peers; that `pow:ergo-testnet` is not matched as a prefix; that duplicates
collapse; that every `uri` of a multi-address instance is read; that a hostname, a quote
or a bad port is skipped; that a missing `__config__` starts the node; and that a file
that does not decode stops the start.

**The rendered config.** That an empty resolution writes `knownPeers = []` and not a
missing key — Ergo's `mainnet.conf` is a *fallback* under the user's config, so an absent
`knownPeers` is not "no peers", it is those thirteen hardcoded addresses, on a service
whose spec says it dials only what it was resolved onto. Also that the API key itself
appears nowhere in `ergo.conf`, and that the file and the curl config are mode 0600.

**The API key hash**, against the vector Ergo ships in its own `application.conf`,
`mainnet.conf` and `testnet.conf` (`blake2b-256("hello")` =
`324dcf02…1b72cf`, which the node's `/utils/hash/blake2b` returns for the same input),
and against BLAKE2b's published empty-input vector — which is there to pin the *output
length*, since a 256-bit BLAKE2b is a different hash and not a truncated 512-bit one.

**The pruning rule**, which is the one that decides how this service can be configured at
all: that a mnemonic on a pruned node is refused before the JVM starts, that
`ERGO_BLOCKS_TO_KEEP=-1` is accepted, and that it turns *both* bootstrap settings off.

And one regression that was found by writing them: `read_pow_peers` logs to **stderr**,
because its stdout is the peer list. A log line on the same stream would have been parsed
as an address.

What they do **not** cover is anything past that boundary: no JVM is started, no chain is
synced, no wallet is restored. That was done by hand instead — see below.

## What was verified by running it

The image was built for `linux/arm64` and run, which is where three of the bugs above
came from. In order:

- **The peer list reaches the node.** With a fixture `__config__` naming three `pow:ergo`
  peers, `/peers/all` came back with **exactly those three** and nothing else — which is
  the proof that `mainnet.conf`'s thirteen hardcoded addresses were not used — and
  `/peers/connected` showed a live handshake with one of them.
- **An empty resolution starts anyway**, logging that it did, with `knownPeers = []`.
- **SIGTERM shuts it down cleanly**: `docker stop` returned in 1.1 s with Ergo's own
  "Going to shutdown all connections & unbind port" and "Stopping ErgoNodeViewHolder" in
  the log, and PID 1 exited 143.
- **The wallet round-trips.** On `ERGO_BLOCKS_TO_KEEP=-1`, restore → unlock → an address
  read back out of `/wallet/addresses`. Restarting the container took the
  already-initialized path and unlocked the same wallet.
- **Nothing leaks.** `docker logs | grep -c` for the mnemonic, the API key and the
  spending password: **0** on every run.

What is still **not verified**: a full chain sync (the Docker runs above reached height 0),
and **`nodo pack` / `nodo execute` on a real nodo**. This audit host has no KVM. Nothing
in this tree was packed or launched on a node.

## What this depends on

These nodo changes are on `celaut-project/nodo` branch `dev`. A node older than that
will fail in the ways below.

- **[nodo#383](https://github.com/celaut-project/nodo/pull/383)** — the packer carries
  `network[].formal` and `network[].protocol_stack` from `service.json`. Before it,
  `parseNetwork` read `tags` and `prose` and dropped the rest, so the `formal` block
  above would pack to nothing and this service would ask for "any `pow:ergo` peer"
  instead of the one it declares.
- **[nodo#384](https://github.com/celaut-project/nodo/pull/384)** — the `pow:ergo`
  resolver emits each peer's P2P endpoint. A peer is *verified* over its REST API
  (`:9053`) and has to be *dialled* over Ergo's P2P port (`:9030` on mainnet, `:9023` on
  testnet). The entrypoint writes the P2P addresses it is given. It does not translate
  ports. It skips an `ergo-rest` slot.
- **[nodo#386](https://github.com/celaut-project/nodo/pull/386)** (implements
  [nodo#385](https://github.com/celaut-project/nodo/issues/385)) — `${VAR}` templates in
  `network[].formal`, substituted at launch from the launcher's environment, with a
  network whose variables are unanswered *deferred* rather than resolved. Against a
  nodo without it, `parse_pow_formal` refuses `pow.block_id=${ERGO_BLOCK_ID}` as
  non-hexadecimal and **`nodo pack .` fails outright**.

## What is not here

- **Mining.** `mining = false`, always. A validating node is what nodo needs.
- **`extraIndex`.** The indexed `/blockchain/...` routes cost disk and indexing time, and
  nothing in nodo's Ergo path reads them.
- **An archival node.** `ERGO_BLOCKS_TO_KEEP=-1` gets close, with the disk raised to
  match; the declared 8 GB does not fit the full chain.
- **Signature verification of the Ergo release** (above).
- **Tor.** Ergo's defaults, on the egress the node gives the instance.
