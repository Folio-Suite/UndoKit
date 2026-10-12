# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require "fileutils"
require "optparse"
require "open3"
require "tmpdir"
require "json"
require "securerandom"
require "digest"
require "time"
require_relative "build-support"

Options = Struct.new(:route, :platform, :configuration, :keep, :device, keyword_init: true)
options = Options.new(route: "package", platform: "macos", configuration: "Debug", keep: false)
OptionParser.new do |parser|
  parser.banner = "Usage: scripts/check-consumer.sh [options]"
  parser.on("--route ROUTE", %w[package native both], "package, native, or both (default package)") { |v| options.route = v }
  parser.on("--platform PLATFORM", %w[macos ios-simulator both], "macos, ios-simulator, or both (default macos)") { |v| options.platform = v }
  parser.on("--configuration CONFIG", %w[Debug Release], "Debug or Release (default Debug)") { |v| options.configuration = v }
  parser.on("--device UDID", "reuse an available iOS simulator; refuse other booted simulators") { |v| options.device = v }
  parser.on("--keep", "retain generated projects, builds, stores, and reports") { options.keep = true }
  parser.on("-h", "--help") { puts parser; exit 0 }
end.parse!
abort "--device requires --platform ios-simulator or both" if options.device && options.platform == "macos"

ROOT = File.expand_path("..", __dir__)
FIXTURE = File.join(__dir__, "consumer", "HostFixture.swift")
route_names = options.route == "both" ? %w[package native] : [options.route]
platform_names = options.platform == "both" ? %w[macos ios-simulator] : [options.platform]
toolchain = `xcodebuild -version 2>&1`.lines.map(&:strip).join("; ")
swift = `swift --version 2>&1`.lines.first.to_s.strip
puts "Consumer evidence setup: #{toolchain}; #{swift}; configuration=#{options.configuration}"
puts "Runner architecture: #{`uname -m`.strip}"

def sha256(path)
  Digest::SHA256.file(path).hexdigest
end

def artifact_hashes(resources, product_root)
  model_dir = File.dirname(resources.fetch("model"))
  model_files = Dir.glob(File.join(model_dir, "*.mom"))
  raise "compiled model version file is missing under #{model_dir}" if model_files.empty?
  privacy = resources.fetch("privacyManifest")
  runtime = Dir.glob(File.join(product_root, "**", "UndoKit.framework", "UndoKit"))
    .find { |path| File.file?(path) }
  runtime ||= Dir.glob(File.join(product_root, "**", "libUndoKit.dylib")).find { |path| File.file?(path) }
  hashes = {"privacyManifestSHA256" => sha256(privacy),
            "compiledModelFiles" => model_files.to_h { |path| [File.basename(path), sha256(path)] }}
  hashes["runtimeBinarySHA256"] = sha256(runtime) if runtime
  hashes
end

def run!(*command, env: {}, label: nil)
  puts "  #{label || command.join(' ')}"
  output, status = Open3.capture2e(env, *command)
  unless status.success?
    # Xcode failures such as plugin validation need not contain "error:".
    # Preserve the complete failed command output in CI, where temporary files
    # disappear with the runner and filtered diagnostics can hide the cause.
    warn output
    log = File.join(Dir.tmpdir, "undokit-consumer-last-failure.log")
    File.write(log, output)
    warn "Full command output: #{log}"
    if command[1, 2] == ["simctl", "launch"]
      simulator_id = command[3] == "--terminate-running-process" ? command[4] : command[3]
      simulator_log = Open3.capture2e("xcrun", "simctl", "spawn", simulator_id, "log", "show", "--last", "5m",
                                      "--style", "compact", "--predicate", "process == 'Consumer'").first
      File.write(File.join($consumer_temporary, "simulator-launch.log"), simulator_log)
    end
    if $consumer_keep
      failed_evidence = File.join(UndoKitBuild.directory("Consumers"), "failed-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
      FileUtils.cp_r($consumer_temporary, failed_evidence)
      warn "Failed consumer artifacts and reports retained: #{failed_evidence}"
    end
    raise "command failed (#{status.exitstatus}): #{command.join(' ')}"
  end
  puts output.lines.last(12).join unless output.empty?
  output
end

def verify_resources!(product_root, route)
  plist_object = ->(path) do
    json, status = Open3.capture2("plutil", "-convert", "json", "-o", "-", path)
    raise "could not parse plist resource #{path}" unless status.success?
    JSON.parse(json)
  end
  source_manifest = plist_object.call(File.join(ROOT, "UndoKit", "Resources", "PrivacyInfo.xcprivacy"))
  model_candidates = Dir.glob(File.join(product_root, "**", "History.momd", "VersionInfo.plist"))
  model = model_candidates.find do |path|
    route == "native" ? path.include?("UndoKit.framework/") : path.include?("UndoKit_UndoKit.bundle/")
  end
  raise "installed compiled History model not found for #{route} under #{product_root}" unless model
  privacy_candidates = Dir.glob(File.join(product_root, "**", "PrivacyInfo.xcprivacy"))
  privacy = privacy_candidates.find do |path|
    route == "native" ? path.include?("UndoKit.framework/") : path.include?("UndoKit_UndoKit.bundle/")
  end
  raise "installed privacy manifest not found for #{route} under #{product_root}" unless privacy
  raise "installed privacy manifest differs from the source declaration: #{privacy}" unless plist_object.call(privacy) == source_manifest
  {"model" => model, "privacyManifest" => privacy}
end

def verify_macho!(app, platform)
  ios = platform == "ios-simulator"
  expected_platform = ios ? "IOSSIMULATOR" : "MACOS"
  expected_rpath = ios ? "@executable_path/Frameworks" : "@executable_path/../Frameworks"
  floor = ios ? [17, 0] : [14, 0]
  app_binary = ios ? File.join(app, "Consumer") : File.join(app, "Contents", "MacOS", "Consumer")
  framework = ios ? File.join(app, "Frameworks", "UndoKit.framework") : File.join(app, "Contents", "Frameworks", "UndoKit.framework")
  framework_binary = File.join(framework, "UndoKit")
  raise "prelaunch check failed: embedded UndoKit.framework runtime missing at #{framework_binary}" unless File.file?(framework_binary)
  raise "prelaunch check failed: consumer executable missing at #{app_binary}" unless File.file?(app_binary)

  rpaths, status = Open3.capture2("otool", "-l", app_binary)
  raise "prelaunch check failed: otool could not inspect #{app_binary}" unless status.success?
  found = rpaths.lines.each_cons(3).any? do |lines|
    lines[0].include?("LC_RPATH") && lines[2].include?("path #{expected_rpath} ")
  end
  raise "prelaunch check failed: #{app_binary} lacks LC_RPATH #{expected_rpath}" unless found

  inspect_build = lambda do |binary, arch|
    output, build_status = Open3.capture2("xcrun", "vtool", "-arch", arch, "-show-build", binary)
    raise "prelaunch check failed: vtool could not inspect #{binary} (#{arch})" unless build_status.success?
    platform_line = output.lines.find { |line| line.match?(/platform\s*:?[ \t]+\S+/i) }
    minos_line = output.lines.find { |line| line.match?(/minos\s*:?[ \t]+\S+/i) }
    actual_platform = platform_line&.match(/platform\s*:?\s*(\S+)/i)&.captures&.first&.upcase&.gsub(/[^A-Z]/, "")
    version = minos_line&.match(/minos\s*:?\s*(\S+)/i)&.captures&.first
    actual_version = version&.scan(/\d+/)&.first(2)&.map(&:to_i)
    unless actual_platform == expected_platform && actual_version == floor
      raise "prelaunch check failed: #{binary} #{arch} build metadata platform=#{actual_platform.inspect} minos=#{version.inspect}; expected #{expected_platform} minos #{floor.join('.')}. vtool output: #{output.strip}"
    end
    {"architecture" => arch, "platform" => actual_platform, "minOS" => version}
  end
  metadata = {"consumer" => inspect_build.call(app_binary, "arm64"),
              "framework" => inspect_build.call(framework_binary, "arm64"),
              "runtimeFramework" => framework_binary, "requiredRunpath" => expected_rpath}
  puts "Prelaunch Mach-O gate passed: #{metadata.inspect}"
  metadata
end

def generated_project(directory, root, route, platform, configuration, framework_path = nil)
  source_dir = File.join(directory, "Sources")
  FileUtils.mkdir_p(source_dir)
  FileUtils.cp(FIXTURE, File.join(source_dir, "HostFixture.swift"))
  native = route == "native-framework"
  ios = platform == "ios-simulator"
  sdk = ios ? "iphoneos" : "macosx"
  product_ref = native ? "A00000000000000000000011" : "A00000000000000000000012"
  link_build = "A00000000000000000000021"
  embed_build = "A00000000000000000000022"
  package_ref = "A00000000000000000000031"
  package_dependency = "A00000000000000000000032"
  route_flags = native ? "NATIVE_FRAMEWORK" : ""
  framework_search_paths = native ? "(\"$(inherited)\", \"#{File.dirname(framework_path)}\", )" : "(\"$(inherited)\", )"
  runtime_path = ios ? "@executable_path/Frameworks" : "@executable_path/../Frameworks"
  runtime_paths = "(\"$(inherited)\", \"#{runtime_path}\", )"
  framework_groups = if native
    <<~PBX
      /* Begin PBXFileReference section */
      #{product_ref} /* UndoKit.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; path = "#{framework_path}"; sourceTree = "<absolute>"; };
      /* End PBXFileReference section */
      /* Begin PBXBuildFile section */
      #{link_build} /* UndoKit.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = #{product_ref}; };
      #{embed_build} /* UndoKit.framework in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = #{product_ref}; settings = {ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }; };
      /* End PBXBuildFile section */
    PBX
  else
    <<~PBX
      /* Begin PBXBuildFile section */
      #{link_build} /* UndoKit in Frameworks */ = {isa = PBXBuildFile; productRef = #{package_dependency}; };
      #{embed_build} /* UndoKit in Embed Frameworks */ = {isa = PBXBuildFile; productRef = #{package_dependency}; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };
      /* End PBXBuildFile section */
      /* Begin XCBuildConfiguration product section */
      #{package_ref} /* XCLocalSwiftPackageReference "." */ = {isa = XCLocalSwiftPackageReference; relativePath = "#{root}"; };
      #{package_dependency} /* XCSwiftPackageProductDependency */ = {isa = XCSwiftPackageProductDependency; package = #{package_ref}; productName = UndoKit; };
      /* End XCBuildConfiguration product section */
    PBX
  end
  product_settings = native ? "" : "packageProductDependencies = (#{package_dependency}, );"
  package_link = native ? "" : "#{package_ref},"
  framework_file_list = native ? "#{product_ref} /* UndoKit.framework */," : ""
  embed_phase = <<~PBX
    A00000000000000000000042 = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = (#{embed_build} /* UndoKit in Embed Frameworks */, ); name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0; };
  PBX
  project = <<~PBX
    // !$*UTF8*$!
    {
    archiveVersion = 1; classes = {}; objectVersion = 60;
    objects = {
    #{framework_groups}
    A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = A00000000000000000000051; compatibilityVersion = "Xcode 14.0"; mainGroup = A00000000000000000000002; packageReferences = (#{package_link}); productRefGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000010, ); };
    A00000000000000000000002 = {isa = PBXGroup; children = (A00000000000000000000005, A00000000000000000000003, #{framework_file_list}); sourceTree = "<group>"; };
    A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000013, ); name = Products; sourceTree = "<group>"; };
    A00000000000000000000004 = {isa = PBXGroup; children = (A00000000000000000000005, ); path = Sources; sourceTree = "<group>"; };
    A00000000000000000000005 = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources; sourceTree = "<group>"; };
    A00000000000000000000013 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Consumer.app; sourceTree = BUILT_PRODUCTS_DIR; };
    A00000000000000000000010 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000052; buildPhases = (A00000000000000000000040, A00000000000000000000041, A00000000000000000000042, A00000000000000000000043, ); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (A00000000000000000000005, ); name = Consumer; #{product_settings} productName = Consumer; productReference = A00000000000000000000013; productType = "com.apple.product-type.application"; };
    A00000000000000000000040 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
    A00000000000000000000041 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (#{link_build} /* UndoKit in Frameworks */, ); runOnlyForDeploymentPostprocessing = 0; };
    #{embed_phase}
    A00000000000000000000043 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
    A00000000000000000000051 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000060, A00000000000000000000061, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    A00000000000000000000052 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000062, A00000000000000000000063, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    A00000000000000000000060 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = #{sdk}; SWIFT_VERSION = 6.0; }; name = Debug; };
    A00000000000000000000061 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = #{sdk}; SWIFT_VERSION = 6.0; }; name = Release; };
    A00000000000000000000062 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; FRAMEWORK_SEARCH_PATHS = #{framework_search_paths}; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = #{runtime_paths}; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = "org.foliosuite.undokit.consumer.#{route == 'native-framework' ? 'nativeframework' : 'package'}.#{platform.gsub('-', '')}"; PRODUCT_NAME = Consumer; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CONSUMER_APP #{route_flags}"; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Debug; };
    A00000000000000000000063 = {isa = XCBuildConfiguration; buildSettings = {CODE_SIGNING_ALLOWED = YES; CODE_SIGN_IDENTITY = "-"; FRAMEWORK_SEARCH_PATHS = #{framework_search_paths}; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = #{runtime_paths}; MACOSX_DEPLOYMENT_TARGET = 14.0; PRODUCT_BUNDLE_IDENTIFIER = "org.foliosuite.undokit.consumer.#{route == 'native-framework' ? 'nativeframework' : 'package'}.#{platform.gsub('-', '')}"; PRODUCT_NAME = Consumer; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) CONSUMER_APP #{route_flags}"; SWIFT_VERSION = 6.0; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Release; };
    };
    rootObject = A00000000000000000000001;
    }
  PBX
  path = File.join(directory, "Consumer.xcodeproj")
  FileUtils.mkdir_p(path)
  File.write(File.join(path, "project.pbxproj"), project)
  File.write(File.join(path, "Package.resolved"), "") unless native
  path
end

temporary_parent = UndoKitBuild.directory("Consumers")
FileUtils.mkdir_p(temporary_parent)
# Reuse build databases across runs/worktrees; serialize their mutation.
consumer_lock = File.open(File.join(temporary_parent, "build.lock"), File::RDWR | File::CREAT, 0o600)
consumer_lock.flock(File::LOCK_EX)
build_root = UndoKitBuild.directory("Consumers", "Build")
at_exit { consumer_lock.close }
Dir.mktmpdir("undokit-consumer-", temporary_parent) do |temporary|
  $consumer_temporary = temporary
  $consumer_keep = options.keep
  evidence_root = File.join(temporary, "host-data")
  FileUtils.mkdir_p(evidence_root)
  source_commit = Open3.capture2("git", "rev-parse", "HEAD", chdir: ROOT).first.strip
  dirty_paths = Open3.capture2("git", "status", "--short", "--untracked-files=all", chdir: ROOT).first.lines.map(&:strip)
  evidence = {
    "capturedAtUTC" => Time.now.utc.iso8601,
    "sourceCommit" => source_commit,
    "workingTreeDirtyPaths" => dirty_paths,
    "xcode" => toolchain,
    "swift" => swift,
    "macOS" => `sw_vers -productVersion`.strip,
    "hostArchitecture" => `uname -m`.strip,
    "configuration" => options.configuration,
    "runs" => []
  }
  selected_simulator = nil
  simulator_created = false
  simulator_booted_here = false
  at_exit do
    if simulator_created && selected_simulator
      system("xcrun", "simctl", "delete", selected_simulator["udid"], out: File::NULL, err: File::NULL)
    elsif simulator_booted_here && selected_simulator
      system("xcrun", "simctl", "shutdown", selected_simulator["udid"], out: File::NULL, err: File::NULL)
    end
  end

  route_names.each do |route|
    platform_names.each do |platform|
      app_route = route == "native" || platform == "ios-simulator"
      if platform == "ios-simulator" && !selected_simulator
        runtimes = JSON.parse(`xcrun simctl list runtimes --json`).fetch("runtimes")
        if options.device
          devices = JSON.parse(run!("xcrun", "simctl", "list", "devices", "available", "--json")).fetch("devices")
          runtime_id, entries = devices.find { |_key, values| values.any? { |entry| entry["udid"] == options.device } }
          device = entries&.find { |entry| entry["udid"] == options.device }
          runtime = runtimes.find { |entry| entry["identifier"] == runtime_id && entry["isAvailable"] }
          unless device && device["isAvailable"] && runtime && runtime_id.start_with?("com.apple.CoreSimulator.SimRuntime.iOS-")
            raise "requested simulator is not an available iOS device: #{options.device}"
          end
          other = devices.values.flatten.find { |entry| entry["state"] == "Booted" && entry["udid"] != options.device }
          raise "another simulator is booted: #{other['udid']}; shut it down before --device validation" if other
          selected_simulator = {"udid" => device["udid"], "name" => device["name"], "runtimeIdentifier" => runtime_id,
                                "runtimeVersion" => runtime["version"], "reused" => true}
          puts "Selected existing iOS simulator: #{device['name']} / #{runtime['name']} / #{device['udid']}"
        else
          runtime = runtimes.select { |entry| entry["isAvailable"] && entry["identifier"].start_with?("com.apple.CoreSimulator.SimRuntime.iOS-") }
            .max_by { |entry| entry.fetch("version", "0").scan(/\d+/).map(&:to_i) }
          device_types = JSON.parse(`xcrun simctl list devicetypes --json`).fetch("devicetypes")
          device_type = device_types.find { |entry| entry["name"] == "iPhone 17" } || device_types.find { |entry| entry["name"].start_with?("iPhone") }
          raise "no available iOS runtime or iPhone simulator device type found" unless runtime && device_type
          udid = `xcrun simctl create "UndoKit Consumer #{SecureRandom.hex(4)}" #{device_type['identifier']} #{runtime['identifier']}`.strip
          raise "could not create an owned iOS simulator" unless $?.success? && !udid.empty?
          selected_simulator = {"udid" => udid, "name" => "UndoKit Consumer", "runtimeIdentifier" => runtime["identifier"], "runtimeVersion" => runtime["version"]}
          simulator_created = true
          puts "Owned iOS simulator: #{device_type['name']} / #{runtime['name']} (#{runtime['version']}) / #{udid}"
        end
      end
      scratch = File.join(temporary, "#{route}-#{platform}")
      FileUtils.mkdir_p(scratch)
      if !app_route
        consumer_package = File.join(scratch, "Package.swift")
        FileUtils.mkdir_p(File.join(scratch, "Sources", "Consumer"))
        FileUtils.cp(FIXTURE, File.join(scratch, "Sources", "Consumer", "main.swift"))
        File.write(consumer_package, <<~SWIFT)
          // swift-tools-version: 6.0
          import PackageDescription
          let package = Package(name: "UndoKitConsumer", platforms: [.macOS(.v14)],
            dependencies: [.package(name: "UndoKit", path: #{ROOT.to_json})],
            targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "UndoKit", package: "UndoKit")])],
            swiftLanguageModes: [.v6])
        SWIFT
        report = File.join(evidence_root, "#{route}-#{platform}-report.json")
        root = File.join(evidence_root, "#{route}-#{platform}-host")
        FileUtils.mkdir_p(root)
        build = File.join(build_root, "Package")
        run!("swift", "run", "--configuration", options.configuration.downcase, "--package-path", scratch,
             "--scratch-path", build, "Consumer", env: {"UNDOkit_CONSUMER_ROOT" => root, "UNDOkit_CONSUMER_REPORT" => report,
               "CLANG_MODULE_CACHE_PATH" => File.join(build_root, "ModuleCache")},
             label: "SwiftPM source consumer: #{platform} #{options.configuration}")
        puts "Evidence: #{JSON.parse(File.read(report)).inspect}"
        resource_paths = verify_resources!(build, "package")
        puts "Installed source-package resources: #{resource_paths.inspect}"
        evidence["runs"] << {"route" => "source-package", "platform" => platform,
          "consumerReport" => JSON.parse(File.read(report)), "installedResources" => resource_paths,
          "artifactSHA256" => artifact_hashes(resource_paths, build)}
        next
      end

      framework_path = nil
      if route == "native"
        derived = File.join(build_root, "Native")
        destination = platform == "ios-simulator" ? "generic/platform=iOS Simulator" : "generic/platform=macOS"
        command = ["xcodebuild", "-project", File.join(ROOT, "UndoKit.xcodeproj"), "-scheme", "UndoKit",
                   "-configuration", options.configuration, "-destination", destination,
                   "-derivedDataPath", derived, "-onlyUsePackageVersionsFromResolvedFile",
                   "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
                   "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "build"]
        # Hosted CI validates the reviewed dependency pin before this command;
        # it cannot accept Xcode's interactive unsigned-plugin approval prompt.
        command.insert(1, "-skipPackagePluginValidation") if ENV["GITHUB_ACTIONS"] == "true"
        run!(*command, label: "Native framework build: #{platform} universal").
          tap { |output| raise "expected native framework build output" if output.empty? }
        product_configuration = options.configuration + (platform == "ios-simulator" ? "-iphonesimulator" : "")
        framework_path = File.join(derived, "Build", "Products", product_configuration, "UndoKit.framework")
        raise "native framework missing under #{File.join(derived, 'Build', 'Products')}" unless framework_path && File.directory?(framework_path)
        architectures, lipo_status = Open3.capture2("lipo", "-archs", File.join(framework_path, "UndoKit"))
        raise "could not inspect native framework architectures" unless lipo_status.success?
        architectures = architectures.strip
        raise "native framework does not contain arm64 and x86_64: #{architectures}" unless %w[arm64 x86_64].all? { |arch| architectures.split.include?(arch) }
        puts "Native #{platform} framework architectures: #{architectures}; runtime evidence remains separate"
      end

      project = generated_project(scratch, ROOT, route == "native" ? "native-framework" : "source-package",
                                  platform, options.configuration, framework_path)
      derived = File.join(build_root, "Host")
      destination = platform == "ios-simulator" ? "id=#{selected_simulator['udid']}" : "generic/platform=macOS"
      run!("xcodebuild", "-project", project, "-scheme", "Consumer", "-configuration", options.configuration,
           "-destination", destination, "-derivedDataPath", derived,
           "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-", "build",
           label: "Independent #{route} app build: #{platform} #{options.configuration}")
      product_configuration = options.configuration + (platform == "ios-simulator" ? "-iphonesimulator" : "")
      app = File.join(derived, "Build", "Products", product_configuration, "Consumer.app")
      raise "consumer app missing under #{File.join(derived, 'Build', 'Products')}" unless app && File.directory?(app)
      resource_paths = verify_resources!(app, route)
      puts "Installed #{route} resources: #{resource_paths.inspect}"
      macho_evidence = verify_macho!(app, platform)
      bundle_id = "org.foliosuite.undokit.consumer.#{route == 'native' ? 'nativeframework' : 'package'}.#{platform.gsub('-', '')}"
      if platform == "ios-simulator"
        booted = JSON.parse(run!("xcrun", "simctl", "list", "devices", "booted", "--json")).fetch("devices").values.flatten
        if options.device && booted.any? { |entry| entry["udid"] != selected_simulator["udid"] }
          raise "another simulator became booted; refusing to start a second simulator"
        end
        unless booted.any? { |entry| entry["udid"] == selected_simulator["udid"] }
          simulator_booted_here = true
          run!("xcrun", "simctl", "boot", selected_simulator["udid"])
        end
        run!("xcrun", "simctl", "bootstatus", selected_simulator["udid"], "-b")
        run!("xcrun", "simctl", "install", selected_simulator["udid"], app)
        container = run!("xcrun", "simctl", "get_app_container", selected_simulator["udid"], bundle_id, "data").strip
        evidence_route = route == "native" ? "native-framework" : "source-package"
        # Every installed launch gets fresh stores and reports, including reused devices.
        evidence_directory = File.join(container, "Library", "Application Support",
                                       "UndoKitConsumerEvidence-#{evidence_route}-#{SecureRandom.uuid}")
        run!("xcrun", "simctl", "launch", "--terminate-running-process", selected_simulator["udid"], bundle_id,
             env: {"SIMCTL_CHILD_UNDOkit_CONSUMER_ROOT" => evidence_directory})
        report_path = nil
        60.times do
          candidate = File.join(evidence_directory, "ConsumerReport.json")
          failure = File.join(evidence_directory, "ConsumerFailure.txt")
          raise "simulator consumer failed: #{File.read(failure)}" if File.file?(failure)
          if File.file?(candidate)
            report_path = candidate
            break
          end
          sleep 1
        end
        raise "simulator app produced no consumer report" unless report_path
        report = JSON.parse(File.read(report_path))
        FileUtils.cp(report_path, File.join(evidence_root, "#{route}-#{platform}-report.json"))
      else
        evidence_route = route == "native" ? "native-framework" : "source-package"
        root = File.join(evidence_root, "#{route}-#{platform}-host")
        FileUtils.mkdir_p(root)
        run!(File.join(app, "Contents", "MacOS", "Consumer"), env: {"UNDOkit_CONSUMER_ROOT" => root},
             label: "Run independent macOS #{route} consumer")
        report_file = File.join(root, "ConsumerReport.json")
        raise "macOS consumer report missing at #{report_file}" unless File.file?(report_file)
        report = JSON.parse(File.read(report_file))
        raise "consumer report did not prove durable grouped behavior: #{report}" unless report["hostValue"] == "alpha-beta" && report["receiptCount"] == 3 && report["appliedMembers"] == 6 && report["bundledModelLoaded"]
        FileUtils.cp(report_file, File.join(evidence_root, "#{route}-#{platform}-report.json"))
        puts "Evidence: #{report.inspect}"
      end
      if platform == "ios-simulator"
        raise "consumer report did not prove the expected durable grouped behavior: #{report}" unless report["hostValue"] == "alpha-beta" && report["receiptCount"] == 3 && report["appliedMembers"] == 6 && report["bundledModelLoaded"] && report["processArchitecture"]
        puts "Evidence: #{report.inspect}"
        puts "Simulator runtime: #{selected_simulator['runtimeIdentifier']} #{selected_simulator['runtimeVersion']}"
      end
      evidence["runs"] << {"route" => route == "native" ? "native-framework" : "source-package",
        "platform" => platform, "consumerReport" => report, "installedResources" => resource_paths,
        "artifactSHA256" => artifact_hashes(resource_paths, app), "prelaunchMachO" => macho_evidence,
        "simulator" => selected_simulator && platform == "ios-simulator" ? selected_simulator : nil}
    end
  end

  evidence_json = JSON.pretty_generate(evidence)
  File.write(File.join(temporary, "ConsumerEvidence.json"), evidence_json + "\n")
  puts "ConsumerEvidence.json summary (also retained when --keep is omitted):\n#{evidence_json}"

  if options.keep
    destination = File.join(temporary_parent, "kept-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
    FileUtils.cp_r(temporary, destination)
    puts "Retained consumer evidence: #{destination}"
  else
    puts "Consumer harness passed; temporary stores/projects removed; shared build cache retained at #{build_root}"
  end
end
