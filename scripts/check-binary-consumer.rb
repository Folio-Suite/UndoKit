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

    def run(xcframework, run_id, platforms, installations, device, export_options, mixed_runtime)
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
      simulator = platforms.include?("ios-simulator") ? prepare_simulator!(device) : nil
      begin
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          platforms.each do |platform|
            selected_installations = platform == "ios-simulator" ? ["embedded"] : installations
            build_consumer!(evidence_root, build_root, xcframework, mac_framework, toolchain,
                            producer_identity, platform, selected_installations, simulator, run_id, export_options, mixed_runtime)
          end
        end
      ensure
        cleanup_simulator!(simulator) if simulator
      end
    end

    def prepare_simulator!(udid)
      raise Assembly::VerificationError, "--device is required when --platform includes ios-simulator" if udid.to_s.empty?
      devices = JSON.parse(Assembly.capture!("xcrun", "simctl", "list", "devices", "available", "--json")).fetch("devices")
      runtimes = JSON.parse(Assembly.capture!("xcrun", "simctl", "list", "runtimes", "--json")).fetch("runtimes")
      runtime_id, runtime_devices = devices.find { |_id, entries| entries.any? { |entry| entry["udid"] == udid } }
      target = runtime_devices&.find { |entry| entry["udid"] == udid }
      runtime = runtimes.find { |entry| entry["identifier"] == runtime_id && entry["isAvailable"] }
      unless target && target["isAvailable"] && runtime && runtime_id.start_with?("com.apple.CoreSimulator.SimRuntime.iOS-")
        raise Assembly::VerificationError, "requested simulator is not an available iOS device: #{udid}"
      end
      booted = devices.values.flatten.select { |entry| entry["state"] == "Booted" }
      other = booted.find { |entry| entry["udid"] != udid }
      raise Assembly::VerificationError, "another simulator is booted: #{other['udid']}; shut it down before binary validation" if other
      state = {udid: udid, name: target["name"], runtimeIdentifier: runtime_id,
               runtimeVersion: runtime["version"], bundleIDs: [], bootedHere: target["state"] != "Booted"}
      if state[:bootedHere]
        Assembly.capture!("xcrun", "simctl", "boot", udid)
        Assembly.capture!("xcrun", "simctl", "bootstatus", udid, "-b")
      end
      state
    rescue JSON::ParserError, KeyError => error
      raise Assembly::VerificationError, "could not inspect requested iOS simulator: #{error.message}"
    end

    def cleanup_simulator!(simulator)
      simulator.fetch(:bundleIDs).each do |bundle_id|
        system("xcrun", "simctl", "terminate", simulator.fetch(:udid), bundle_id, out: File::NULL, err: File::NULL)
        system("xcrun", "simctl", "uninstall", simulator.fetch(:udid), bundle_id, out: File::NULL, err: File::NULL)
      end
      if simulator.fetch(:bootedHere)
        system("xcrun", "simctl", "shutdown", simulator.fetch(:udid), out: File::NULL, err: File::NULL)
      end
    end

    def build_consumer!(evidence_root, build_root, xcframework, original_framework, toolchain,
                        producer_identity, platform, installations, device, run_id, export_options, mixed_runtime)
      ios = platform == "ios-simulator"
      project_directory = File.join(evidence_root, "ConsumerProject-#{platform}")
      source_directory = File.join(project_directory, "Sources")
      app_sources = File.join(source_directory, "App")
      domain_sources = File.join(source_directory, "Domain")
      FileUtils.mkdir_p(app_sources)
      FileUtils.mkdir_p(domain_sources)
      FileUtils.cp(FIXTURE, File.join(app_sources, "HostFixture.swift"))
      FileUtils.cp(File.join(__dir__, "consumer", "DomainIdentity.swift"), File.join(domain_sources, "DomainIdentity.swift"))
      interface_probe = File.join(project_directory, "UndoKit.xcframework")
      FileUtils.cp_r(xcframework, interface_probe)
      variant_name = ios ? "ios-simulator" : "macos"
      selected_framework = File.join(xcframework, variants_path(xcframework, variant_name), "UndoKit.framework")
      probe_framework = File.join(interface_probe, variants_path(interface_probe, variant_name), "UndoKit.framework")
      compiled_modules = Dir.glob(File.join(probe_framework, "Modules", "UndoKit.swiftmodule", "*.swiftmodule"))
      compiled_modules.each { |path| FileUtils.rm_f(path) }
      if Dir.glob(File.join(probe_framework, "Modules", "UndoKit.swiftmodule", "*.swiftinterface")).empty?
        raise Assembly::VerificationError, "textual Swift interfaces disappeared from the consumer probe"
      end
      unless Digest::SHA256.file(File.join(selected_framework, "UndoKit")).hexdigest ==
             Digest::SHA256.file(File.join(probe_framework, "UndoKit")).hexdigest
        raise Assembly::VerificationError, "consumer probe changed the selected framework executable"
      end
      interface_hashes = Dir.glob(File.join(probe_framework, "Modules", "UndoKit.swiftmodule", "*.swiftinterface")).to_h do |path|
        [File.basename(path), Digest::SHA256.file(path).hexdigest]
      end
      framework = probe_framework
      project = File.join(project_directory, "Consumer.xcodeproj")
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "project.pbxproj"), project_text(interface_probe, platform, run_id))
      write_scheme(project)
      log = File.join(project_directory, "binary-consumer-build.log")
      architecture = ios ? "arm64" : `uname -m`.strip
      unless %w[arm64 x86_64].include?(architecture)
        raise Assembly::VerificationError, "unsupported consumer host architecture: #{architecture}"
      end
      destination = ios ? "id=#{device.fetch(:udid)}" : "generic/platform=macOS"
      command = ["xcodebuild", "-project", project, "-scheme", "Consumer", "-configuration", "Release",
                 "-destination", destination, "-derivedDataPath", build_root,
                 "ARCHS=#{ios ? 'arm64' : architecture}", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=YES",
                 "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "build"]
      run_command!(command, log)
      export_evidence = nil
      if export_options && !ios
        export_evidence = export_macos!(project, project_directory, build_root, architecture, export_options)
      end
      product_configuration = ios ? "Release-iphonesimulator" : "Release"
      built_app = export_evidence ? export_evidence.fetch("exportedApp") :
        File.join(build_root, "Build", "Products", product_configuration, "Consumer.app")
      embedded_framework = ios ? File.join(built_app, "Frameworks", "UndoKit.framework") :
        File.join(built_app, "Contents", "Frameworks", "UndoKit.framework")
      raise Assembly::VerificationError, "binary consumer app was not produced at #{built_app}" unless File.directory?(built_app)
      raise Assembly::VerificationError, "binary consumer did not embed the selected UndoKit runtime" unless File.file?(File.join(embedded_framework, "UndoKit"))

      source_privacy = File.expand_path("../UndoKit/Resources/PrivacyInfo.xcprivacy", __dir__)
      installations.each do |installation|
      installed_root = File.join(evidence_root, "Installations", platform, installation)
      FileUtils.mkdir_p(installed_root)
      app = File.join(installed_root, "Consumer.app")
      FileUtils.cp_r(built_app, app)
      executable = ios ? File.join(app, "Consumer") : File.join(app, "Contents", "MacOS", "Consumer")
      runtime_root = File.join(installed_root, "SharedFrameworks")
      runtime_environment = {}
      runtime_framework = ios ? File.join(app, "Frameworks", "UndoKit.framework") :
        File.join(app, "Contents", "Frameworks", "UndoKit.framework")
      if installation == "shared-macos" && !ios
        FileUtils.mkdir_p(runtime_root)
        FileUtils.mv(runtime_framework, File.join(runtime_root, "UndoKit.framework"))
        run_command!(["codesign", "--force", "--deep", "--sign", "-", File.join(runtime_root, "UndoKit.framework")],
                     File.join(evidence_root, "shared-framework-sign.log"))
        run_command!(["codesign", "--force", "--deep", "--sign", "-", app],
                     File.join(evidence_root, "shared-consumer-sign.log"))
        runtime_framework = File.join(runtime_root, "UndoKit.framework")
        runtime_environment["DYLD_FRAMEWORK_PATH"] = runtime_root
        resource_root = Assembly.framework_resource_root(runtime_framework)
      end
      verify_runtime_link!(executable, runtime_framework, platform, architecture)
      resource_root = Assembly.framework_resource_root(runtime_framework)
      privacy = File.join(resource_root, "PrivacyInfo.xcprivacy")
      unless Digest::SHA256.file(source_privacy).hexdigest == Digest::SHA256.file(privacy).hexdigest
        raise Assembly::VerificationError, "installed framework privacy manifest differs from its source declaration"
      end
      model = File.join(resource_root, "History.momd")
      unless File.file?(File.join(model, "VersionInfo.plist")) && !Dir.glob(File.join(model, "*.mom")).empty?
        raise Assembly::VerificationError, "installed framework compiled model is incomplete"
      end
      if ios
        bundle_id = "org.foliosuite.undokit.binaryconsumer.#{run_id.gsub(/[^A-Za-z0-9-]/, "-").downcase}"
        device_id = device.fetch(:udid)
        run_command!(["xcrun", "simctl", "install", device_id, app], File.join(installed_root, "simulator-install.log"))
        device.fetch(:bundleIDs) << bundle_id
        container = run_command!(["xcrun", "simctl", "get_app_container", device_id, bundle_id, "data"],
                                 File.join(installed_root, "simulator-container.log")).strip
        host_data = File.join(container, "Library", "Application Support", "UndoKitConsumerEvidence-#{SecureRandom.uuid}")
        run_command!(["xcrun", "simctl", "launch", "--terminate-running-process", device_id, bundle_id],
                     File.join(installed_root, "simulator-launch.log"),
                     {"SIMCTL_CHILD_UNDOkit_CONSUMER_ROOT" => host_data})
        report_path = nil
        60.times do
          candidate = File.join(host_data, "ConsumerReport.json")
          failure = File.join(host_data, "ConsumerFailure.txt")
          raise Assembly::VerificationError, "binary simulator consumer failed: #{File.read(failure)}" if File.file?(failure)
          if File.file?(candidate)
            report_path = candidate
            break
          end
          sleep 1
        end
        raise Assembly::VerificationError, "binary simulator app produced no consumer report" unless report_path
        report = JSON.parse(File.read(report_path))
        FileUtils.cp(report_path, File.join(installed_root, "ConsumerReport.json"))
      else
        host_data = File.join(installed_root, "host-data")
        FileUtils.mkdir_p(host_data)
        run_command!([executable], File.join(installed_root, "binary-consumer-run.log"),
                     runtime_environment.merge("UNDOkit_CONSUMER_ROOT" => host_data))
        report_path = File.join(host_data, "ConsumerReport.json")
        raise Assembly::VerificationError, "binary consumer did not write its history report" unless File.file?(report_path)
        report = JSON.parse(File.read(report_path))
      end
      expected = {"hostValue" => "alpha-beta", "groupMemberCount" => 2, "receiptCount" => 3,
                  "appliedDeliveries" => 3, "appliedMembers" => 6, "reopenedCanUndo" => true,
                  "reopenedCanRedo" => false, "bundledModelLoaded" => true,
                  "sharedUndoKitTypeIdentity" => true}
      expected.each do |key, value|
        raise Assembly::VerificationError, "binary consumer report #{key}=#{report[key].inspect}; expected #{value.inspect}" unless report[key] == value
      end
      unless report["undoKitLoadedImages"].is_a?(Array) && report["undoKitLoadedImages"].length == 1
        raise Assembly::VerificationError, "binary consumer did not prove exactly one loaded UndoKit runtime: #{report["undoKitLoadedImages"].inspect}"
      end
      if installation == "shared-macos" && !report.fetch("undoKitLoadedImages").first.start_with?(runtime_root)
        raise Assembly::VerificationError, "shared-macOS consumer loaded UndoKit outside the host-managed location: #{report["undoKitLoadedImages"].inspect}"
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
        "consumer" => "independent app and domain framework linked to the assembled binary framework",
        "installation" => installation,
        "consumerConfiguration" => "Release",
        "consumerPlatform" => platform,
        "consumerArchitecture" => architecture,
        "consumerSigning" => export_evidence ? "Apple Development local debugging export; not release distribution" : "ad-hoc identity '-' for the local test application",
        "macOSArchiveExport" => export_evidence,
        "mixedRuntimeRejection" => mixed_runtime ? probe_mixed_runtime!(executable, installed_root, runtime_environment, mixed_runtime) : nil,
        "runtimeFrameworkPath" => runtime_framework,
        "selectedFrameworkBinarySHA256" => Digest::SHA256.file(File.join(selected_framework, "UndoKit")).hexdigest,
        "runtimeFrameworkSHA256" => Digest::SHA256.file(File.join(runtime_framework, "UndoKit")).hexdigest,
        "compiledModelTreeSHA256" => Assembly.tree_sha256(model),
        "privacyManifestSHA256" => Digest::SHA256.file(privacy).hexdigest,
        "textualSwiftInterfaceSHA256" => interface_hashes,
        "compiledSwiftModulesRemovedFromConsumerProbe" => compiled_modules.map { |path| File.basename(path) },
        "xcodebuildVersion" => toolchain.fetch(:xcode).lines.map(&:strip),
        "swiftVersion" => toolchain.fetch(:swift).lines.map(&:strip),
        "hostOSVersion" => `sw_vers -productVersion`.strip,
        "runtimeReport" => report,
        "simulator" => ios ? {"udid" => device.fetch(:udid), "name" => device.fetch(:name),
          "runtimeIdentifier" => device.fetch(:runtimeIdentifier), "runtimeVersion" => device.fetch(:runtimeVersion)} : nil,
        "buildLog" => log,
        "runLog" => File.join(installed_root, ios ? "simulator-launch.log" : "binary-consumer-run.log")
      })
      path = File.join(installed_root, "BinaryConsumerEvidence.json")
      File.write(path, JSON.pretty_generate(evidence) + "\n")
      puts "Independent binary consumer passed: #{path}"
      end
    rescue JSON::ParserError => error
      raise Assembly::VerificationError, "invalid binary consumer report: #{error.message}"
    end

    def export_macos!(project, directory, build_root, architecture, options)
      archive = File.join(directory, "Consumer.xcarchive")
      export_root = File.join(directory, "Exported")
      plist = File.join(directory, "ExportOptions.plist")
      json = File.join(directory, "ExportOptions.json")
      File.write(json, JSON.pretty_generate({"method" => "debugging", "destination" => "export",
        "signingStyle" => "manual", "teamID" => options.fetch(:team),
        "signingCertificate" => options.fetch(:identity)}))
      run_command!(["plutil", "-convert", "xml1", "-o", plist, json], File.join(directory, "export-options.log"))
      archive_log = File.join(directory, "archive.log")
      run_command!(["xcodebuild", "-project", project, "-scheme", "Consumer", "-configuration", "Release",
        "-destination", "generic/platform=macOS", "-derivedDataPath", build_root, "-archivePath", archive,
        "ARCHS=#{architecture}", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_STYLE=Manual",
        "CODE_SIGN_IDENTITY=#{options.fetch(:identity)}", "DEVELOPMENT_TEAM=#{options.fetch(:team)}", "archive"], archive_log)
      export_log = File.join(directory, "export.log")
      run_command!(["xcodebuild", "-exportArchive", "-archivePath", archive,
        "-exportOptionsPlist", plist, "-exportPath", export_root], export_log)
      app = File.join(export_root, "Consumer.app")
      raise Assembly::VerificationError, "Xcode export did not produce #{app}" unless File.directory?(app)
      signature = run_command!(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
                               File.join(directory, "export-signature-verify.log"))
      details = run_command!(["codesign", "--display", "--verbose=4", app], File.join(directory, "export-signature.log"))
      unless details.include?("TeamIdentifier=#{options.fetch(:team)}") && details.include?("Authority=Apple Development:")
        raise Assembly::VerificationError, "exported consumer did not retain the requested Apple Development signature"
      end
      {"method" => "debugging", "archivePath" => archive, "exportedApp" => app,
       "exportOptionsPlist" => plist, "archiveLog" => archive_log, "exportLog" => export_log,
       "signature" => details, "signatureVerification" => signature}
    end

    def probe_mixed_runtime!(executable, installed_root, runtime_environment, alternate)
      alternate = File.expand_path(alternate)
      unless File.file?(alternate) && File.basename(alternate) == "libUndoKit.dylib"
        raise Assembly::VerificationError, "mixed-runtime probe requires an existing source-built libUndoKit.dylib"
      end
      directory = File.join(installed_root, "MixedRuntimeProbe")
      FileUtils.mkdir_p(directory)
      host_data = File.join(directory, "host-data")
      environment = runtime_environment.merge("DYLD_INSERT_LIBRARIES" => alternate,
                                              "UNDOkit_CONSUMER_ROOT" => host_data)
      output, status = Open3.capture2e(environment, executable)
      log = File.join(directory, "launch.log")
      File.write(log, "$ DYLD_INSERT_LIBRARIES=#{alternate} #{executable}\n#{output}")
      failure_path = File.join(host_data, "ConsumerFailure.txt")
      failure = File.file?(failure_path) ? File.read(failure_path) : ""
      expected = failure.include?("expected one loaded UndoKit runtime image") ||
                 failure.include?("app and domain framework resolved different UndoKit HistoryStore type identities")
      unless !status.success? && expected
        raise Assembly::VerificationError, "mixed-runtime probe did not reach the precise identity guard (status #{status.exitstatus}, signal #{status.termsig}); see #{log}"
      end
      if File.file?(File.join(host_data, "History.sqlite")) || File.file?(File.join(host_data, "HostState.json"))
        raise Assembly::VerificationError, "mixed-runtime graph mutated host/history stores before rejection"
      end
      {"alternateRuntimePath" => alternate, "alternateRuntimeSHA256" => Digest::SHA256.file(alternate).hexdigest,
       "alternateRuntimeInstallName" => Assembly.capture!("xcrun", "otool", "-D", alternate),
       "consumerExecutableSHA256" => Digest::SHA256.file(executable).hexdigest,
       "failure" => failure, "exitStatus" => status.exitstatus, "launchLog" => log,
       "hostAndHistoryStoresCreated" => false}
    end

    def verify_runtime_link!(executable, framework, platform, architecture)
      dependencies = Assembly.capture!("xcrun", "otool", "-L", executable)
      unless dependencies.lines.any? { |line| line.include?("UndoKit.framework/") }
        raise Assembly::VerificationError, "consumer executable does not link the embedded UndoKit framework"
      end
      load_commands = Assembly.capture!("xcrun", "otool", "-l", executable)
      expected_rpath = platform == "ios-simulator" ? "@executable_path/Frameworks" : "@executable_path/../Frameworks"
      unless load_commands.include?(expected_rpath)
        raise Assembly::VerificationError, "consumer executable has no Frameworks run path #{expected_rpath}"
      end
      architectures = Assembly.parse_architectures(Assembly.capture!("xcrun", "lipo", "-archs", executable))
      Assembly.verify_architectures!(architectures, [architecture], "binary consumer executable")
      raise Assembly::VerificationError, "embedded UndoKit runtime path is missing" unless File.file?(File.join(framework, "UndoKit"))
      runtime_architectures = Assembly.parse_architectures(Assembly.capture!("xcrun", "lipo", "-archs", File.join(framework, "UndoKit")))
      unless runtime_architectures.include?(architecture)
        raise Assembly::VerificationError, "installed UndoKit runtime architectures are #{runtime_architectures.join(', ')}; expected support for #{architecture}"
      end
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

    def project_text(xcframework, platform, run_id)
      xcframework_path = pbx_escape(xcframework)
      framework_search = pbx_escape(File.dirname(xcframework))
      ios = platform == "ios-simulator"
      sdk = ios ? "iphonesimulator" : "macosx"
      rpath = ios ? "@executable_path/Frameworks" : "@executable_path/../Frameworks"
      deployment_settings = ios ? "IPHONEOS_DEPLOYMENT_TARGET = 17.0; TARGETED_DEVICE_FAMILY = \"1,2\";" : "MACOSX_DEPLOYMENT_TARGET = 14.0;"
      bundle_id = "org.foliosuite.undokit.binaryconsumer.#{run_id.gsub(/[^A-Za-z0-9-]/, "-").downcase}"
      <<~PBX
        // !$*UTF8*$!
        {
        	archiveVersion = 1;
        	classes = { };
        	objectVersion = 110;
        	objects = {
        A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = A00000000000000000000051; compatibilityVersion = "Xcode 16.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = A00000000000000000000002; productRefGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000010, A00000000000000000000014, ); };
        A00000000000000000000002 = {isa = PBXGroup; children = (A00000000000000000000004, A00000000000000000000003, A00000000000000000000011, ); sourceTree = "<group>"; };
        A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000013, A00000000000000000000015, ); name = Products; sourceTree = "<group>"; };
        A00000000000000000000004 = {isa = PBXGroup; children = (A00000000000000000000005, A00000000000000000000006, ); sourceTree = "<group>"; };
        A00000000000000000000005 = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources/App; sourceTree = "<group>"; };
        A00000000000000000000006 = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources/Domain; sourceTree = "<group>"; };
        A00000000000000000000010 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000052; buildPhases = (A00000000000000000000040, A00000000000000000000041, A00000000000000000000042, A00000000000000000000043, ); buildRules = (); dependencies = (A00000000000000000000035, ); fileSystemSynchronizedGroups = (A00000000000000000000005, ); name = Consumer; productName = Consumer; productReference = A00000000000000000000013; productType = "com.apple.product-type.application"; };
        A00000000000000000000011 = {isa = PBXFileReference; explicitFileType = wrapper.xcframework; path = "#{xcframework_path}"; sourceTree = "<absolute>"; };
        A00000000000000000000013 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Consumer.app; sourceTree = BUILT_PRODUCTS_DIR; };
        A00000000000000000000021 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; };
        A00000000000000000000022 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
        A00000000000000000000040 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000041 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000021, A00000000000000000000026, ); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000042 = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = (A00000000000000000000022, A00000000000000000000025, ); name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000043 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000014 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000057; buildPhases = (A00000000000000000000044, A00000000000000000000045, ); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (A00000000000000000000006, ); name = ConsumerDomain; productName = ConsumerDomain; productReference = A00000000000000000000015; productType = "com.apple.product-type.framework"; };
        A00000000000000000000044 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000045 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000027, ); runOnlyForDeploymentPostprocessing = 0; };
        A00000000000000000000026 = {isa = PBXBuildFile; fileRef = A00000000000000000000015; };
        A00000000000000000000027 = {isa = PBXBuildFile; fileRef = A00000000000000000000011; };
        A00000000000000000000025 = {isa = PBXBuildFile; fileRef = A00000000000000000000015; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
        A00000000000000000000015 = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = ConsumerDomain.framework; sourceTree = BUILT_PRODUCTS_DIR; };
        A00000000000000000000035 = {isa = PBXTargetDependency; target = A00000000000000000000014; targetProxy = A00000000000000000000036; };
        A00000000000000000000036 = {isa = PBXContainerItemProxy; containerPortal = A00000000000000000000001; proxyType = 1; remoteGlobalIDString = A00000000000000000000014; remoteInfo = ConsumerDomain; };
        A00000000000000000000057 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000064, A00000000000000000000065, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000064 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; DEFINES_MODULE = YES; DYLIB_INSTALL_NAME_BASE = "@rpath"; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "#{framework_search}", ); GENERATE_INFOPLIST_FILE = YES; INSTALL_PATH = "@rpath"; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = org.foliosuite.undokit.binaryconsumer.domain; PRODUCT_NAME = ConsumerDomain; SKIP_INSTALL = YES; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Debug; };
        A00000000000000000000065 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; DEFINES_MODULE = YES; DYLIB_INSTALL_NAME_BASE = "@rpath"; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "#{framework_search}", ); GENERATE_INFOPLIST_FILE = YES; INSTALL_PATH = "@rpath"; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = org.foliosuite.undokit.binaryconsumer.domain; PRODUCT_NAME = ConsumerDomain; SKIP_INSTALL = YES; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Release; };
        A00000000000000000000051 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000060, A00000000000000000000061, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000052 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000062, A00000000000000000000063, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        A00000000000000000000060 = {isa = XCBuildConfiguration; buildSettings = {#{deployment_settings} SDKROOT = #{sdk}; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Debug; };
        A00000000000000000000061 = {isa = XCBuildConfiguration; buildSettings = {#{deployment_settings} SDKROOT = #{sdk}; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Release; };
        A00000000000000000000062 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "#{framework_search}", ); GENERATE_INFOPLIST_FILE = YES; #{deployment_settings} LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "#{rpath}", ); PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id}; PRODUCT_NAME = Consumer; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CONSUMER_APP NATIVE_FRAMEWORK"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Debug; };
        A00000000000000000000063 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; CODE_SIGN_STYLE = Manual; FRAMEWORK_SEARCH_PATHS = ("$(inherited)", "#{framework_search}", ); GENERATE_INFOPLIST_FILE = YES; #{deployment_settings} LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "#{rpath}", ); PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id}; PRODUCT_NAME = Consumer; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CONSUMER_APP NATIVE_FRAMEWORK"; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_VERSION = 6.0; }; name = Release; };
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

options = {xcframework: nil, run_id: nil, installation: "embedded", platform: "macos", device: nil, export_macos: false, team: nil, identity: nil, mixed_runtime: nil}
parser = OptionParser.new do |arguments|
  arguments.banner = "Usage: ruby scripts/check-binary-consumer.rb --xcframework PATH [--platform macos|ios-simulator|both] [--installation embedded|shared-macos|both] [--device UDID]"
  arguments.on("--xcframework PATH", "Assembled UndoKit.xcframework to install in an independent app") { |value| options[:xcframework] = value }
  arguments.on("--run-id ID", "Unique evidence-run name") { |value| options[:run_id] = value }
  arguments.on("--platform PLATFORM", %w[macos ios-simulator both], "macos, ios-simulator, or both (default macos)") { |value| options[:platform] = value }
  arguments.on("--installation MODE", %w[embedded shared-macos both], "embedded, shared-macos, or both (default embedded)") { |value| options[:installation] = value }
  arguments.on("--device UDID", "required for ios-simulator; reuse this available iOS simulator") { |value| options[:device] = value }
  arguments.on("--export-macos", "archive and export the macOS fixture for local debugging (requires team and identity)") { options[:export_macos] = true }
  arguments.on("--development-team ID", "local export's Apple Developer team") { |value| options[:team] = value }
  arguments.on("--signing-identity IDENTITY", "local export's installed Apple Development identity or SHA-1") { |value| options[:identity] = value }
  arguments.on("--probe-mixed-runtime PATH", "macOS only: require rejection after loading this source-built libUndoKit.dylib") { |value| options[:mixed_runtime] = value }
  arguments.on("-h", "--help", "Show this help") { puts arguments; exit 0 }
end
parser.parse!
options[:run_id] ||= "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"

begin
  raise UndoKit::XCFrameworkAssembly::VerificationError, "--xcframework is required" unless options[:xcframework]
  unless options[:run_id].match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--run-id must contain only letters, numbers, dot, underscore, and hyphen"
  end
  platform_names = options[:platform] == "both" ? %w[macos ios-simulator] : [options[:platform]]
  if platform_names.include?("ios-simulator") && options[:device].to_s.empty?
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--device is required when --platform includes ios-simulator"
  end
  if options[:installation] == "shared-macos" && options[:platform] == "ios-simulator"
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--installation shared-macos requires --platform macos or both"
  end
  if options[:installation] == "both" && options[:platform] == "ios-simulator"
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--installation both requires --platform macos or both"
  end
  if options[:mixed_runtime] && options[:platform] != "macos"
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--probe-mixed-runtime requires --platform macos"
  end
  if options[:export_macos] && (options[:platform] != "macos" || options[:team].to_s.empty? || options[:identity].to_s.empty?)
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--export-macos requires --platform macos, --development-team and --signing-identity"
  end
  if !options[:export_macos] && (options[:team] || options[:identity])
    raise UndoKit::XCFrameworkAssembly::VerificationError, "--development-team and --signing-identity require --export-macos"
  end
  export_options = options[:export_macos] ? {team: options[:team], identity: options[:identity]} : nil
  installations = options[:installation] == "both" ? %w[embedded shared-macos] : [options[:installation]]
  UndoKit::BinaryConsumer.run(options[:xcframework], options[:run_id], platform_names, installations,
                              options[:device], export_options, options[:mixed_runtime])
rescue UndoKit::XCFrameworkAssembly::VerificationError => error
  warn "Binary consumer check failed: #{error.message}"
  exit 1
end
