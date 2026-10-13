# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "assembly"

class XCFrameworkAssemblyContractTest < Minitest::Test
  Assembly = UndoKit::XCFrameworkAssembly

  def test_consumer_command_refuses_missing_or_mismatched_producer_provenance
    Dir.mktmpdir("undokit-provenance-") do |temporary|
      bundle = File.join(temporary, "UndoKit.xcframework")
      FileUtils.mkdir_p(bundle)
      command = [RbConfig.ruby, File.expand_path("../check-binary-consumer.rb", __dir__),
                 "--xcframework", bundle]
      output, status = Open3.capture2e(*command)
      refute status.success?
      assert_includes output, "candidate provenance is missing"
      File.write(File.join(temporary, "provenance.json"), JSON.generate(
        "sourceCommit" => "a" * 40, "xcframeworkTreeSHA256" => "wrong-artifact"))
      output, status = Open3.capture2e(*command)
      refute status.success?
      assert_includes output, "does not identify the selected XCFramework bytes"
    end
  end

  def test_archive_matrix_keeps_device_and_simulator_separate
    assert_equal [
      ["macos", "generic/platform=macOS", %w[arm64 x86_64], "14.0"],
      ["ios-device", "generic/platform=iOS", %w[arm64], "17.0"],
      ["ios-simulator", "generic/platform=iOS Simulator", %w[arm64 x86_64], "17.0"]
    ], (Assembly::ARCHIVE_TARGETS.map do |target|
      [target.fetch(:name), target.fetch(:destination), target.fetch(:architectures), target.fetch(:minimum_os)]
    end)
  end

  def test_architecture_inspection_requires_the_exact_variant_set
    assert_equal %w[arm64 x86_64], Assembly.parse_architectures("x86_64 arm64\n")
    with_framework_fixture(Assembly::ARCHIVE_TARGETS.last) do |framework, symbols, target, runner|
      mismatched_runner = lambda do |*command|
        command[1] == "lipo" ? "arm64" : runner.call(*command)
      end
      error = assert_raises(Assembly::VerificationError) do
        Assembly.verify_framework!(framework, symbols, target, runner: mismatched_runner)
      end
      assert_match(/expected arm64, x86_64/, error.message)
    end
  end

  def test_dsym_must_match_binary_uuid_for_each_architecture
    binary = <<~OUTPUT
      UUID: 8A7B6C5D-4E3F-2A10-9988-776655443322 (arm64) /UndoKit
      UUID: AABBCCDD-1122-3344-5566-77889900AABB (x86_64) /UndoKit
    OUTPUT
    symbols = <<~OUTPUT
      UUID: AABBCCDD-1122-3344-5566-77889900AABB (x86_64) /UndoKit.dSYM/Contents/Resources/DWARF/UndoKit
      UUID: 8A7B6C5D-4E3F-2A10-9988-776655443322 (arm64) /UndoKit.dSYM/Contents/Resources/DWARF/UndoKit
    OUTPUT

    assert_equal Assembly.parse_uuids(binary), Assembly.parse_uuids(symbols)
    mismatched_symbols = symbols.sub("8A7B6C5D-4E3F-2A10-9988-776655443322", "00000000-0000-0000-0000-000000000000")
    assert_raises(Assembly::VerificationError) do
      Assembly.verify_uuid_match!(binary, mismatched_symbols, "macOS")
    end
  end

  def test_uuid_parser_rejects_duplicate_architecture_records
    duplicate = <<~OUTPUT
      UUID: 8A7B6C5D-4E3F-2A10-9988-776655443322 (arm64) /UndoKit
      UUID: AABBCCDD-1122-3344-5566-77889900AABB (arm64) /UndoKit
    OUTPUT
    assert_raises(Assembly::VerificationError) { Assembly.parse_uuids(duplicate) }
  end

  def test_framework_verification_reads_resources_interfaces_and_build_floors_from_archives
    Assembly::ARCHIVE_TARGETS.each do |target|
      with_framework_fixture(target) do |framework, symbols, _, runner|
        evidence = Assembly.verify_framework!(framework, symbols, target, runner: runner)
        assert_equal target.fetch(:architectures), evidence.fetch("architectures")
        assert_equal target.fetch(:minimum_os), evidence.fetch("platformBuildMetadata").values.first.fetch("minimumOS")
        assert_equal target.fetch(:interfaces).values.sort, evidence.fetch("swiftInterfaceSHA256").keys.sort
        resource_root = target.fetch(:platform) == "macos" ? File.join(framework, "Resources") : framework
        assert_equal "privacy-v1", File.read(File.join(resource_root, "PrivacyInfo.xcprivacy"))
        refute_empty evidence.fetch("compiledModelTreeSHA256")
      end
    end
  end

  def test_xcframework_metadata_resolves_symbols_inside_each_platform_variant
    Dir.mktmpdir("undokit-xcframework-contract-") do |temporary|
      xcframework = File.join(temporary, "UndoKit.xcframework")
      FileUtils.mkdir_p(xcframework)
      info_path = File.join(xcframework, "Info.plist")
      File.write(info_path, "fixture plist")
      source_privacy = File.join(temporary, "PrivacyInfo.xcprivacy")
      File.write(source_privacy, "privacy-v1")
      libraries = []
      runners = {}

      Assembly::ARCHIVE_TARGETS.each do |target|
        identifier = "fixture-#{target.fetch(:name)}"
        library_directory = File.join(xcframework, identifier)
        framework = File.join(library_directory, "UndoKit.framework")
        symbols = File.join(library_directory, "dSYMs", "UndoKit.framework.dSYM")
        _, _, _, runner = create_framework_fixture(target, framework, symbols)
        runners[target.fetch(:name)] = runner
        libraries << {"LibraryIdentifier" => identifier, "LibraryPath" => "UndoKit.framework",
                      "SupportedPlatform" => target.fetch(:platform),
                      "SupportedPlatformVariant" => target[:platform_variant],
                      "SupportedArchitectures" => target.fetch(:architectures),
                      "DebugSymbolsPath" => "dSYMs"}
      end

      metadata_runner = lambda do |*command|
        if command[0] == "plutil" && command.include?("-convert")
          JSON.generate("AvailableLibraries" => libraries)
        elsif command[0] == "plutil" && command.include?("-lint")
          "OK"
        else
          target = Assembly::ARCHIVE_TARGETS.find do |item|
            command.any? { |argument| argument.to_s.include?("fixture-#{item.fetch(:name)}") }
          end
          raise "fixture target was not identified for #{command.inspect}" unless target
          runners.fetch(target.fetch(:name)).call(*command)
        end
      end

      result = Assembly.verify_xcframework!(xcframework, source_privacy, runner: metadata_runner)
      assert_equal Assembly::ARCHIVE_TARGETS.map { |item| item.fetch(:name) }.sort, result.keys.sort
      result.each_value do |variant|
        assert_includes variant.fetch("debugSymbolsPath"), "/dSYMs"
        assert File.directory?(File.join(xcframework, variant.fetch("debugSymbolBundlePath")))
        framework = File.join(xcframework, variant.fetch("frameworkPath"))
        resources = variant.fetch("resourceLayout") == "framework-root" ? framework : File.join(framework, "Resources")
        assert File.file?(File.join(resources, "History.momd", "VersionInfo.plist"))
      end
    end
  end

  private

  def with_framework_fixture(target)
    Dir.mktmpdir("undokit-framework-contract-") do |temporary|
      framework = File.join(temporary, "UndoKit.framework")
      symbols = File.join(temporary, "UndoKit.framework.dSYM")
      _, _, _, runner = create_framework_fixture(target, framework, symbols)
      yield framework, symbols, target, runner
    end
  end

  def create_framework_fixture(target, framework, symbols)
    binary = File.join(framework, "UndoKit")
    symbol_binary = File.join(symbols, "Contents", "Resources", "DWARF", "UndoKit")
    module_directory = File.join(framework, "Modules", "UndoKit.swiftmodule")
    resource_root = target.fetch(:platform) == "macos" ? File.join(framework, "Resources") : framework
    model_directory = File.join(resource_root, "History.momd")
    FileUtils.mkdir_p(module_directory)
    [binary, symbol_binary, File.join(framework, "Modules", "module.modulemap"),
     File.join(resource_root, "PrivacyInfo.xcprivacy"),
     File.join(model_directory, "VersionInfo.plist"), File.join(model_directory, "HistoryV1.mom")].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, File.basename(path))
    end
    target.fetch(:interfaces).each_value do |interface|
      File.write(File.join(module_directory, interface), "public interface #{interface}")
    end
    File.write(File.join(resource_root, "PrivacyInfo.xcprivacy"), "privacy-v1")

    binary_uuids = target.fetch(:architectures).to_h do |architecture|
      [architecture, architecture == "arm64" ? "8A7B6C5D-4E3F-2A10-9988-776655443322" : "AABBCCDD-1122-3344-5566-77889900AABB"]
    end
    runner = lambda do |*command|
      if command[1] == "lipo"
        target.fetch(:architectures).join(" ")
      elsif command[1] == "dwarfdump"
        is_symbols = command.last.include?(".dSYM/")
        uuids = is_symbols ? binary_uuids.dup : binary_uuids
        uuids.map { |architecture, uuid| "UUID: #{uuid} (#{architecture}) /#{File.basename(command.last)}" }.join("\n")
      elsif command[1] == "otool"
        "Mach header\n  filetype DYLIB\n"
      elsif command[1] == "vtool"
        platform = if target.fetch(:platform) == "macos"
          "MACOS"
        elsif target[:platform_variant] == "simulator"
          "IOSSIMULATOR"
        else
          "IOS"
        end
        "platform #{platform}\nminos #{target.fetch(:minimum_os)}\n"
      elsif command[0] == "plutil"
        "OK"
      else
        raise "unexpected fixture tool invocation: #{command.inspect}"
      end
    end
    [framework, symbols, target, runner]
  end
end
