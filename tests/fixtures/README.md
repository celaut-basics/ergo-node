# `__config__` fixtures

Text-format `celaut.ConfigurationFile` sources. At each test run,
`tests/test_entrypoint.sh` encodes them with:

```sh
protoc --proto_path=service --encode=celaut.ConfigurationFile \
       service/celaut.proto < tests/fixtures/<name>.txtpb
```

That is the same schema `service/entrypoint.sh` uses to decode `/__config__`.
The test does not need Python, a generated `_pb2` module, or a nodo checkout.

| fixture | what it is for |
|---|---|
| `config-three-peers.txtpb` | The ordinary case: a `pow:ergo` resolution with three peers. The second peer has a P2P slot and a REST slot, as in a `Gateway.ResolveNetwork` answer. Another network and the gateway also contain `uri { ip, port }` blocks. |
| `config-rest-only.txtpb` | A peer with only a REST slot. The REST API is not a P2P peer. |
| `config-no-peers.txtpb` | A `pow:ergo` resolution that resolved to nobody. Not an error. |
| `config-other-network.txtpb` | Resolved onto something, but not onto our chain. A deferred `pow:ergo` network is absent like this. |
| `config-nested-tag.txtpb` | `pow:ergo` only as a slot tag of another network. Only a tag of the resolution itself selects it. |
| `config-duplicate-peers.txtpb` | The same address from two sources. |
| `config-similar-tag.txtpb` | `pow:ergo-testnet` alongside `pow:ergo`, so a prefix match would be caught. |
| `config-multi-uri.txtpb` | One instance at two addresses, in the older one-slot shape. |
| `config-bad-addresses.txtpb` | A hostname, a quote, port 0, -1 or 70000. Only an IP literal and a port from 1 to 65535 is a peer. |

## Reading one by hand

```sh
protoc --proto_path=service --decode=celaut.ConfigurationFile \
       service/celaut.proto \
  < <(protoc --proto_path=service --encode=celaut.ConfigurationFile \
             service/celaut.proto < tests/fixtures/config-three-peers.txtpb)
```
