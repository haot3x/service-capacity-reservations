# Pinned ASF reference dependency

Source: https://github.com/garyyang-finchip/agent-safety-framework

Commit: `64c2e27f2bda90721938327bb08751603a95a459` (revision 4)

Contracts: https://github.com/garyyang-finchip/agent-safety-framework/tree/64c2e27f2bda90721938327bb08751603a95a459/assets/erc-asf/contracts

Schemas: https://github.com/garyyang-finchip/agent-safety-framework/tree/64c2e27f2bda90721938327bb08751603a95a459/assets/erc-asf/schemas

Seven Solidity files, six JSON schemas and `LICENSE.md` are copied byte-for-byte from that commit. The manifest `SHA256SUMS` records all fourteen files. The original dependency is CC0-1.0; the local consumer under `src/asf` and integration tests are MIT, authored by Ted (@haot3x). This README and manifest are local provenance records.

Run `python3 scripts/verify-asf.py` from the project root to check dependency integrity and local policy documents. Formatting excludes `vendor/**` to preserve the upstream bytes. These integration tests compile the actual reference registries; they do not replay or certify the entire upstream test suite.

ASF is an experimental proposal. No assigned ERC number or Final status is asserted here.
