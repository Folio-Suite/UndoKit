#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'json'
require 'fileutils'
require 'optparse'
require 'open3'
require 'digest'
require 'time'
require_relative 'build-support'

options = {sdk: 'iphonesimulator', configuration: 'Release', team: nil, profile: 'smoke'}
OptionParser.new do |parser|
  parser.banner = 'Usage: scripts/build-scale-device.rb --sdk iphonesimulator|iphoneos [--team ID] [--configuration Debug|Release]'
  parser.on('--sdk SDK', %w[iphonesimulator iphoneos]) { |v| options[:sdk] = v }
  parser.on('--team ID') { |v| options[:team] = v }
  parser.on('--profile NAME', %w[smoke simulator-full]) { |v| options[:profile] = v }
  parser.on('--configuration NAME', %w[Debug Release]) { |v| options[:configuration] = v }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!
abort '--team is required for an installable physical-device build' if options[:sdk] == 'iphoneos' && !options[:team]
abort 'simulator-full requires --sdk iphonesimulator' if options[:profile] == 'simulator-full' && options[:sdk] != 'iphonesimulator'
root = File.expand_path('..', __dir__)
project_root = UndoKitBuild.directory('Scale', 'DeviceProject')
build_root = UndoKitBuild.directory('Scale', 'DeviceBuild')
lock = File.open(File.join(UndoKitBuild.directory('Scale'), 'device-build.lock'), File::RDWR | File::CREAT, 0o600)
lock.flock(File::LOCK_EX) unless ENV['UNDOKIT_SCALE_DEVICE_BUILD_LOCK_HELD'] == '1'
source_root = File.join(project_root, 'Sources')
FileUtils.mkdir_p(source_root)
Dir.glob(File.join(source_root, '*.swift')).each { |path| File.delete(path) }
sources = Dir.glob(File.join(__dir__, 'scale', 'Workload', '*.swift')) + [File.join(__dir__, 'scale', 'ScaleDeviceApp.swift')]
sources.each { |path| FileUtils.cp(path, source_root) }
def capture(*command)
  value, status = Open3.capture2e(*command)
  raise "#{command.inspect} failed: #{value}" unless status.success?
  value.strip
end
manifest = {'capturedAtUTC' => Time.now.utc.iso8601, 'sourceHead' => capture('git', '-C', root, 'rev-parse', 'HEAD'),
            'sourceDirtyPaths' => capture('git', '-C', root, 'status', '--short', '--untracked-files=all').lines.map(&:strip),
            'sourceSHA256' => (sources + Dir.glob(File.join(root, 'UndoKit', '**/*')).select { |p| File.file?(p) } + [File.join(root, 'Package.swift')]).to_h { |p| [p.delete_prefix(root + '/'), Digest::SHA256.file(p).hexdigest] },
            'toolchain' => capture('xcodebuild', '-version'), 'swift' => capture('swift', '--version'),
            'configuration' => options[:configuration], 'sdk' => options[:sdk],
            'profile' => options[:profile],
            'budgets' => {seconds: 900, residentBytes: (options[:profile] == 'simulator-full' ? 2 * 1024**3 : 512 * 1024**2), evidenceAllocatedBytes: 2 * 1024**3,
                          minimumFreeBytes: 4 * 1024**3, ordinaryHeartbeatSeconds: 1, externalBuildCacheBytes: 12 * 1024**3, externalMinimumFreeBytes: 20 * 1024**3},
            'qualification' => options[:sdk] == 'iphoneos' ? 'physical runtime pending; build is not acceptance' : (options[:profile] == 'simulator-full' ? 'full simulator fixture; not physical qualification' : 'simulator smoke only; not physical qualification')}
File.write(File.join(source_root, 'BuildManifest.json'), JSON.pretty_generate(manifest) + "\n")
sign = options[:sdk] == 'iphoneos' ? "CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = #{options[:team]};" : 'CODE_SIGN_IDENTITY = "-";'
project = <<~PBX
  // !$*UTF8*$!
  { archiveVersion = 1; classes = {}; objectVersion = 60; objects = {
    A00000000000000000000001 = {isa = PBXProject; attributes = {LastUpgradeCheck = 2700; }; buildConfigurationList = A00000000000000000000051; compatibilityVersion = "Xcode 14.0"; mainGroup = A00000000000000000000002; packageReferences = (A00000000000000000000031, ); productRefGroup = A00000000000000000000003; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000010, ); };
    A00000000000000000000002 = {isa = PBXGroup; children = (A00000000000000000000005, A00000000000000000000003, ); sourceTree = "<group>"; };
    A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000013, ); name = Products; sourceTree = "<group>"; };
    A00000000000000000000005 = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources; sourceTree = "<group>"; };
    A00000000000000000000013 = {isa = PBXFileReference; explicitFileType = wrapper.application; path = ScaleDevice.app; sourceTree = BUILT_PRODUCTS_DIR; };
    A00000000000000000000031 = {isa = XCLocalSwiftPackageReference; relativePath = "#{root}"; };
    A00000000000000000000032 = {isa = XCSwiftPackageProductDependency; package = A00000000000000000000031; productName = UndoKit; };
    A00000000000000000000021 = {isa = PBXBuildFile; productRef = A00000000000000000000032; };
    A00000000000000000000022 = {isa = PBXBuildFile; productRef = A00000000000000000000032; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };
    A00000000000000000000010 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000052; buildPhases = (A00000000000000000000040, A00000000000000000000041, A00000000000000000000042, A00000000000000000000043, ); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (A00000000000000000000005, ); name = ScaleDevice; packageProductDependencies = (A00000000000000000000032, ); productName = ScaleDevice; productReference = A00000000000000000000013; productType = "com.apple.product-type.application"; };
    A00000000000000000000040 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
    A00000000000000000000041 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000021, ); runOnlyForDeploymentPostprocessing = 0; };
    A00000000000000000000042 = {isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 10; files = (A00000000000000000000022, ); name = "Embed Frameworks"; runOnlyForDeploymentPostprocessing = 0; };
    A00000000000000000000043 = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
    A00000000000000000000051 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000060, A00000000000000000000061, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    A00000000000000000000052 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000062, A00000000000000000000063, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
    A00000000000000000000060 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; SWIFT_VERSION = 6.0; }; name = Debug; };
    A00000000000000000000061 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; SWIFT_VERSION = 6.0; }; name = Release; };
    A00000000000000000000062 = {isa = XCBuildConfiguration; buildSettings = {#{sign} GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", ); PRODUCT_BUNDLE_IDENTIFIER = org.foliosuite.undokit.scale; PRODUCT_NAME = ScaleDevice; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Debug; };
    A00000000000000000000063 = {isa = XCBuildConfiguration; buildSettings = {#{sign} GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; IPHONEOS_DEPLOYMENT_TARGET = 17.0; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", ); PRODUCT_BUNDLE_IDENTIFIER = org.foliosuite.undokit.scale; PRODUCT_NAME = ScaleDevice; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; TARGETED_DEVICE_FAMILY = "1,2"; }; name = Release; };
    }; rootObject = A00000000000000000000001; }
PBX
project_path = File.join(project_root, 'ScaleDevice.xcodeproj')
FileUtils.mkdir_p(project_path)
File.write(File.join(project_path, 'project.pbxproj'), project)
command = ['xcodebuild', '-project', project_path, '-scheme', 'ScaleDevice', '-configuration', options[:configuration],
           '-sdk', options[:sdk], '-destination', options[:sdk] == 'iphoneos' ? 'generic/platform=iOS' : 'generic/platform=iOS Simulator',
           '-derivedDataPath', build_root, 'build']
command += ['-allowProvisioningUpdates'] if options[:sdk] == 'iphoneos'
log = File.join(project_root, 'build.log')
success = system(*command, out: log, err: log)
manifest['buildSucceeded'] = success
manifest['command'] = command
app = File.join(build_root, 'Build', 'Products', "#{options[:configuration]}-#{options[:sdk]}", 'ScaleDevice.app')
if success
  manifest['artifactSHA256'] = Dir.glob(File.join(app, '**/*'), File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(app + '/'), Digest::SHA256.file(p).hexdigest] }
  # The complete artifact hash inventory is external: modifying the signed app here
  # would invalidate its signature and the inventory itself. The embedded manifest
  # captures source/toolchain/configuration before compilation.
end
File.write(File.join(project_root, 'BuildManifest.json'), JSON.pretty_generate(manifest) + "\n")
puts "Project: #{project_path}\nApp: #{app}\nBuild evidence: #{File.join(project_root, 'BuildManifest.json')}\nLog: #{log}"
exit(success ? 0 : 1)
