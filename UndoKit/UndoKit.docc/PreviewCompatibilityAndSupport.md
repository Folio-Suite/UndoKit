# Preview compatibility and support

<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

Distinguish intended support, actual qualification and published identity.

## Preview promises

The first qualified preview baseline is version 0.2.0. Its compatibility promises
begin with actual qualification, not a planned version label or development build.
Before that baseline, public APIs are under frost, with qualification-driven
changes documented. No migration from tagged 0.1.0 or experimental stores is
promised. Unsupported history is preserved and refused.

After the qualified preview, patches preserve public source compatibility and
documented behavior; minor 0.x releases may change APIs with migration guidance.
Supported retained histories remain usable directly or through supported
structural migration, subject to the host's retained codecs/resources. From 1.0,
public API or persisted-compatibility breaks require a major release, with a
supported forward migration or documented staged upgrade for supported stores.
There is no downgrade guarantee or promise that older readers open newer stores.

Any future structural migration requires explicit host opening permission,
recoverable originals, validated replacement and commit after successful
preparation. The current implementation exposes no speculative migration switch:
automatic/inferred Core Data migration is disabled and incompatible models are
refused. Structural migration cannot reinterpret opaque domain payloads.

## Release identity and evidence

A published release uses an immutable plain three-part annotated tag, matching
marketing version, monotonic framework build number, source commit and final
archive checksum. The complete dynamic XCFramework includes matching dSYMs and
model/privacy resources. Approved Apple Distribution signing with secure timestamp
precedes the one release ZIP/checksum; qualification and promotion use those same
bytes without rebuilding or re-signing.

Documentation snapshots must identify their version/source. Development docs must
be labelled separately. A latest-release pointer advances only when the matching
release is available. Corrections must be visible; newer API guidance must not
silently replace a historical contract. GitHub release and Pages deployment are
coordinated steps, without an atomic-publication promise.

The [qualification amendment](https://github.com/Folio-Suite/UndoKit/issues/57)
accepts clean declared-architecture builds without dedicated Intel execution.
Actual floor/current OS behavioral tests remain required using appropriate
runners, simulators, VMs or hardware. Physical tests address specific unresolved
behaviors rather than a blanket device matrix. Binary archive/export/symbolication
evidence remains separate. Qualification names its source/artifact/configuration,
environment and limitations; a waived execution is not a runtime pass. Actual
abrupt termination remains unqualified. Missing required behavioral evidence
cannot be labelled passing.

## Get help safely

Use the repository's GitHub Issues for a small fictional reproduction. Include
UndoKit version/build or source commit, package/project/XCFramework route,
embedded/shared installation, device/model/architecture, OS/build, Xcode/Swift
versions and language mode, configuration, expected/actual behavior and sanitized
diagnostics. Do not upload real host databases, user content or raw payloads.

Suspected vulnerabilities use the verified private route in SECURITY.md rather
than public issues, discussions or PRs. Latest-preview support is best effort,
without a response-time guarantee or routine backports; older versions receive
upgrade guidance. That support policy does not weaken the forward persisted-history
continuity contract. Reports outside the qualified matrix do not extend support.
