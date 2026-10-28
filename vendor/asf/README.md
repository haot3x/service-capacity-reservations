# Pinned ASF reference dependency

Source: https://github.com/garyyang-finchip/agent-safety-framework

Commit: `a76071c0e0ab76c296a0eb878dee1365ce5a78bc` (revision 7)

Contracts: https://github.com/garyyang-finchip/agent-safety-framework/tree/a76071c0e0ab76c296a0eb878dee1365ce5a78bc/assets/erc-asf/contracts

Schemas: https://github.com/garyyang-finchip/agent-safety-framework/tree/a76071c0e0ab76c296a0eb878dee1365ce5a78bc/assets/erc-asf/schemas

Nine Solidity files, six JSON schemas and `LICENSE.md` are copied byte-for-byte from that commit. The manifest `SHA256SUMS` records all sixteen files. The original dependency is CC0-1.0; the local consumer under `src/asf` and integration tests are MIT, authored by Ted (@haot3x). This README and manifest are local provenance records.

Run `python3 scripts/verify-asf.py` from the project root to check dependency integrity and local policy documents. Formatting excludes `vendor/**` to preserve the upstream bytes. These integration tests compile the actual reference registries; they do not replay or certify the entire upstream test suite.

ASF is an experimental proposal. It is discussed as ERC-8468; no Final status is asserted here.
