# Typed Swift, Objective-C, and XCFramework compatibility

Research for [Establish typed Swift, Objective-C, and XCFramework compatibility](https://github.com/ctwelve/UndoKit/issues/4), within [Define UndoKit for Folio and KitchenMemory](https://github.com/ctwelve/UndoKit/issues/1). Investigated September 25–26, 2026. This is evidence for later interface and distribution decisions, not an approved API or a shipping configuration.

## Findings that shape the decision

Idiomatic Swift payloads and an independently usable Objective-C interface can share a history engine. Swift callers can submit and recover their own concrete values through generic codecs; they need not manually translate a model into Foundation collections. An Objective-C-facing layer can use Objective-C-compatible objects and codec contracts over the same encoded records. The languages need not expose identical declarations. This is a design inference from Swift's generic, coding, and Objective-C interoperability facilities, not a compiled UndoKit proof. [Swift generics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/), [Apple coding guidance](https://developer.apple.com/documentation/foundation/encoding-and-decoding-custom-types), [Objective-C exposure rules](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#objc).

Supporting a client's `OrderedDictionary` payload does **not** by itself require `OrderedDictionary` in UndoKit's public signatures. Its existing conditional `Codable` conformance can participate in a host type's codec. Conversely, exposing a package type in the binary API makes the package module and its compatibility part of the distribution contract. These are independent choices. [OrderedDictionary coding implementation](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/OrderedCollections/OrderedDictionary/OrderedDictionary%2BCodable.swift), [Swift dependency visibility rules](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md#transitive-dependency-loading).

The existing project is a dynamic framework scaffold with five declared platform variants. Effective deployment minima are substantially older than SDK 27.0. It is not yet configured for binary distribution: `BUILD_LIBRARY_FOR_DISTRIBUTION=NO` and `SKIP_INSTALL=YES`. No archive, compiler interoperability probe, packaged resource load, or runtime acceptance test was performed in this investigation.

## Recorded environment and source versions

| Input | Observed revision or version |
| --- | --- |
| UndoKit baseline | `b94fbbd7685165dbd083ae155375855f848d0845` |
| KitchenMemory, clean working tree | `23353f56968774cae0f7882f602dd2491e2737a5` |
| Folio, clean working tree | `135b69515aedb17ea10db87f970257528f7e8ed9` |
| Xcode | 27.0, build `27A266a` |
| Compiler | Apple Swift 6.4, `swiftlang-6.4.0.34.1`, clang `2100.3.34.1`; swift-driver `1.168.6` |
| SDKs examined by build settings | macOS, iOS, iOS Simulator, watchOS, watchOS Simulator: 27.0 |
| KitchenMemory Collections pin | 1.7.0, `a66de878e87ef5a3d5d390e0f6d9002aa5541a43` |
| Current Collections release/main at lookup | 1.7.1, `98ef3c98609a1e31b7e157b5b619579001a789d6`; published `2026-09-25T23:47:50Z` |
| KitchenMemory Algorithms pin/current latest release | 1.2.1, `87e50f483c54e6efd60e885f7f5aa946cee68023` |
| Algorithms main inspected, not the release baseline | `5b7143f8e291dee0e14c118fd0212487f0b37af5`, committed `2026-07-22T23:09:31Z` |
| KitchenMemory transitive Numerics pin | 1.1.1, `0c0290ff6b24942dadb83a929ffaaa1481df04a2` |

Consumer pins come from [KitchenMemory's Package.resolved](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/KitchenMemory.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). Current versions were read directly through GitHub's repository APIs; a browser-cached Collections latest-release page still reported 1.6.0. The [1.7.1 release](https://github.com/apple/swift-collections/releases/tag/1.7.1) and [exact comparison with 1.7.0](https://github.com/apple/swift-collections/compare/a66de878e87ef5a3d5d390e0f6d9002aa5541a43...98ef3c98609a1e31b7e157b5b619579001a789d6) establish the current snapshot. The coding and principal type-declaration files cited below are unchanged in that comparison; it does include HashTreeCollections bug fixes, so unchanged coding declarations are not proof of identical behavior.

Two local Xcode caches contained different Collections versions. Type inspection used the checkout whose HEAD matches the **1.7.0 pin**, not the older cache at `a0cb0954ecb21e4e31b0070e6ed5674e8556685a`. Current README/manifests were additionally fetched at exact upstream revisions. No consumer dependencies were resolved or changed.

## Actual project and consumer observations

The [UndoKit project](https://github.com/ctwelve/UndoKit/blob/b94fbbd7685165dbd083ae155375855f848d0845/UndoKit.xcodeproj/project.pbxproj) declares `iphoneos iphonesimulator macosx watchos watchsimulator`, disables Catalyst and the designed-for-iPhone/iPad Mac/XR modes, uses Objective-C module verification, and has no package references. Its public [umbrella header](https://github.com/ctwelve/UndoKit/blob/b94fbbd7685165dbd083ae155375855f848d0845/UndoKit/UndoKit.h) currently exposes version symbols only. There is no production Swift implementation or Core Data model yet; explicit resource entries include the license and README.

`xcodebuild -showBuildSettings -json`, Release configuration, scheme `UndoKit`, with each generic destination and normal Xcode access produced:

| Destination | Effective deployment minimum | Effective `ARCHS` |
| --- | --- | --- |
| macOS | 14.0 | `arm64 x86_64` |
| iOS / iPadOS | 17.0 | `arm64` |
| iOS Simulator | 17.0 | `arm64 x86_64` |
| watchOS | 10.0 | `arm64 arm64_32` |
| watchOS Simulator | 10.0 | `arm64 x86_64` |

All five report `MACH_O_TYPE=mh_dylib`, `DEFINES_MODULE=YES`, `BUILD_LIBRARY_FOR_DISTRIBUTION=NO`, `SKIP_INSTALL=YES`, and no resolved `SWIFT_VERSION`. The target-level `$(RECOMMENDED_*_DEPLOYMENT_TARGET)` settings override the project-level macOS 27.0 value. These are **settings observations**, not produced or tested slices. A first sandboxed settings read emitted simulator-service warnings; the table was re-read successfully with normal Xcode access. No conclusion about simulator health follows from the sandbox warning.

Folio's shared [Suite configuration](https://github.com/Folio-Suite/Folio/blob/135b69515aedb17ea10db87f970257528f7e8ed9/Config/Suite.xcconfig) specifies macOS 26.5. Its inspected FolioKit/Write projects are Objective-C and declare no Swift package references. KitchenMemory's [project](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/KitchenMemory.xcodeproj/project.pbxproj) uses Swift 6 language mode, approachable concurrency, MainActor default isolation on application configurations, and macOS/iOS 27.0 deployment settings. Consumer deployment settings do not automatically define UndoKit's promised support floor.

Collections/Algorithms already matter to KitchenMemory, but current use is not evidence that every container must be stored as history payload:

- [CausalGraph](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/KitchenKit/Domain/CausalGraph.swift) uses `OrderedDictionary`, `OrderedSet`, and `Deque` for traversal.
- [OrganizationEvidence](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/KitchenKit/Domain/OrganizationEvidence.swift) uses a transient `Heap<Int>` to order ready receipts.
- [IdentityCollection](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/KitchenKit/Domain/IdentityCollection.swift) uses Algorithms uniqueness and an ordered dictionary internally while returning arrays.
- [CookingSessionOutbox](https://github.com/ctwelve/KitchenMemory/blob/23353f56968774cae0f7882f602dd2491e2737a5/KitchenMemory/Features/CookingSession/CookingSessionOutbox.swift) holds a `Deque` of pending commands.

## Typed data support and its boundaries

### Containers are not all alike

The following is a source inspection of Collections 1.7.0, also applicable to the unchanged declarations in 1.7.1. `Encodable` and `Decodable` conditions apply independently; a bidirectional history codec needs both or a different explicit codec.

| Type | Coding support and relevant semantics | Primary implementation |
| --- | --- | --- |
| `Deque<Element>` | Conditional coding when elements conform; stores logical element order, rebuilding the deque on decode. | [Deque coding](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/DequeModule/Deque/Deque%2BCodable.swift) |
| `OrderedSet<Element>` | `Element` is already `Hashable`; conditional coding preserves order and rejects duplicate decoded elements. | [OrderedSet coding](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/OrderedCollections/OrderedSet/OrderedSet%2BCodable.swift) |
| `OrderedDictionary<Key, Value>` | Hashable keys; conditional coding for both keys and values. Uses an unkeyed alternating key/value representation to preserve order, including String keys; duplicate keys or missing paired values fail decoding. | [OrderedDictionary coding](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/OrderedCollections/OrderedDictionary/OrderedDictionary%2BCodable.swift) |
| `TreeSet<Element>` | Hashable elements; conditional coding; duplicate decoded elements fail. This is not an ordered collection. | [TreeSet coding](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeSet/TreeSet%2BCodable.swift) |
| `TreeDictionary<Key, Value>` | Conditional coding; String/Int and supported `CodingKeyRepresentable` keys use keyed encoding, other keys use pairs. Decoding inserts values into a new tree. | [TreeDictionary coding](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeDictionary/TreeDictionary%2BCodable.swift) |
| `Heap<Element>` | Requires `Comparable`; no `Codable` conformance found in `Sources/HeapModule`. It is neither `Sequence` nor `Collection`; a custom codec must define which logical values and ordering semantics it preserves. | [Heap declaration and operations](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HeapModule/Heap.swift) |
| `UniqueArray`, `RigidArray`, `UniqueDeque`, `RigidDeque` | Noncopyable ownership-aware containers; no coding conformances found in their source modules. A blanket `T: Codable` API does not cover them. Any supported persistence adapter needs an explicit ownership/snapshot contract. | [UniqueArray](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/BasicContainers/UniqueArray/UniqueArray.swift), [RigidArray](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/BasicContainers/RigidArray/RigidArray.swift), [UniqueDeque](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/DequeModule/UniqueDeque/UniqueDeque.swift), [RigidDeque](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/DequeModule/RigidDeque/RigidDeque.swift) |

Collections' “persistent” tree terminology means shared in-memory structure across values. Its coding routines serialize entries and reconstruct trees; they do not encode cross-snapshot node sharing. **Inference:** serializing many `TreeDictionary` snapshots independently will not automatically give Folio a disk-efficient branching history. That requires a separate history/storage design. [HashTreeCollections description](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/README.md#hashtreecollections-module), [tree encoding/decoding](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeDictionary/TreeDictionary%2BCodable.swift).

### Algorithms is a different dependency decision

Algorithms supplies operations and result/view types for sequences and collections, not a persistence format. Its `UniquedSequence` retains a base sequence and a projection closure; it does not gain automatic durable semantics because it came from an Apple package. A host can still work naturally with algorithm results, while a codec persists a defined snapshot or domain representation. Neither Collections nor Algorithms should be required solely to accept all `Codable` payloads. Internal use is justified by actual algorithms and performance needs. [Algorithms guide/source](https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/Sources/Algorithms/Unique.swift), [package purpose](https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/README.md).

### Encoding does not remove schema and isolation decisions

Apple's `Codable` guidance supports synthesized coding for suitable constituent properties and custom coding when representations differ. This can keep a client's typed model intact at call sites. It does not promise durable interpretation of arbitrary runtime objects. Closures, live framework objects, file handles, and identities referring to mutable external resources still need an explicit host-defined representation or must be excluded. This last sentence is a design requirement, not a claim that every such object is categorically impossible to encode. [Apple custom coding guidance](https://developer.apple.com/documentation/foundation/encoding-and-decoding-custom-types).

For an Objective-C codec, `NSSecureCoding` is a possible convenience, with allowed-class decoding throughout the object graph. It addresses object substitution during unarchiving; it is neither semantic validation nor automatic application schema migration. A byte-oriented host codec is another option and need not require all payloads to be Foundation archives. [NSSecureCoding](https://developer.apple.com/documentation/foundation/nssecurecoding).

The following questions remain design work: stable operation/payload identifiers; payload version independent of framework/Core Data model version; decoder registration after relaunch; unknown versions; backward/forward migration; external-resource lifetime; and whether encodings must be deterministic. A concrete generic decoder still needs the expected type, and a runtime handler registry is not itself persisted executable code. Immutable payload bytes plus a stable codec discriminator are one feasible internal shape, not a selected API. [JSONDecoder typed decode](https://developer.apple.com/documentation/foundation/jsondecoder/decode(_:from:)).

`Codable` and `Sendable` are separate requirements. The installed Swift SDK declares encoding methods independently of sendability; Collections uses conditional `Sendable` conformances, e.g. for a deque only when its elements are Sendable. KitchenMemory's MainActor defaults make isolation an adoption requirement. A generic API must decide whether it encodes and calls host handlers on the host actor, or transfers suitably safe values. Do not infer actor safety from successful serialization. [Deque declaration](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/DequeModule/Deque/Deque.swift), [Swift concurrency isolation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/). Installed declaration inspected: `MacOSX27.0.sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface`, `Encodable`, `Decodable`, and `Codable` at lines 4217–4223.

## Feasible interface shapes, without choosing one

| Shape | Ergonomics and Objective-C access | Distribution consequence to prove |
| --- | --- | --- |
| Objective-C-compatible engine plus generic Swift facade in the same framework | Foundation-based core interface; Swift generic entry points carry concrete host payloads/codecs and provide typed callbacks. Objective-C uses its own first-class protocol/delegate/block surface. | One mixed-language module is feasible. Verify public headers, generated Swift header, cycles, generic callbacks and module-interface import from a binary-only client. |
| Swift engine with explicit Objective-C wrappers | Swift exposes generics/value types; public Objective-C-compatible classes/protocols wrap the common engine. ObjC callers need not write Swift. | Includes Swift runtime dependencies even for ObjC consumers; generated header completeness and deployment/runtime linkage require proof. |
| Objective-C-compatible binary plus companion Swift source target | Typed source layer can use the host's selected Collections/Algorithms versions and codec specializations. | An Apple-supported binary-plus-source Swift package can provide one installation, but the complete Swift surface is no longer delivered solely inside the XCFramework. This is a delivery tradeoff requiring maintainer agreement. |
| Public APIs naming Collections types | Can be natural for operations whose meaning actually includes such a collection type. | Clients must receive compatible package modules and binaries; independently usable ObjC wrappers remain necessary. Support for custom payloads alone does not justify this extra contract. |

These are design inferences. Swift can expose representable classes, protocols, integer-backed enums and methods to Objective-C; arbitrary Swift structs, associated-value enums and generic APIs do not thereby become Objective-C interfaces. Apple documents generated `ProductModuleName-Swift.h` headers and requires public/open declarations in framework headers. Mixed-framework internal imports must avoid generated-header cycles using forward declarations. [Swift `objc` attribute](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/#objc), [Apple generated-header guidance](https://developer.apple.com/documentation/swift/importing-swift-into-objective-c), [binary-plus-source packages](https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages).

## Binary compatibility and dependency delivery

Swift ABI stability, module stability, library evolution, and persisted-payload compatibility are different concerns. For a separately distributed Swift framework, Apple directs enabling `BUILD_LIBRARY_FOR_DISTRIBUTION`, which emits a textual module interface and enables library evolution. Publishing `@frozen` layouts or `@inlinable` implementation details creates additional compatibility commitments. None of these mechanisms migrates stored host payloads. They also do not justify an “any compiler, any dependency version” support promise; the supported compiler range and concrete interfaces must be tested. [Swift library evolution](https://www.swift.org/blog/library-evolution/), [compiler compatibility model](https://github.com/swiftlang/swift/blob/main/docs/LibraryEvolution.rst).

Collections 1.7.x documents Swift **6.2.4 / Xcode 26.3** as its build minimum, with certain features requiring newer facilities. Its normal public API is source-stable under the documented rules. Traits enabling unstable containers/sorted collections, `_RopeModule`, and the upstream Xcode/CMake configurations are outside that promise. This is not a general third-party ABI guarantee. Algorithms' release manifest uses Swift tools 5.7 and depends on Numerics' `RealModule`; its source-stability policy permits raising the toolchain requirement in a minor release. [Collections 1.7.1 policy](https://github.com/apple/swift-collections/blob/98ef3c98609a1e31b7e157b5b619579001a789d6/README.md#source-stability), [Algorithms 1.2.1 manifest](https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/Package.swift), [Algorithms policy](https://github.com/apple/swift-algorithms/blob/87e50f483c54e6efd60e885f7f5aa946cee68023/README.md#source-stability).

Both package manifests declare library products without an explicit static/dynamic type. Do not treat adding a package product in Xcode as proof that a complete dependency closure has been packaged into UndoKit. [Collections manifest](https://github.com/apple/swift-collections/blob/98ef3c98609a1e31b7e157b5b619579001a789d6/Package.swift), [Algorithms current manifest](https://github.com/apple/swift-algorithms/blob/5b7143f8e291dee0e14c118fd0212487f0b37af5/Package.swift).

Dependency placement has three materially different consequences:

1. **Host-only use:** Generic payload/codec APIs can avoid importing Collections into UndoKit at all. The host supplies conformances and executable handler code. This minimizes coupling without changing the host's useful payload type.
2. **Private implementation use:** `internal import` or narrower access can hide a dependency's module interface from ordinary transitive clients when Swift's resilience and access conditions permit it. Its executable code still needs delivery. This is not symbol renaming or automatic protection against duplicate package copies.
3. **Public dependency use:** Public or `@usableFromInline` imports require client module loading. A binary built against one non-resilient package version cannot be assumed compatible with another source-compatible version. The release must define compatible dependency artifacts or a source-built arrangement and test it.

The visibility rules, including exceptions for non-resilient and `@testable` clients, are specified by [SE-0409](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md#transitive-dependency-loading). The compatibility consequences above are inferences from those rules and the packages' source-only promises. Swift now documents `@_implementationOnly` as deprecated in favor of access-level imports; it is not an appropriate unexamined packaging workaround. [Compiler diagnostic guidance](https://github.com/swiftlang/swift/blob/main/userdocs/diagnostics/implementation-only-deprecated.md).

If package object code is statically absorbed into UndoKit while KitchenMemory also links Collections/Algorithms, duplicate definitions, conformance metadata, and symbol visibility need an explicit linking experiment. If packages are delivered dynamically, the host must embed the dependent frameworks appropriately. An XCFramework is a platform-variant artifact, not a dependency resolver. Do not assume nested umbrella frameworks are a portable solution: Apple's embedding guidance excludes umbrella frameworks on iOS-family platforms. The same old technical note contains obsolete static-framework advice; use current static-framework documentation for that question. [Embedding guidance](https://developer.apple.com/library/archive/technotes/tn2435/_index.html), [current XCFramework guidance](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle).

## Packaging and Core Data resources

The intended archive matrix follows the five declared variants above, with the actual architectures discovered from the release archives. Apple's instructions require a framework-only scheme with dependencies, `SKIP_INSTALL=NO`, distribution settings, and separate platform archives before `-create-xcframework`. iPadOS shares the iOS variant; simulator and device binaries are separate even when both are arm64. Preserve appropriate headers and Swift module interfaces, and define whether signed artifacts, symbols and documentation accompany releases. [Apple XCFramework creation](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle).

A **static framework with resources is supported in Xcode 15 and later**. Xcode links its archive into the client and omits that main binary from the embedded resource-bearing framework. Thus a Core Data model does not alone force dynamic linkage. This differs from a bare `.a`, which is not itself a resource bundle. Static versus dynamic remains a decision; neither has been packaged or loaded here. [Apple static-framework documentation](https://developer.apple.com/documentation/xcode/creating-a-static-framework).

A compiled model can be loaded using a model URL through `NSManagedObjectModel(contentsOf:)`. UndoKit must deliberately locate its own resource bundle/model rather than assume the host's main bundle contains it. Inference: static linkage may make a class-based bundle lookup resolve differently from dynamic linkage, so the actual installed resource path needs a runtime probe for the chosen package arrangement. Model version resources must ship with every relevant variant; history database location remains host-selected and is separate from the framework's model resource. [Model URL initializer](https://developer.apple.com/documentation/coredata/nsmanagedobjectmodel/init(contentsof:)), [Bundle class lookup](https://developer.apple.com/documentation/foundation/bundle/init(for:)). Detailed store transactions, migration policy and document-package coordination belong to the platform/lifecycle research and later decisions.

## Required proofs before accepting a design

These are proposed disposable experiments, **all unrun**. They should become prototype tickets once the corresponding interface/distribution decision makes their setup precise.

| Question | Smallest useful proof | Evidence boundary |
| --- | --- | --- |
| Can one artifact serve both languages without object-graph decomposition? | Build a candidate mixed framework and two minimal external consumers: Objective-C-only host and Swift host submitting a custom payload containing `OrderedDictionary`, `OrderedSet`, and `Deque`; recover the same concrete types. | Header/module compile proves interoperability; runtime typed decode and handler dispatch are separate observations. |
| Which containers need convenience codecs? | Round-trip concrete ordered/tree payloads, malformed duplicates, unknown versions and a proposed Heap adapter; explicitly accept or exclude noncopyable containers. | Do not equate round-trip equality with stable on-disk schema, graph sharing or semantic correctness. |
| Does actor isolation match KitchenMemory? | Compile representative MainActor/default-isolated host payloads and callbacks in Swift 6 mode; exercise documented callback executor behavior. | A suppressed concurrency diagnostic is not an isolation guarantee. |
| Are dependency modules and symbols complete and unique? | Consume only the delivered artifact(s), remove producer package caches from the consumer search path, and build/run with KitchenMemory's independently present packages. Inspect interfaces and linker/load outputs. Try agreed same/different supported package versions. | One same-toolchain build is not a version compatibility matrix. |
| Does binary distribution survive compiler changes? | Build with the agreed oldest producer compiler; import the textual interfaces and run clients on each supported consumer compiler, with no producer `.swiftmodule` cache dependency. | Define directional compatibility explicitly; do not infer older-compiler support from a newer compiler reading an old interface. |
| Do all declared variants actually ship? | Archive all five variants, inspect XCFramework metadata and binary architectures, then link minimal consumers for each. Run representative devices/simulators including watchOS if it stays in the contract. | Settings and a successful archive are not runtime evidence for every supported OS. |
| Can the packaged Core Data model be found? | In clean dynamic and/or static consumers for the selected arrangement, locate the shipped model, create/open the history store at a caller-provided URL, and exercise an older model fixture. | Resource load and store open do not establish lifecycle durability or package-copy correctness. |

## Decisions left for the maintainer

- Which interface shape best satisfies both idiomatic typed Swift and independent Objective-C use, and whether one convenient Swift package may supplement the XCFramework.
- Whether package types appear in public UndoKit API, stay in implementation, or remain host-owned; which concrete non-Codable payload families need supplied adapters.
- Supported compiler/dependency versions and deployment floors, including whether the scaffold's watchOS support is a first-release promise.
- Codec identity/versioning, migration and unsupported-payload behavior; actor/ownership rules; resource-bundle discovery.
- Static/dynamic linkage, dependency closure and symbols, archive/signing/documentation delivery, and the compatibility matrix that must pass.

No public API, schema, dependency addition, platform change, or final packaging topology is selected by this research.
