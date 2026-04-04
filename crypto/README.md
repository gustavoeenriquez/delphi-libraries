# crypto — Cryptography Libraries

Pure-Delphi cryptographic primitives. No OpenSSL, no DLLs.

## Status: Planned

This category is open for contributions.

## Landscape

Several Delphi cryptography libraries already exist under open licenses.
Before implementing from scratch, evaluate these:

| Library | Covers | License |
|---|---|---|
| [DEC](https://github.com/MHumm/DelphiEncryptionCompendium) | AES, DES, SHA, MD5, RSA | MPL 2.0 |
| [HashLib4Pascal](https://github.com/Xor-el/HashLib4Pascal) | Blake3, SHA-3, xxHash, CRC | MIT |
| [CryptoLib4Pascal](https://github.com/Xor-el/CryptoLib4Pascal) | Ed25519, ECDSA, ChaCha20 | MIT |

## Gaps worth implementing (CC0, no native Delphi library)

| Algorithm | Difficulty | Notes |
|---|---|---|
| **ChaCha20-Poly1305 AEAD** | Medium | Full AEAD construction. Partial coverage in CryptoLib4Pascal. |
| **Argon2id** | Medium | Password hashing (RFC 9106). No pure-Delphi native implementation. |
| **X25519 key exchange** | Hard | Curve25519 ECDH. Building block for TLS 1.3 / Signal protocol. |

## Want to contribute?

Follow the same structure as `audio/audio-common`:
- `src/` — `.pas` source files
- `tests/src/` — test project (`.dpr` + `.dproj`), ≥ 30 assertions
- `README.md` + `LICENSE.md` (CC0 1.0)

See the root [CONTRIBUTING.md](../CONTRIBUTING.md).
