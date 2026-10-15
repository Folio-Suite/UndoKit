<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Distribution signing identity

The maintainer approved Justin Croonenberghs as UndoKit's distribution publisher
and installed the issued certificates in Keychain. On 2026-10-15, normal local
Keychain access and an actual disposable XCFramework signing probe established:

| Field | Verified value |
| --- | --- |
| Publisher | Apple Distribution: Justin Croonenberghs (FT9KDL728H) |
| Team | `FT9KDL728H` |
| Certificate SHA-256 | `b2cb2851074eb70fbdf5f64410606c83341d088f7874934f565f429eb0cef6b8` |
| Keychain identity SHA-1 | `42B17F0D8B4B374D0CA6FF52E3C5B39609F72D67` |
| Valid from, UTC | 2026-10-15 22:07:11 |
| Valid until, UTC | 2027-10-15 22:07:10 |
| Producer | Xcode 27.0 (27A266a) |
| Secure timestamp display | Oct 15, 2026 at 5:19:24 PM, America/Chicago |

`security find-identity -v -p codesigning` lists the matching usable identity.
`codesign --sign <identity-SHA-1> --timestamp <copied-XCFramework>` succeeded.
Strict verification passed with the Apple trust anchor, exact leaf certificate,
and team requirement:

```text
anchor apple generic and certificate leaf = H"42B17F0D8B4B374D0CA6FF52E3C5B39609F72D67" and certificate leaf[subject.OU] = "FT9KDL728H"
```

The signature reports the approved authority, team and a secure `Timestamp=`.
The certificate extracted from the actual signature matches the recorded
SHA-256. Extraction with an explicit prefix uses
`codesign -d --extract-certificates=<prefix> <bundle>`; a separated prefix is
interpreted as another input path and fails on the pinned toolchain.

This probe signs a copy of an earlier unsigned assembly solely to verify the
signing path. It is not a prepared or qualified release candidate. No private
key was exported, no credential or Keychain access rule was changed, and no
release, tag or documentation site was published. Public certificate metadata
does not establish continued availability of its private key on another host.

## Protected access and replacement

Use the maintainer's existing macOS Keychain access for local preparation. The
private key stays in Keychain; let macOS enforce its access controls and any
user authorization prompt. Do not commit/export a private key, put credentials
in the publisher JSON, disable Keychain protection or copy an identity to CI as
part of this procedure. A new build host needs its own maintainer-approved
protected signing access; this local check does not provision one.

Before each candidate, use the [candidate preparation procedure](release-preparation.md)
to recheck the exact approved fingerprint, publisher/team, certificate validity,
usable identity and actual timestamped signature. Renew before expiry. A
replacement certificate needs a new recorded fingerprint and approval plus a
real sign/verify probe with the pinned Xcode. Same-team renewal is distinct
from a publisher/team change; announce the latter through the trusted release
channel and verify consumer acceptance.

Avoid routine revocation of certificates authenticating published releases.
If a compromise or replacement requires revocation, record the affected release
identities and consumer/recovery guidance. Produce a new immutable release
identity, signed bytes and checksum; never overwrite or re-sign a published ZIP.
