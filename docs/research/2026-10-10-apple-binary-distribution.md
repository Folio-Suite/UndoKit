<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Apple binary distribution requirements for the public preview

Research completed 2026-10-10 for [Establish Apple binary distribution requirements](https://github.com/Folio-Suite/UndoKit/issues/3), within [Prepare UndoKit’s multiplatform public preview release](https://github.com/Folio-Suite/UndoKit/issues/2). This note supplies facts and decision inputs; it does not approve a platform matrix, compatibility promise, or shipping artifact.

The agreed destination is a Swift-only public preview for macOS and iOS/iPadOS, with tagged source, binaries, Swift Package support, and an Xcode project. Independent hosts establish acceptance; full Folio/KitchenMemory adoption is separate.

## Local evidence and historical limits

Inspected source baseline: `9e5cf63b7ba89247de8cedd9308329e74c13f82a`. Paths below refer to that revision; no source or build configuration changed during research.

- [Package.swift](https://github.com/Folio-Suite/UndoKit/blob/9e5cf63b7ba89247de8cedd9308329e74c13f82a/Package.swift) declares Swift tools/language mode 6, macOS 14, one **dynamic** UndoKit library, and processed resources under `UndoKit/Resources`. It declares no external package dependencies. The manifest does not presently declare an iOS floor or a binary target.
- [ADR 0004](../adr/0004-independent-source-package.md) accepts source-package authority and dynamic linkage to avoid duplicate runtime identities across an app and its domain frameworks. It defers iOS and XCFramework qualification. The new map reopens that deferred scope; this research does not supersede the ADR.
- [HistoryStoreStorage.swift](https://github.com/Folio-Suite/UndoKit/blob/9e5cf63b7ba89247de8cedd9308329e74c13f82a/UndoKit/Modules/Storage/HistoryStoreStorage.swift) selects `Bundle.module` under `SWIFT_PACKAGE`, otherwise `Bundle(for: HistoryStore.self)`, and explicitly loads `History.momd`. Missing/invalid resources produce a compatibility failure. Automatic store migration and inferred mapping are disabled.
- [HistoryManagedRecords.swift](https://github.com/Folio-Suite/UndoKit/blob/9e5cf63b7ba89247de8cedd9308329e74c13f82a/UndoKit/Modules/Storage/HistoryManagedRecords.swift) gives managed-record classes explicit Objective-C runtime names. Swift-only public callers therefore do not remove internal Objective-C identity concerns.
- [Project.xcconfig](https://github.com/Folio-Suite/UndoKit/blob/9e5cf63b7ba89247de8cedd9308329e74c13f82a/Project.xcconfig) specifies macOS 14, Swift 6, complete concurrency checking, nonisolated default actor isolation, and marketing version 0.1.0. The project declares five platform SDK families, recommended target-level deployment floors, automatic Apple Development signing, and `SKIP_INSTALL=NO`. No explicit `BUILD_LIBRARY_FOR_DISTRIBUTION` setting was found. Its Release project configuration selects `dwarf-with-dsym`. These are source settings, not effective settings or archive evidence.
- The shared scheme builds only UndoKit in its BuildAction and uses Release for archiving; its TestAction references UndoKitTests.
- [Existing consumer check](../../scripts/check-consumer.sh) creates a separate macOS source-package executable and opens/reopens a history store. It is useful resource/admission coverage, but does not test a downloaded tag, binary installation, application embedding, iOS, or multiple consuming frameworks.
- [Historical distribution research](swift-objc-distribution.md) inspected a scaffold before production Swift/model implementation. Its `SKIP_INSTALL=YES`, empty implementation, Objective-C scope, five-platform matrix, and dependency discussions are historical evidence rather than current commitments. Source inspection above supersedes those observations where applicable.

## Verified external requirements

Official Apple documentation was retrieved live on 2026-10-10, including its linked Markdown representations where the browser returned a JavaScript shell. Swift compiler architecture material and Apple's older explanatory session were also read; they explain compatibility mechanisms rather than qualify a particular 2026 compiler pair.

### Artifact and archive closure

XCFrameworks hold static or dynamic platform variants. For dynamic iOS/iPadOS linking, use `.framework` bundles; standalone `.dylib` delivery is macOS-only. Device and simulator variants remain separate even when both use arm64. Apple's documented archive setup uses a framework-only scheme, `BUILD_LIBRARY_FOR_DISTRIBUTION=YES`, `SKIP_INSTALL=NO`, and default architectures. Archive each generic destination separately, then assemble with `-create-xcframework`; discover actual slices rather than treating project declarations as proof. [Apple XCFramework creation](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle).

A plausible shape is three variants: native macOS, iOS device, and iOS Simulator. That is a design inference for the agreed scope, not a chosen architecture/deployment contract. Catalyst and watchOS require separate agreement rather than silently following the current scaffold.

Apple supports resource-bearing static frameworks in Xcode 15+, omitting their already-linked archive binary when embedding resources. Thus a Core Data model alone does not demand dynamic linkage. [Apple static frameworks](https://developer.apple.com/documentation/xcode/creating-a-static-framework). For UndoKit, changing to static delivery would nevertheless reopen ADR 0004's identity decision and require a new bundle locator plus multi-consumer validation; this is inference from the local loader and record classes.

### Swift interfaces and compiler direction

Module stability and library evolution address different boundaries: compiler-readable interfaces versus compatible evolution of separately shipped code. `BUILD_LIBRARY_FOR_DISTRIBUTION` enables both; direct compiler equivalents include `-emit-module-interface` and `-enable-library-evolution`. Enabling evolution later is itself ABI-incompatible. Ordinary source packages built alongside clients generally do not need it. Public, `@usableFromInline`, `@inlinable`, and `@frozen` declarations constrain what future binary changes are safe. [Swift library evolution](https://www.swift.org/blog/library-evolution/).

Apple describes textual interfaces as readable by **future compilers from older producers**; opaque `.swiftmodule` files are compiler-version-sensitive. The reverse direction is not established: a newer producer can emit syntax/features an older consumer cannot read. [Apple binary-framework session](https://developer.apple.com/videos/play/wwdc2019/416/). An exact producer/consumer range, interface parsing, SDK availability, concurrency annotations, and actual runtime behavior therefore need agreed probes. Source-language mode `6` is not the same as a Swift compiler-version support range. These last conclusions are release-planning inferences, not additional universal compatibility guarantees.

Library evolution does not promise API source stability or persisted-history migration. Those are maintainer contracts; packaging cannot establish them. Inspect every shipped textual interface's imports and expose no accidental dependency closure. Currently the package has no third-party dependencies; future public dependencies would add their own interface/runtime compatibility work.

### Core Data resources and runtime identity

Apple loads a compiled model by URL into `NSManagedObjectModel`; `.xcdatamodeld` source is compiled to `.momd`. [Core Data stack construction](https://developer.apple.com/documentation/coredata/setting-up-a-core-data-stack-manually).

For UndoKit the binary closure must match **how it was compiled**. An Xcode framework build expects its own framework bundle's model; an SPM-derived build expects the generated package resource bundle. Copying only the dynamic executable into an XCFramework would not establish either path. Do not add `SWIFT_PACKAGE` manually to an Xcode archive as a packaging shortcut. These are inferences from the inspected conditional loader.

Apple's embedding guidance makes the app responsible for embedding dynamic framework dependencies; iOS does not support umbrella frameworks. The technical note is archived, so its older static-framework prohibitions are superseded by Apple's current static-framework guidance above. [TN2435](https://developer.apple.com/library/archive/technotes/tn2435/_index.html).

Design implication: every framework client in one process should resolve the same UndoKit runtime and resource owner. A dynamic declaration alone does not prove there is one loaded copy. Combining source-built UndoKit with a separately built binary in the same process should remain unsupported unless deliberately qualified; inspect load commands, loaded images, and managed-record identities in a representative app-plus-domain-framework host.

### Signing, notarization, and symbols

Apple documents signing the assembled XCFramework with a timestamp using Apple Development or Apple Distribution identities for Developer Program members. [XCFramework signing](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle). Xcode inspects publisher identity and can reject removed, invalid, or changed signatures; certificate replacement needs an accountable transition. [Origin verification](https://developer.apple.com/documentation/xcode/verifying-the-origin-of-your-xcframeworks).

Publisher authentication of a dependency and signing the consuming app are separate steps. macOS Developer ID software notarization uses Developer ID signatures, valid executable signatures, timestamps, and hardened runtime for apps/command-line targets. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). These docs do **not** establish a universal requirement to notarize a multiplatform XCFramework ZIP merely because it contains a macOS slice. Decide separately whether standalone runnable sample apps/installers are distributed; those have their own distribution validation. This distinction is an inference from the different documented workflows, not an exemption for any future deliverable.

A binary and its dSYM are paired by build UUID; preserve symbols from the exact released archive rather than rebuilding later to reproduce them. [Apple debugging information](https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information). Local `xcodebuild -create-xcframework -help` confirms `-debug-symbols` accepts dSYMs or bcsymbolmaps per framework/library. Research only read this help; it produced no archive. Do not infer a current bitcode requirement from that option. Public symbol-download packaging versus maintainer retention remains a support-policy choice.

## Binary Swift Package options

Apple supports remote ZIP artifacts (XCFramework at archive root, public download URL, manifest checksum), local path artifacts committed with the package, and mixed source/binary packages. The binary target's name must match its module. [Apple binary-package distribution](https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages). The current Apple article has inconsistent API cross-links/example text; the canonical manifest APIs are `binaryTarget(name:url:checksum:)` and `binaryTarget(name:path:)`. [Swift PackageDescription reference](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html).

Decision alternatives, not approved designs:

| Arrangement | Consequence to decide and test |
| --- | --- |
| Source SPM in this repo; downloadable XCFramework for direct Xcode integration | Keeps existing source workflow; binary consumers install directly. Does not offer binary SPM unless requested. |
| Source SPM here plus a separate binary-wrapper package/repository | Allows both choices with the same `import UndoKit`; aligns wrapper version and immutable artifact checksum with source release. Requires ownership of another release surface. |
| Separate source and binary manifests at explicit repository locations | Avoids a new repository but must give consumers unambiguous package URLs/paths and version semantics; ordinary root dependency resolution does not discover arbitrary alternative manifests. |
| One mixed package exposing source and binary products | Requires distinct target/module identities or a carefully qualified composition; two implementations both named UndoKit are not a straightforward selector. Never let both copies enter one consumer graph. |

These alternatives are inferences from target/module naming and the current source target. Tagged source plus downloadable binaries does not itself decide whether Swift Package support must include a binary package. Hosted artifacts must be finalized before their checksum is recorded; later signature/archive changes change bytes and require a new checksum. A checksum verifies expected archive bytes, while a publisher signature supplies identity evidence.

## Smallest useful acceptance probes for later implementation

None of these probes was run in this research.

1. Archive selected Release variants from a pinned commit/toolchain; inspect actual architectures/platform metadata, public interfaces, model resources, version values, signatures, and matching dSYM UUIDs. Assemble/sign/ZIP once and verify the final bytes after download.
2. In a fresh consumer without producer build caches, import the textual interface with each promised consumer compiler, including the oldest. Preserve a compiler-direction table and expected rejection cases rather than claiming every Swift 6 compiler works.
3. Build and run independent hosts from the exact source tag and exact binary download for macOS, iOS Simulator, and device. Each creates a store at a caller-provided URL, records/reconciles a representative transaction, closes/reopens, and reads history. Add persistence/recovery fixtures according to the separate compatibility ticket.
4. Qualify direct XCFramework and binary-SPM routes separately if both are promised. Inspect an archived/exported host's embedded framework/resources and launch that app; successful framework archiving does not prove host embedding or signing.
5. Add one app importing UndoKit both directly and through a domain framework. Assert shared types/managed-record resolution, observe one loaded runtime, and open the packaged model. A simple executable misses this identity boundary.
6. If signed releases are chosen, verify expected publisher identity and consumer embedding/re-signing, plus the documented update experience. If runnable macOS samples ship, independently test their chosen distribution/notarization path.

## Decisions this research unblocks

- Platform/toolchain matrix: deployment floors, architectures, producer compiler, supported consumer compilers, and minimum Xcode for each route.
- Binary installation contract: Xcode framework resource closure versus SPM-derived closure; dynamic linkage continuity; direct binary only or binary SPM; permitted consumer graphs.
- Preview compatibility: whether clients must rebuild at every preview update and how API/ABI claims differ from storage promises.
- Publication/support: publisher identity, certificate rollover, exact archive/symbol retention, artifact immutability, tag alignment, and evidence retained per release.

The distribution question is answered at the requirements level. Compiler interoperability, iOS runtime qualification, archive/resource closure, signing, and independent consumer acceptance remain **unrun release work**, not conclusions of this note.
