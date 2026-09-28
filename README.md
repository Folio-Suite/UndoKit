# UndoKit
A managed persistent undo manager for modern Apple ecosystem apps

## Integration with Folio

UndoKit is an independently buildable framework in the Folio monorepo. Its source,
MIT license, domain vocabulary, research, and unresolved design decisions were
imported from the original repository; see [provenance](UPSTREAM.md) and the
[design index](docs/imported-design/README.md).

The imported implementation is an umbrella-header scaffold. The template tests
do not establish durable-history behavior. Folio's need for history does not
settle the acceptance and recovery questions still open in the design work.

Build the shared `UndoKit` scheme in `UndoKit.xcodeproj`, or use the enclosing
`Folio` workspace scheme. The Folio adaptation supplies an explicit public module
map, macOS 14 deployment, coordinated Suite release identity, and development
signing. UndoKit has no dependency on FolioKit or any application domain Kit.
Future Swift and Objective-C callers remain part of its design contract.

`Project.xcconfig` provides standalone version defaults and optionally inherits
the enclosing Suite's version configuration. The shared scheme can archive the
framework. A separately versioned XCFramework release policy remains to be
settled before publishing a usable external history API.

The original source license and authorship are retained. New integration files
carry the Folio Project's MIT SPDX notices.
