# HoverPocket device pairing v1

Separate EUPL-1.2 executable using magic-wormhole 0.8.1 (SPAKE2 + authenticated encrypted messages). No homemade cryptography. Requires Rust 1.87 or later. Build: `cargo build --release --locked --manifest-path shared/pairing-helper/Cargo.toml`.

The public TLS rendezvous is `wss://mailbox.mw.leastauthority.com/v1`. It sees network addresses and timing, but not decrypted device metadata or media. This helper transfers no library files. Syncthing subsequently transfers files using its certificate-authenticated encrypted connections. Availability depends on Syncthing and the rendezvous service; no insecure fallback. The host must explain this briefly under connection details.

## Local stdio contract

UTF-8 JSON lines, camelCase. One process per session, 300 second absolute deadline, one PAKE attempt. Never log stdin/stdout: codes and peer metadata are sensitive. Kill the child on cancellation, window close, replacement or application exit. Do not inherit HOVERPOCKET_PAIRING_TEST_RELAY outside isolated tests.

First stdin: `{ "role":"invite", "deviceId":"SYNCTHING-ID", "deviceName":"Windows", "platform":"windows", "groupId":"lowercase UUID", "folderId":"hoverpocket-library-UUID" }`.
For join, `role` is `join`, `code` is the user code and groupId/folderId may be null. Existing configured libraries MUST pass their actual group and folder IDs: mismatches fail. macOS uses platform `macos`. Get the device ID from the authenticated local Syncthing API, never invent it. A new invitation chooses its group UUID before spawning, but does not enable sharing yet.

Stdout events:
- `code`: code (mailbox-number plus 8 random digits), expiresInSeconds=300. Display only on inviting device; never save to disk.
- `peer`: approvalId, verification (8 uppercase hex digits), peer (version, role, nonce, deviceId, deviceName, platform, groupId, folderId), groupId, folderId. approvalId binds the complete ordered identity transcript. Display the peer name/platform and verification on both devices. Inviter explicitly approves this exact approvalId. Joiner shows waiting for approval and may send ready after local preflight succeeds.
- `approved`: same fields except verification. Both decisions accepted. Only now may host configure the dedicated Syncthing share and local sync group.
- `complete`: both hosts reported applied. Show connection complete; actual file synchronization progress is separate.
- `error`: reason is a fixed public identifier. Terminal even if exit code is zero. A closed stdout without complete is a failure.

Stdin after peer: `{ "action":"approve", "approvalId":"exact value" }` for inviter, `ready` for joiner, or `decline` to reject. After approved: action `applied` only after successful local configuration and readback, otherwise `failed`. No approval may be cached/reused. Cancel by killing the process.

## Host integration rules

Preserve any existing library group/path, particularly hoverpocket-library-sync-v1. Discover its dedicated folder by exact normalized path. For new groups use an app-managed transport separate from database/originals. Refuse reparse/symlink paths, existing foreign folder IDs and markers with a different group. After approved, securely create the marker `{ "version":1, "groupId":"authenticated group" }` if absent in an otherwise empty dedicated directory, then configure local sync using the existing sync-v1 implementation.

Read full Syncthing device/folder objects and preserve all unrelated fields. Existing global devices must not be renamed or edited. New peers have introducer and autoAcceptFolders false. Only add/remove IDs from this dedicated folder. Never remove global devices or touch Eagle folders. Read back changes before reporting applied. If setup fails, roll back additions to this share before showing a retryable error; preserve files. Removal stops this share only; already received copies remain. A peer allowed into a library receives the whole library, including trash.

Require local Syncthing GUI/API bound to loopback. Keep API key in native memory, never WebView/SwiftUI state or logs. Public code pairing currently requires Syncthing installed/running on each desktop; do not claim standalone mobile sync. Future iPhone needs its own transport implementation.

## Verification

`cargo test --locked --manifest-path shared/pairing-helper/Cargo.toml` tests validation. `python shared/pairing-helper/verify_pairing.py path/to/hoverpocket-pairing.exe` runs isolated two-process handshake/decline/wrong-code/group mismatch checks via the real TLS rendezvous using fictional identities, without opening media or changing Syncthing. Use only when network access is authorized. Optional test relay override accepts loopback only.

License regeneration: install cargo-about 0.9.2 with the cli feature, then run `cargo about generate --locked --fail -m shared/pairing-helper/Cargo.toml --target x86_64-pc-windows-msvc --target aarch64-apple-darwin --target x86_64-apple-darwin -o shared/pairing-helper/THIRD-PARTY-LICENSES.html shared/pairing-helper/licenses.hbs`. Windows and macOS packages include the helper executable plus LICENSE.txt, NOTICE.md and THIRD-PARTY-LICENSES.html.
