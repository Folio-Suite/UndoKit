<!--
SPDX-FileCopyrightText: 2026 the Folio Project
SPDX-License-Identifier: MIT
-->

# Swift Collections values in opaque history payloads

Research on 2026-10-11. UndoKit source baseline: `6c8eb91c5d3fdf7d89473a6ce0bf769bbee1f295`.
Upstream serialization inspection pins Swift Collections **1.7.0**, commit
`a66de878e87ef5a3d5d390e0f6d9002aa5541a43`. The upstream main ref observed during
research was `935f696a549abf069a2a1e4c6db2f834f7009cd3`; the matrix below describes
the release source, not an unpinned promise about main. Live tag discovery also
verified 1.7.1 at `98ef3c98609a1e31b7e157b5b619579001a789d6` and the newest
observed tag, 1.7.2 at `3b69cedbaa49957e97c092ae400bb57602ef941f`. No 1.7.2
source or runtime qualification is claimed. This is investigation,
not an accepted architecture decision or a persisted-format compatibility promise.

## Finding

Most established Swift Collections value types already supply Codable
conformances. They can be host payload values, or fields of host payload structs,
through UndoKit's existing generic codecs when their element/key/value types
satisfy the applicable constraints. UndoKit does not need a Collections dependency
merely to accept those values. Its built-in codecs require `Codable &
SendableMetatype`; its custom codec initializer remains the explicit route for a
host-defined representation. [UndoKit codec interface](https://github.com/Folio-Suite/UndoKit/blob/6c8eb91c5d3fdf7d89473a6ce0bf769bbee1f295/UndoKit/Interface/HistoryCodecs.swift).

This fits the accepted boundary: typed host adaptation translates values into the
opaque transaction protocol; semantic meaning and authoritative outcome evidence
remain with the host. [Host adaptation ADR](../adr/0003-host-adaptation-module-ownership.md).

## Verified upstream serialization matrix

All generic Codable conformances below are conditional on the corresponding
components conforming to Encodable/Decodable; Hashable/Comparable requirements
also continue to apply to the collection type itself. Codable source is excluded
from Embedded Swift builds. Representation details are pinned implementation and
API-documentation evidence, not validation of every encoder and element type.

| Type | Upstream Codable support and representation | Durable-history implication |
| --- | --- | --- |
| `Deque<Element>` | Conditional; unkeyed elements in logical iteration order. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/DequeModule/Deque/Deque+Codable.swift) | Host can retain queue order without first writing an Array adapter. Buffer capacity/layout is not the payload. |
| `OrderedSet<Element>` | Conditional; encodes its element array and rejects duplicate decoded elements. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/OrderedCollections/OrderedSet/OrderedSet+Codable.swift) | Preserves order and uniqueness; a historical duplicate is a decode failure, not silent normalization. |
| `OrderedDictionary<Key, Value>` | Conditional; always an unkeyed sequence of alternating keys and values, including String keys. Rejects duplicate keys and an unmatched final key. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/OrderedCollections/OrderedDictionary/OrderedDictionary+Codable.swift) | Preserves explicit order. JSON uses an array, not a JSON object; converting old Dictionary payloads requires an intentional migration. |
| `TreeDictionary<Key, Value>` | Conditional; follows Dictionary encoding: keyed for String, Int and supported CodingKeyRepresentable keys, otherwise alternating unkeyed key/value pairs. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeDictionary/TreeDictionary+Codable.swift) | Logical contents are serialized; internal shared tree nodes are not. The source explicitly describes interoperability with Dictionary's encoding. |
| `TreeSet<Element>` | Conditional; unkeyed elements in iteration order; rejects duplicate decoded elements. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeSet/TreeSet+Codable.swift) | Round-trips membership, without an ordering guarantee or automatic canonical bytes. |
| `BitSet` | Codable; unkeyed UInt64 bitmap words. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/BitCollections/BitSet/BitSet+Codable.swift) | The encoded data is a bitmap, not an array of member indices. Encoder support for the full UInt64 range needs representative tests. |
| `BitArray` | Codable; bit count followed by UInt64 bitmap words; validates count and unused bits. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/BitCollections/BitArray/BitArray+Codable.swift) | It is not encoded as a Bool array. Preserve the representation or provide an explicit host migration. |
| `Heap<Element>` | No Codable conformance found in the release's HeapModule source inventory. Public `unordered` exposes an Array; public sequence initializer constructs a heap. [Source](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HeapModule/Heap.swift) | A host codec can encode elements and rebuild a heap. Heap layout and ordering among equal-priority values must not become implicit history guarantees. |
| `UniqueArray`, `RigidArray`, `UniqueDeque`, `RigidDeque` | No Codable conformance found in their release source inventory; these ownership-aware containers are noncopyable. [BasicContainers source](https://github.com/apple/swift-collections/tree/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/BasicContainers), [Deque source](https://github.com/apple/swift-collections/tree/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/DequeModule) | Not direct drop-ins for the current implicitly Copyable `HistoryCodec<Value>` generic. A copyable host snapshot representation is the modest route; move-only history APIs would be separate design work. |

## Persistence and compatibility cautions

`TreeDictionary` and `TreeSet` are persistent *in-memory* data structures: their
nodes can be shared by successive values. Their Codable implementations iterate
over logical contents and rebuild the collection on decode. Consequently, storing
successive complete snapshots does not preserve that node sharing on disk and
does not automatically produce compact deltas. Hosts may benefit from cheap
in-memory snapshots while retaining their existing full-state/delta policies.
[TreeDictionary design and tradeoffs](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeDictionary/TreeDictionary.swift),
[TreeSet design](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeSet/TreeSet.swift).

Both tree types explicitly disclaim iteration-order guarantees. Their array-shaped
encodings therefore must not be treated as canonical intent. Sorting JSON object
keys cannot sort an unkeyed array or decide the host's semantic ordering. Ordered
collections preserve the order the host supplied, but arbitrary nested values may
still have nondeterministic encodings. Keep canonical Intent Fingerprints separate
from integrity checks of stored bytes. [TreeDictionary ordering](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeDictionary/TreeDictionary.swift),
[TreeSet ordering](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/Sources/HashTreeCollections/TreeSet/TreeSet.swift),
[UndoKit glossary](../../CONTEXT.md).

The upstream contract promises public API source stability with semantic
versioning, and explicitly limits that promise to Swift package builds. It does
not establish that arbitrary host archives remain decodable forever or that
encoding is canonical. Swift Collections 1.7 requires Swift 6.2.4 or newer;
experimental traits and underscored APIs are outside its stable public contract.
Do not create a dependency/toolchain-floor change solely for functionality the
host's current Codable types already provide. [Release README](https://github.com/apple/swift-collections/blob/a66de878e87ef5a3d5d390e0f6d9002aa5541a43/README.md).

`SendableMetatype` concerns whether type/conformance metadata can safely cross
isolation boundaries. It does not mean that an instance is Sendable. Swift's
isolated-conformance rules can restrict generic use of actor-isolated conformances;
validate the actual host payload and compiler settings rather than adding an
unchecked Sendable assertion. The proposal is implemented from Swift 6.2, relevant
to the current Swift 6.4 toolchain; it is not a newly invented Collections-specific
requirement. [SE-0470](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md),
[UndoKit codec constraints](https://github.com/Folio-Suite/UndoKit/blob/6c8eb91c5d3fdf7d89473a6ce0bf769bbee1f295/UndoKit/Interface/HistoryCodecs.swift).

## Consumer and interface implications

KitchenMemory's current resolved Collections version is 1.7.0. Its tracked source
uses ordered dictionaries/sets, deques and a heap, including transient traversal
and receipt-ordering machinery. A container used transiently by a consumer is not
automatically state that needs durable history. No direct Collections imports
were found in Folio's tracked Swift files during this pass; this does not contradict
planned adoption or rule out use elsewhere in its dependency graph. No consumer
code or dependency pin was changed.

A host can already write, for example:

```swift
let codec = HistoryCodec<OrderedDictionary<String, Int>>.binaryPropertyList()
```

The same value can be a registration's Command, accepted-effect, or checkpoint
State type when it represents the host's chosen meaning. The existing typed
registration path stores stable operation/schema and codec identity/configuration;
it does not identify payloads by the Swift collection type name. Payload limits
still apply to encoded values. Codable traverses elements, so large full snapshots
can incur allocation and synchronous encoding cost on the calling actor even
when copying the in-memory collection is cheap. No performance claim follows
from the small probe. [Registration contract](../../UndoKit/Interface/Hosting/HistoryOperation.swift),
[Codec contract](../../UndoKit/Interface/Hosting/HistoryCodecs.swift),
[Payload limits](../../UndoKit/Interface/HistoryTypes.swift).

## Preliminary convenience recommendations

1. Document and qualify the existing direct Codable path, including ordered
   payloads and nested collection fields. Demonstrate actual persistence/reopen
   and Undo/Redo, not only in-memory encode/decode.
2. Offer narrowly justified, generic codec conveniences only when they remove
   actual adapter duplication: a host-controlled representation mapping is more
   general than an overload for every Collections type. Keep representation
   identity, configuration and decoding failures explicit.
3. For a heap or a host-chosen stable archive format, show a host-owned custom
   codec that writes a documented representation. Do not add retroactive Codable
   conformances to upstream types or infer domain ordering from collection layout.
4. Treat collection deltas, automatic inverse operations, retained-object
   discovery, and compressed shared-node persistence as separate proposals. They
   require host policy and stronger correctness/performance evidence than Codable
   convenience alone.

## Local runtime probe

A scratch external consumer compiled against production UndoKit at the baseline
above and Collections **1.7.1**, exact commit
`98ef3c98609a1e31b7e157b5b619579001a789d6`, using Swift 6.4 on macOS 27.0.1
arm64. All **30 round trips passed**: Deque<Int>, OrderedSet<String>,
OrderedDictionary<String, Int>, TreeSet<Int>, TreeDictionary<String, Int>, BitSet,
BitArray, and a compound Snapshot containing the three ordered types, each through
existing JSON, XML property-list and binary property-list HistoryCodec factories.
The six additional round trips cover BitSet indices 63/127 and a 64-bit all-true
BitArray, exercising high UInt64 bits across all three representations.

The compound Snapshot also passed a production HistoryEngine binary checkpoint
create, close, reopen and read exercise. The reopened opaque bytes matched the
original bytes, typed equality held, and explicit ordered iteration matched.
The probe artifacts are local, temporary evidence:
`/private/tmp/undokit-collections-probe/Package.swift`,
`/private/tmp/undokit-collections-probe/Sources/Probe/main.swift`, and
`/private/tmp/undokit-collections-probe.log`. They are not maintained regression
coverage. This probe did not submit an operation or exercise Undo/Redo, process
crashes, a separate-process restart, cross-version decoding, or scale. It supports
the direct codec/checkpoint path for the concrete tested values, not every
possible payload or encoder configuration.

## Evidence boundary

This upstream investigation inspected the pinned source inventory and first-party
Swift evolution documentation. It did not run cross-version archive fixtures,
all possible Foundation representations, move-only API experiments, or consumer
performance benchmarks. Tests of concrete consumer payloads and UndoKit's full
reopen/recovery path are required before claiming supported adoption.
