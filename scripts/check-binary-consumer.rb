#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"
require "optparse"
require "open3"
require "securerandom"
require "time"
require_relative "build-support"
require_relative "xcframework/assembly"

module UndoKit
  module BinaryConsumer
    module_function

    Assembly = XCFrameworkAssembly
    FIXTURE = File.expand_path("consumer/HostFixture.swift", __dir__)

    def run(xcframework, run_id)
      xcframework = File.expand_path(xcframework)
      raise Assembly::VerificationError, "XCFramework directory is missing: #{xcframework}" unless File.directory?(xcframework)
      provenance_path = File.join(File.dirname(xcframework), "provenance.json")
      raise Assembly::VerificationError, "candidate provenance is missing: #{provenance_path}" unless File.file?(provenance_path)
      producer = JSON.parse(File.read(provenance_path))
      unless producer["sourceCommit"].to_s.match?(/\A[0-9a-f]{40}\z/) &&
             producer["xcframeworkTreeSHA256"] == Assembly.tree_sha256(xcframework)
        raise Assembly::VerificationError, "candidate provenance does not identify the selected XCFramework bytes"
      end
      producer_identity = {"producerSourceCommit" => producer.fetch("sourceCommit"),
                           "producerProvenanceSHA256" => Digest::SHA256.file(provenance_path).hexdigest,
                           "producerXCFrameworkTreeSHA256" => producer.fetch("xcframeworkTreeSHA256")}
      variants = Assembly.verify_xcframework!(xcframework, File.expand_path("../UndoKit/Resources/PrivacyInfo.xcprivacy", __dir__))
      toolchain = pinned_toolchain!
      mac_framework = File.join(xcframework, variants.fetch("macos").fetch("frameworkPath"))
      shared_root = UndoKitBuild.root
      repo_root = File.expand_path("..", __dir__)
      if shared_root == repo_root || shared_root.start_with?(repo_root + File::SEPARATOR)
        raise Assembly::VerificationError, "shared build root must be outside the checkout: #{shared_root}"
      end
      build_root = UndoKitBuild.directory("XCFramework", "Build")
      evidence_parent = File.join(File.dirname(xcframework), "BinaryConsumerRuns")
      FileUtils.mkdir_p(evidence_parent)
      evidence_root = File.join(evidence_parent, run_id)
      begin
        Dir.mkdir(evidence_root)
      rescue Errno::EEXIST
        raise Assembly::VerificationError, "binary consumer evidence already exists: #{evidence_root}"
      end
      lock_path = File.join(UndoKitBuild.directory("XCFramework"), "Build.lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        build_consumer!(evidence_root, build_root, xcframework, mac_framework, toolchain, producer_identity)
      end
    end

    def build_consumer!(evidence_root, build_root, xcframework, original_framework, toolchain, producer_identity)
      project_directory = File.join(evidence_root, "ConsumerProject")
      source_directory = File.join(project_directory, "Sources")
      FileUtils.mkdir_p(source_directory)
      FileUtils.cp(FIXTURE, File.join(source_directory, "HostFixture.swift"))
      interface_probe = File.join(project_directory, "UndoKit.xcframework")
      FileUtils.cp_r(xcframework, interface_probe)
      probe_framework = File.join(interface_probe, variants_path(interface_probe, "macos"), "UndoKit.framework")
      compiled_modules = Dir.glob(File.join(probe_framework, "Modules", "UndoKit.swiftmodule", "*.swiftmodule"))
      compiled_modules.each { |path| FileUtils.rm_f(path) }
      if Dir.glob(File.join(probe_framework, "Modules", "UndoKit.swiftmodule", "*.swiftinterface")).empty?
        raise Assembly::VerificationError, "textual Swift interfaces disappeared from the consumer probe"
      end
      unless Digest::SHA256.file(File.join(original_framework, "UndoKit")).hexdigest ==
             Digest::SHA256.file(File.join(probe_framework, "UndoKit")).hexdigest
        raise Assembly::VerificationError, "consumer probe changed the selected framework executable"
      end
      interface_hashes = Dir.glob(File.join(probe_framework, "Modules", "UndoKit.swiftmodule", "*.swiftinterface")).to_h do |path|
        [File.basename(path), Digest::SHA256.file(path).hexdigest]
      end
      framework = probe_framework
      project = File.join(project_directory, "Consumer.xcodeproj")
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "project.pbxproj"), project_text(interface_probe))
      write_scheme(project)
      log = File.join(evidence_root, "binary-consumer-build.log")
      architecture = `uname -m`.strip
      unless %w[arm64 x86_64].include?(architecture)
        raise Assembly::VerificationError, "unsupported consumer host architecture: #{architecture}"
      end
      command = ["xcodebuild", "-project", project, "-scheme", "Consumer", "-configuration", "Release",
                 "-destination", "generic/platform=macOS", "-derivedDataPath", build_root,
                 "ARCHS=#{architecture}", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=YES",
                 "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "build"]
      run_command!(command, log)
      app = File.join(build_root, "Build", "Products", "Release", "Consumer.app")
      executable = File.join(app, "Contents", "MacOS", "Consumer")
      embedded_framework = File.join(app, "Contents", "Frameworks", "UndoKit.framework")
      raise Assembly::VerificationError, "binary consumer app was not produced at #{app}" unless File.directory?(app)
      raise Assembly::VerificationError, "binary consumer did not embed the selected UndoKit runtime" unless File.file?(File.join(embedded_framework, "UndoKit"))

      resource_root = Assembly.framework_resource_root(embedded_framework)
      source_privacy = File.expand_path("../UndoKit/Resources/PrivacyInfo.xcprivacy", __dir__)
      privacy = File.join(resource_root, "PrivacyInfo.xcprivacy")
      unless Digest::SHA256.file(source_privacy).hexdigest == Digest::SHA256.file(privacy).hexdigest
        raise Assembly::VerificationError, "installed framework privacy manifest differs from its source declaration"
      end
      model = File.join(resource_root, "History.momd")
      unless File.file?(File.join(model, "VersionInfo.plist")) && !Dir.glob(File.join(model, "*.mom")).empty?
        raise Assembly::VerificationError, "installed framework compiled model is incomplete"
      end
      verify_runtime_link!(executable, embedded_framework)

      host_data = File.join(evidence_root, "host-data")
      FileUtils.mkdir_p(host_data)
      run_command!([executable], File.join(evidence_root, "binary-consumer-run.log"),
                   "UNDOkit_CONSUMER_ROOT" => host_data)
      report_path = File.join(host_data, "ConsumerReport.json")
      raise Assembly::VerificationError, "binary consumer did not write its history report" unless File.file?(report_path)
      report = JSON.parse(File.read(report_path))
      expected = {"hostValue" => "alpha-beta", "groupMemberCount" => 2, "receiptCount" => 3,
                  "appliedDeliveries" => 3, "appliedMembers" => 6, "reopenedCanUndo" => true,
                  "reopenedCanRedo" => false, "bundledModelLoaded" => true}
      expected.each do |key, value|
        raise Assembly::VerificationError, "binary consumer report #{key}=#{report[key].inspect}; expected #{value.inspect}" unless report[key] == value
      end

      unless Assembly.tree_sha256(xcframework) == producer_identity.fetch("producerXCFrameworkTreeSHA256")
        raise Assembly::VerificationError, "candidate bytes changed during consumer validation"
      end
      evidence = producer_identity.merge({
        "schemaVersion" => 1,
        "capturedAtUTC" => Time.now.utc.iso8601,
        "consumerHarnessSourceCommit" => git_output("rev-parse", "HEAD"),
        "consumerHarnessDirtyPaths" => git_output("status", "--porcelain", "--untracked-files=all").lines.map(&:strip),
        "xcframeworkPath" => xcframework,
        "xcframeworkTreeSHA256" => Assembly.tree_sha256(xcframework),
        "consumer" => "independent macOS application linked to the assembled binary framework",
        "consumerConfiguration" => "Release",
        "consumerArchitecture" => architecture,
        "consumerSigning" => "ad-hoc identity '-' for the local test application",
        "runtimeFrameworkPath" => embedded_framework,
        "selectedFrameworkBinarySHA256" => Digest::SHA256.file(File.join(original_framework, "UndoKit")).hexdigest,
        "runtimeFrameworkSHA256" => Digest::SHA256.file(File.join(embedded_framework, "UndoKit")).hexdigest,
        "compiledModelTreeSHA256" => Assembly.tree_sha256(model),
        "privacyManifestSHA256" => Digest::SHA256.file(privacy).hexdigest,
        "textualSwiftInterfaceSHA256" => interface_hashes,
        "compiledSwiftModulesRemovedFromConsumerProbe" => compiled_modules.map { |path| File.basename(path) },
        "xcodebuildVersion" => toolchain.fetch(:xcode).lines.map(&:strip),
        "swiftVersion" => toolchain.fetch(:swift).lines.map(&:strip),
        "hostOSVersion" => `sw_vers -productVersion`.strip,
        "runtimeReport" => report,
        "buildLog" => log,
        "runLog" => File.join(evidence_root, "binary-consumer-run.log")
      })
      path = File.join(evidence_root, "BinaryConsumerEvidence.json")
      File.write(path, JSON.pretty_generate(evidence) + "\n")
      puts "Independent binary consumer passed: #{path}"
    rescue JSON::ParserError => error
      raise Assembly::VerificationError, "invalid binary consumer report: #{error.message}"
    end

    def verify_runtime_link!(executable, framework)
      dependencies = Assembly.capture!("xcrun", "otool", "-L", executable)
      unless dependencies.lines.any? { |line| line.include?("UndoKit.framework/") }
        raise Assembly::VerificationError, "consumer executable does not link the embedded UndoKit framework"
      end
      load_commands = Assembly.capture!("xcrun", "otool", "-l", executable)
      unless load_commands.include?("@executable_path/../Frameworks")
        raise Assembly::VerificationError, "consumer executable has no Frameworks run path"
      end
      architectures = Assembly.parse_architectures(Assembly.capture!("xcrun", "lipo", "-archs", executable))
      expected = `uname -m`.strip
      Assembly.verify_architectures!(architectures, [expected], "binary consumer executable")
      raise Assembly::VerificationError, "embedded UndoKit runtime path is missing" unless File.file?(File.join(framework, "UndoKit"))
    end

    def pinned_toolchain!
      xcode = Assembly.capture!("xcodebuild", "-version")
      swift = Assembly.capture!("xcrun", "swift", "--version")
      unless xcode.match?(/\AXcode 27\.0\nBuild version 27A266a\s*\z/)
        raise Assembly::VerificationError, "binary consumer requires Xcode 27.0 (27A266a); found:\n#{xcode}"
      end
      unless swift.match?(/Apple Swift version 6\.4 \(swiftlang-6\.4\.0\.34\.1 clang-2100\.3\.34\.1\)/)
        raise Assembly::VerificationError, "binary consumer requires Apple Swift 6.4; found:\n#{swift}"
      end
      {xcode: xcode, swift: swift}
    end

    def project_text(xcframework)
      xcframework_path = pbx_escape(xcframework)
      framework_search = pbx_escape(File.dirname(xcframework))
      <<~PBX
        // !$*UTF8*$!
        {
        	archiveVersion = 1;
        	classes = { };
        	objectVersion = 110;
        	objects = {
        A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = A00000000000000000000051; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A00000000000000000000002; productRefGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000010, ); };
        A00000000000000000000002 = {isa = PBXGroup; children = (A00000000000000000000004, A00000000000000000000003, A00000000000000000000011, ); sourceTree = "<group>"; };
        A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000013, ); name = Products; sourceTree = "<group>"; };
        A00000000000000000000004 = {isa = PBXGroup; children = (A00000000000000000000005, ); sourceTree = "<group>"; };
        A00000000000000000000005 = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources; sourceTree = "<group>"; };
        A00000000000000000000010 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000052; buildPhases = (A00000000000000000000040, A00000000000000000000041, A00000000000000000000042, A00000000000000000000043, ); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (A00000000000000000000005, ); name = Consumer; productName = Consumer; productReference = A00000000000000000000013; productType = "com.apple.product-type.application"; };
        A00000000000000000000011 = {isa = PBXFileReference; explicitFileType = wrapper.xcframework; path = "#{xcframework_path}"; sourceTree = "<absolute>"; };
        A00000000000000000000013 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Consumer.app; sourceTree = BUILT_PRODUCTS_DIR; };
        A00000000000000000000021 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; };
        A00000000000000000000022 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
        A00000000000000000000040 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000041 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000021, ); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000042 = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = (A00000000000000000000022, ); name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000043 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000051 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000060, A00000000000000000000061, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000052 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000062, A00000000000000000000063, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000060 = {isa = XCBuildConfiguration; buildSettings = {MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Debug; };
        A00000000000000000000061 = {isa = XCBuildConfiguration; buildSettings = {MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Release; };
        A00000000000000000000062 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "#{framework_search}", ); GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks", ); MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = org.foliosuite.undokit.binaryconsumer; PRODUCT_NAME = Consumer; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CONSUMER_APP NATIVE_FRAMEWORK"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Debug; };
        A00000000000000000000063 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "#{framework_search}", ); GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/../Frameworks", ); MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = org.foliosuite.undokit.binaryconsumer; PRODUCT_NAME = Consumer; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CONSUMER_APP NATIVE_FRAMEWORK"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Release; };
        };
        rootObject = A00000000000000000000001;
        }
      PBX
    end

    def write_scheme(project)
      scheme_directory = File.join(project, "xcshareddata", "xcschemes")
      FileUtils.mkdir_p(scheme_directory)
      scheme = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="2700" version="1.7">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries>
              <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000010" BuildableName="Consumer.app" BlueprintName="Consumer" ReferencedContainer="container:Consumer.xcodeproj"/>
              </BuildActionEntry>
            </BuildActionEntries>
          </BuildAction>
          <TestAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"/>
          <LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"/>
          <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/>
          <AnalyzeAction buildConfiguration="Release"/>
          <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="NO"/>
        </Scheme>
      XML
      File.write(File.join(scheme_directory, "Consumer.xcscheme"), scheme)
    end

    def variants_path(xcframework, name)
      info = Assembly.capture!("plutil", "-convert", "json", "-o", "-", File.join(xcframework, "Info.plist"))
      target = Assembly::ARCHIVE_TARGETS.find { |item| item.fetch(:name) == name }
      library = JSON.parse(info).fetch("AvailableLibraries").find do |entry|
        entry["SupportedPlatform"] == target.fetch(:platform) && entry["SupportedPlatformVariant"] == target[:platform_variant]
      end
      raise Assembly::VerificationError, "XCFramework has no #{name} variant" unless library

      library.fetch("LibraryIdentifier")
    rescue JSON::ParserError, KeyError => error
      raise Assembly::VerificationError, "invalid XCFramework metadata while preparing consumer: #{error.message}"
    end

    def pbx_escape(value)
      value.gsub("\\", "\\\\").gsub('"', '\\"')
    end

    def git_output(*arguments)
      output, status = Open3.capture2("git", *arguments, chdir: File.expand_path("..", __dir__))
      raise Assembly::VerificationError, "git #{arguments.join(' ')} failed" unless status.success?

      output.strip
    end

    def run_command!(command, log, environment = {})
      puts "Running: #{command.join(' ')}"
      output, status = Open3.capture2e(environment, *command)
      File.write(log, "$ #{command.join(' ')}\n#{output}")
      return output if status.success?

      warn output
      raise Assembly::VerificationError, "#{command.first} failed (#{status.exitstatus}); full output retained in #{log}"
    end
  end
end

options = {xcframework: nil, run_id: nil}
parser = OptionParser.new do |arguments|
  arguments.banner = "Usage: ruby scripts/check-binary-consumer.rb --xcframework PATH [--run-id ID]"
  arguments.on("--xcframework PATH", "Assembled UndoKit.xcframework to install in an independent app") { |value| options[:xcframework] = value }
  arguments.on("--run-id ID", "Unique evidence-run name") { |value| options[:run_id] = value }
  arguments.on("-h", "--help", "Show this help") { puts arguments; exit 0 }
end
parser.parse!
options[:run_id] ||= "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"

begin
  raise UndoKit::XCFrameworkAssembly::VerificationError, "--xcframework is required" unless options[:xcframework]
  unless options[:run_id].match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--run-id must contain only letters, numbers, dot, underscore, and hyphen"
  end
  UndoKit::BinaryConsumer.run(options[:xcframework], options[:run_id])
rescue UndoKit::XCFrameworkAssembly::VerificationError => error
  warn "Binary consumer check failed: #{error.message}"
  exit 1
end
