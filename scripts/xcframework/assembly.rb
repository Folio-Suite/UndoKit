# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require "digest"
require "find"
require "json"
require "open3"
require "pathname"

module UndoKit
  module XCFrameworkAssembly
    class VerificationError < StandardError; end

    ARCHIVE_TARGETS = [
      {name: "macos", destination: "generic/platform=macOS", sdk: "macosx",
       platform: "macos", platform_variant: nil, architectures: %w[arm64 x86_64], minimum_os: "14.0",
       interfaces: {"arm64" => "arm64-apple-macos.swiftinterface",
                    "x86_64" => "x86_64-apple-macos.swiftinterface"}},
      {name: "ios-device", destination: "generic/platform=iOS", sdk: "iphoneos",
       platform: "ios", platform_variant: nil, architectures: %w[arm64], minimum_os: "17.0",
       interfaces: {"arm64" => "arm64-apple-ios.swiftinterface"}},
      {name: "ios-simulator", destination: "generic/platform=iOS Simulator", sdk: "iphonesimulator",
       platform: "ios", platform_variant: "simulator", architectures: %w[arm64 x86_64], minimum_os: "17.0",
       interfaces: {"arm64" => "arm64-apple-ios-simulator.swiftinterface",
                    "x86_64" => "x86_64-apple-ios-simulator.swiftinterface"}}
    ].freeze

    PLATFORM_NAMES = {"macos" => "MACOS", "ios" => "IOS"}.freeze

    module_function

    def parse_architectures(output)
      output.to_s.split.map(&:strip).reject(&:empty?).uniq.sort
    end

    def verify_architectures!(actual, expected, description)
      actual_set = actual.to_a.map(&:to_s).uniq.sort
      expected_set = expected.to_a.map(&:to_s).uniq.sort
      return actual_set if actual_set == expected_set

      raise VerificationError, "#{description} architectures are #{actual_set.join(', ')}; expected #{expected_set.join(', ')}"
    end

    def parse_uuids(output)
      result = {}
      output.to_s.each_line do |line|
        match = line.match(/UUID:\s*([0-9A-Fa-f-]+)\s+\(([^)]+)\)/)
        next unless match

        architecture = match[2].strip
        raise VerificationError, "duplicate UUID record for #{architecture}" if result.key?(architecture)

        result[architecture] = match[1].upcase
      end
      raise VerificationError, "debug symbol inspection returned no UUID records" if result.empty?

      result
    end

    def verify_uuid_match!(binary_output, symbols_output, description)
      binary_uuids = parse_uuids(binary_output)
      symbol_uuids = parse_uuids(symbols_output)
      return binary_uuids if binary_uuids == symbol_uuids

      raise VerificationError, "#{description} dSYM UUIDs #{symbol_uuids.inspect} do not match binary UUIDs #{binary_uuids.inspect}"
    end

    def tree_sha256(path)
      root = File.expand_path(path)
      raise VerificationError, "artifact is missing: #{root}" unless File.exist?(root)

      records = []
      Find.find(root) do |entry|
        next if entry == root

        relative = entry.delete_prefix(root + File::SEPARATOR)
        stat = File.lstat(entry)
        if stat.symlink?
          records << "L\0#{relative}\0#{File.readlink(entry)}\n"
        elsif stat.file?
          records << "F\0#{relative}\0#{Digest::SHA256.file(entry).hexdigest}\n"
        elsif stat.directory?
          records << "D\0#{relative}\n"
        else
          raise VerificationError, "unsupported filesystem entry in artifact: #{relative}"
        end
      end
      Digest::SHA256.hexdigest(records.sort.join)
    end

    def verify_framework!(framework, symbols, target, runner: method(:capture!))
      framework = File.expand_path(framework)
      symbols = File.expand_path(symbols)
      binary = File.join(framework, "UndoKit")
      symbol_binary = File.join(symbols, "Contents", "Resources", "DWARF", "UndoKit")
      ensure_file!(binary, "framework executable")
      ensure_file!(symbol_binary, "dSYM DWARF executable")

      architectures = parse_architectures(runner.call("xcrun", "lipo", "-archs", binary))
      verify_architectures!(architectures, target.fetch(:architectures), "#{target.fetch(:name)} framework")
      symbol_architectures = parse_architectures(runner.call("xcrun", "lipo", "-archs", symbol_binary))
      verify_architectures!(symbol_architectures, target.fetch(:architectures), "#{target.fetch(:name)} dSYM")
      uuids = verify_uuid_match!(runner.call("xcrun", "dwarfdump", "--uuid", binary),
                                 runner.call("xcrun", "dwarfdump", "--uuid", symbol_binary), target.fetch(:name))

      build_metadata = {}
      target.fetch(:architectures).each do |architecture|
        header = runner.call("xcrun", "otool", "-arch", architecture, "-hv", binary)
        raise VerificationError, "#{target.fetch(:name)} #{architecture} is not a dynamic library" unless header.match?(/\b(?:MH_)?DYLIB\b/)

        build = runner.call("xcrun", "vtool", "-arch", architecture, "-show-build", binary)
        platform = build[/^\s*platform\s+(\S+)/i, 1]&.upcase
        minimum_os = build[/^\s*minos\s+(\S+)/i, 1]
        expected_platform = target.fetch(:platform) == "ios" && target[:platform_variant] == "simulator" ?
          "IOSSIMULATOR" : PLATFORM_NAMES.fetch(target.fetch(:platform))
        unless platform == expected_platform && minimum_os == target.fetch(:minimum_os)
          raise VerificationError, "#{target.fetch(:name)} #{architecture} build metadata is platform=#{platform.inspect}, minOS=#{minimum_os.inspect}; expected #{expected_platform} / #{target.fetch(:minimum_os)}"
        end
        build_metadata[architecture] = {"platform" => platform, "minimumOS" => minimum_os}
      end

      module_directory = File.join(framework, "Modules", "UndoKit.swiftmodule")
      interface_hashes = target.fetch(:interfaces).to_h do |architecture, interface|
        path = File.join(module_directory, interface)
        ensure_file!(path, "#{architecture} textual Swift interface")
        [interface, Digest::SHA256.file(path).hexdigest]
      end
      ensure_file!(File.join(framework, "Modules", "module.modulemap"), "framework module map")

      resources = framework_resource_root(framework)
      model = File.join(resources, "History.momd")
      ensure_file!(File.join(model, "VersionInfo.plist"), "compiled Core Data model version metadata")
      compiled_models = Dir.glob(File.join(model, "*.mom"))
      raise VerificationError, "compiled Core Data model versions are missing from #{model}" if compiled_models.empty?
      privacy = File.join(resources, "PrivacyInfo.xcprivacy")
      ensure_file!(privacy, "framework privacy manifest")
      runner.call("plutil", "-lint", privacy)

      {
        "architectures" => architectures,
        "debugSymbolsArchitectures" => symbol_architectures,
        "debugSymbolUUIDs" => uuids,
        "platformBuildMetadata" => build_metadata,
        "resourceLayout" => resources == framework ? "framework-root" : "Resources",
        "swiftInterfaceSHA256" => interface_hashes,
        "frameworkBinarySHA256" => Digest::SHA256.file(binary).hexdigest,
        "compiledModelTreeSHA256" => tree_sha256(model),
        "privacyManifestSHA256" => Digest::SHA256.file(privacy).hexdigest
      }
    end

    def verify_xcframework!(xcframework, source_privacy_manifest, runner: method(:capture!))
      xcframework = File.expand_path(xcframework)
      info_path = File.join(xcframework, "Info.plist")
      ensure_file!(info_path, "XCFramework metadata")
      info_json = runner.call("plutil", "-convert", "json", "-o", "-", info_path)
      libraries = JSON.parse(info_json).fetch("AvailableLibraries")
      unless libraries.length == ARCHIVE_TARGETS.length
        raise VerificationError, "XCFramework has #{libraries.length} variants; expected #{ARCHIVE_TARGETS.length}"
      end

      source_privacy = Digest::SHA256.file(source_privacy_manifest).hexdigest
      evidence = {}
      ARCHIVE_TARGETS.each do |target|
        candidates = libraries.select do |library|
          library["SupportedPlatform"] == target.fetch(:platform) &&
            library["SupportedPlatformVariant"] == target[:platform_variant] &&
            library["SupportedArchitectures"].to_a.map(&:to_s).sort == target.fetch(:architectures).sort
        end
        unless candidates.length == 1
          raise VerificationError, "XCFramework metadata does not identify exactly one #{target.fetch(:name)} variant"
        end
        library = candidates.first
        identifier = library.fetch("LibraryIdentifier")
        library_directory = File.join(xcframework, identifier)
        framework = File.join(library_directory, library.fetch("LibraryPath"))
        symbols_path = library["DebugSymbolsPath"]
        raise VerificationError, "#{target.fetch(:name)} XCFramework variant has no DebugSymbolsPath" if symbols_path.to_s.empty?
        symbols_directory = File.join(library_directory, symbols_path)
        symbol_bundles = if symbols_directory.end_with?(".dSYM")
          [symbols_directory]
        else
          Dir.glob(File.join(symbols_directory, "**", "UndoKit.framework.dSYM"), File::FNM_DOTMATCH)
        end
        unless symbol_bundles.length == 1 && File.directory?(symbol_bundles.first)
          raise VerificationError, "#{target.fetch(:name)} DebugSymbolsPath must contain exactly one UndoKit.framework.dSYM; found #{symbol_bundles.inspect}"
        end
        symbols = symbol_bundles.first
        variant = verify_framework!(framework, symbols, target, runner: runner)
        privacy = File.join(framework_resource_root(framework), "PrivacyInfo.xcprivacy")
        unless Digest::SHA256.file(privacy).hexdigest == source_privacy
          raise VerificationError, "#{target.fetch(:name)} privacy manifest differs from the source declaration"
        end
        evidence[target.fetch(:name)] = {
          "libraryIdentifier" => identifier,
          "frameworkPath" => framework.delete_prefix(xcframework + File::SEPARATOR),
          "debugSymbolsPath" => symbols_directory.delete_prefix(xcframework + File::SEPARATOR),
          "debugSymbolBundlePath" => symbols.delete_prefix(xcframework + File::SEPARATOR)
        }.merge(variant)
      end
      evidence
    rescue JSON::ParserError, KeyError => error
      raise VerificationError, "invalid XCFramework metadata: #{error.message}"
    end

    def ensure_file!(path, description)
      raise VerificationError, "#{description} is missing at #{path}" unless File.file?(path)
    end

    def framework_resource_root(framework)
      roots = [File.join(framework, "Resources"), framework]
      roots.find do |root|
        File.file?(File.join(root, "History.momd", "VersionInfo.plist")) &&
          File.file?(File.join(root, "PrivacyInfo.xcprivacy"))
      end || raise(VerificationError, "compiled History.momd and PrivacyInfo.xcprivacy are not both embedded in #{framework}")
    end

    def capture!(*command)
      output, status = Open3.capture2e(*command)
      return output if status.success?

      raise VerificationError, "#{command.join(' ')} failed (#{status.exitstatus}): #{output.strip}"
    end
  end
end
