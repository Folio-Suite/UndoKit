<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Standard maintenance gate

Run the maintenance gate from the repository root with:

```sh
ruby scripts/maintenance/check.rb
```

The command is also a job in the standard GitHub Actions workflow. It uses
SwiftLint 0.65.1 from the repository's pinned SwiftLintPlugins 0.65.1 package
revision and the checked-in `.swiftlint.yml`. If that artifact is not cached,
the command resolves the locked Xcode package first. It does not change the
SwiftLint rules, thresholds, or source inventory. Lint coverage is the framework
and production tests selected by `.swiftlint.yml`; prototypes and generated
build output are outside that inventory.

The checked-in baseline records each reviewed finding with its rule, severity, source
line and adjacent context, the lint message, and a disposition. The gate matches
the trimmed source context and rule at that path, counting duplicate findings
separately. A new or changed finding fails with its location and source line.
When a finding is fixed, remove its baseline entry in the same change; stale
entries fail so exemptions do not accumulate. The baseline also records its
source revision and the exact configuration hash. Rule or threshold changes
require explicit review and a corresponding baseline update.

One existing error-severity `type_body_length` finding is recorded as reviewed
debt: `NativeHistorySessionTests` spans 650 lines against the configured 350-line
error threshold. The test fixture remains cohesive today; revisit this debt with
the native editing test suite.

The remaining checks validate local Markdown destinations, Ruby and shell
syntax for maintained runners under `scripts/`, and SHA-256 values in
`docs/imported-design/preservation-checksums.json`. The local-link scanner
supports inline links and single-line reference definitions, including angle
brackets around destinations with spaces and optional titles. File and directory
destinations are accepted. External URLs and fragment-only anchors are ignored;
the gate does not contact external sites or validate remote links. It reads
preserved artifacts without modifying them. Historical prototype sources are
not built or executed by this command.

The prerequisites are macOS with the repository's pinned Xcode 27.0 / Swift
6.4 toolchain, Ruby 2.6 or later, Bash, and the pinned SwiftLint package
artifact. The runner uses Ruby's standard library only and is compatible with
the Ruby 2.6 runtime available to contributors. The same command and lint
configuration run locally and in CI. Package Debug/Release
tests and independent consumer checks remain separate existing CI checks;
native project and Release qualification remains scoped to issue #13.
