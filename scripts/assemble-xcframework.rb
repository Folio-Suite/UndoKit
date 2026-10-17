#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require "digest"
require "fileutils"
require "json"
require "optparse"
require "open3"
require "securerandom"
require "time"
require_relative "build-support"
require_relative "xcframework/assembly"

module UndoKit
  module XCFrameworkCommand
    module_function

    Assembly = XCFrameworkAssembly

    def execute(options)
      validate_options!(options)
      source = git_output("rev-parse", "HEAD")
      source_tree = git_output("rev-parse", "HEAD^{tree}")
      dirty = git_output("status", "--porcelain", "--untracked-files=all")
      unless dirty.empty?
        raise Assembly::VerificationError, "source checkout must be clean before assembly; changed paths:\n#{dirty}"
      end

      xcode = Assembly.capture!("xcodebuild", "-version")
      swift = Assembly.capture!("xcrun", "swift", "--version")
      check_toolchain!(xcode, swift)

      shared_root = UndoKitBuild.root
      repo_root = File.expand_path("..", __dir__)
      if shared_root == repo_root || shared_root.start_with?(repo_root + File::SEPARATOR)
        raise Assembly::VerificationError, "shared build root must be outside the checkout: #{shared_root}"
      end

      output_root = UndoKitBuild.directory("XCFramework")
      build_root = UndoKitBuild.directory("XCFramework", "Build")
      candidate_id = "#{options.fetch(:version)}-#{options.fetch(:build_number)}-#{source[0, 12]}-#{options.fetch(:run_id)}"
      candidates_root = UndoKitBuild.directory("XCFramework", "Candidates")
      candidate_root = File.join(candidates_root, candidate_id)
      begin
        Dir.mkdir(candidate_root)
      rescue Errno::EEXIST
        raise Assembly::VerificationError, "candidate output already exists; choose a new --run-id: #{candidate_root}"
      end
      archive_root = File.join(candidate_root, "archives")
      logs_root = File.join(candidate_root, "logs")
      FileUtils.mkdir_p([archive_root, logs_root])
      lock_path = File.join(output_root, "Build.lock")
      puts "Waiting for shared UndoKit XCFramework build lock: #{lock_path}"

      begin
        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          puts "Using shared build intermediates: #{build_root}"
          archives = build_archives!(options, candidate_root, archive_root, logs_root, build_root)
          assembled = assemble!(candidate_root, archives, logs_root)
          variants = Assembly.verify_xcframework!(assembled, File.join(repo_root, "UndoKit", "Resources", "PrivacyInfo.xcprivacy"))
          ensure_source_unchanged!(source, source_tree)
          archive_evidence = archives.to_h do |target_name, paths|
            [target_name, {
              "archivePath" => paths.fetch(:archive),
              "archiveTreeSHA256" => Assembly.tree_sha256(paths.fetch(:archive)),
              "frameworkPath" => paths.fetch(:framework),
              "originalDSYMPath" => paths.fetch(:symbols),
              "logPath" => paths.fetch(:log),
              "command" => paths.fetch(:command),
              "buildSettings" => paths.fetch(:settings)
            }]
          end
          provenance = {
            "schemaVersion" => 1,
            "createdAtUTC" => Time.now.utc.iso8601,
            "candidateID" => candidate_id,
            "releaseVersion" => options.fetch(:version),
            "frameworkBuildNumber" => options.fetch(:build_number),
            "sourceCommit" => source,
            "sourceTree" => source_tree,
            "sourceTagPresent" => system("git", "show-ref", "--verify", "--quiet", "refs/tags/#{options.fetch(:version)}"),
            "workingTreeDirtyPaths" => [],
            "toolchain" => {"xcodebuildVersion" => xcode.lines.map(&:strip), "swiftVersion" => swift.lines.map(&:strip)},
            "configuration" => "Release",
            "procedure" => {
              "script" => "scripts/assemble-xcframework.rb",
              "arguments" => ["--version", options.fetch(:version), "--build-number", options.fetch(:build_number), "--run-id", options.fetch(:run_id)],
              "buildIntermediates" => build_root,
              "codeSigning" => "disabled",
              "platforms" => Assembly::ARCHIVE_TARGETS.map do |target|
                target.slice(:name, :destination, :sdk, :architectures, :minimum_os)
              end
            },
            "archives" => archive_evidence,
            "xcframeworkPath" => assembled,
            "xcframeworkTreeSHA256" => Assembly.tree_sha256(assembled),
            "variants" => variants
          }
          ensure_source_unchanged!(source, source_tree)
          provenance_path = File.join(candidate_root, "provenance.json")
          File.write(provenance_path, JSON.pretty_generate(provenance) + "\n")
          File.write(File.join(candidate_root, "provenance.sha256"), "#{Digest::SHA256.file(provenance_path).hexdigest}  provenance.json\n")
          puts "Assembled unsigned XCFramework: #{assembled}"
          puts "Provenance: #{provenance_path}"
          puts "Retained archives: #{archive_root}"
        end
      rescue StandardError => error
        failure = {
          "failedAtUTC" => Time.now.utc.iso8601,
          "candidateID" => candidate_id,
          "sourceCommitAtStart" => source,
          "sourceCommitAtFailure" => safe_git_output("rev-parse", "HEAD"),
          "sourceDirtyPathsAtFailure" => safe_git_output("status", "--porcelain", "--untracked-files=all").lines.map(&:strip),
          "error" => "#{error.class}: #{error.message}",
          "logsDirectory" => logs_root,
          "archivesDirectory" => archive_root
        }
        File.write(File.join(candidate_root, "assembly-failure.json"), JSON.pretty_generate(failure) + "\n")
        raise
      end
    end

    def build_archives!(options, candidate_root, archive_root, logs_root, build_root)
      Assembly::ARCHIVE_TARGETS.to_h do |target|
        archive = File.join(archive_root, "UndoKit-#{target.fetch(:name)}.xcarchive")
        log = File.join(logs_root, "archive-#{target.fetch(:name)}.log")
        settings = {
          "ARCHS" => target.fetch(:architectures).join(" "),
          "ONLY_ACTIVE_ARCH" => "NO",
          "SKIP_INSTALL" => "NO",
          "BUILD_LIBRARY_FOR_DISTRIBUTION" => "YES",
          "DEBUG_INFORMATION_FORMAT" => "dwarf-with-dsym",
          "CODE_SIGNING_ALLOWED" => "NO",
          "CODE_SIGNING_REQUIRED" => "NO",
          "CODE_SIGN_IDENTITY" => "",
          "MARKETING_VERSION" => options.fetch(:version),
          "CURRENT_PROJECT_VERSION" => options.fetch(:build_number),
          "MACOSX_DEPLOYMENT_TARGET" => "14.0",
          "IPHONEOS_DEPLOYMENT_TARGET" => "17.0",
          "SWIFT_VERSION" => "6.0",
          "SWIFT_STRICT_CONCURRENCY" => "complete"
        }
        command = ["xcodebuild", "-project", File.join(File.expand_path("..", __dir__), "UndoKit.xcodeproj"),
                   "-scheme", "UndoKit", "-configuration", "Release", "-destination", target.fetch(:destination),
                   "-derivedDataPath", build_root, "-clonedSourcePackagesDirPath", File.join(build_root, "SourcePackages"),
                   "-onlyUsePackageVersionsFromResolvedFile", "-archivePath", archive]
        command.insert(1, "-skipPackagePluginValidation") if ENV["GITHUB_ACTIONS"] == "true"
        settings.each { |key, value| command << "#{key}=#{value}" }
        command << "archive"
        run_command!(command, log)

        framework = File.join(archive, "Products", "Library", "Frameworks", "UndoKit.framework")
        symbols = File.join(archive, "dSYMs", "UndoKit.framework.dSYM")
        raise Assembly::VerificationError, "archive did not produce #{framework}" unless File.directory?(framework)
        raise Assembly::VerificationError, "archive did not produce exact framework dSYM #{symbols}" unless File.directory?(symbols)
        validate_archive_versions!(framework, options)
        evidence = Assembly.verify_framework!(framework, symbols, target)
        raise Assembly::VerificationError, "archive privacy resource differs from source" unless
          evidence.fetch("privacyManifestSHA256") == Digest::SHA256.file(File.join(File.expand_path("..", __dir__), "UndoKit", "Resources", "PrivacyInfo.xcprivacy")).hexdigest
        [target.fetch(:name), {archive: archive, framework: framework, symbols: symbols, log: log,
                               command: command, settings: settings, verification: evidence}]
      end
    end

    def validate_archive_versions!(framework, options)
      info = Assembly.capture!("plutil", "-convert", "json", "-o", "-",
                               File.join(Assembly.framework_resource_root(framework), "Info.plist"))
      bundle = JSON.parse(info)
      unless bundle.fetch("CFBundleShortVersionString") == options.fetch(:version) &&
             bundle.fetch("CFBundleVersion").to_s == options.fetch(:build_number)
        raise Assembly::VerificationError, "framework Info.plist version does not match #{options.fetch(:version)} (#{options.fetch(:build_number)})"
      end
    rescue JSON::ParserError, KeyError => error
      raise Assembly::VerificationError, "invalid framework version metadata: #{error.message}"
    end

    def assemble!(candidate_root, archives, logs_root)
      output = File.join(candidate_root, "UndoKit.xcframework")
      command = ["xcodebuild", "-create-xcframework"]
      Assembly::ARCHIVE_TARGETS.each do |target|
        paths = archives.fetch(target.fetch(:name))
        command.concat(["-framework", paths.fetch(:framework), "-debug-symbols", paths.fetch(:symbols)])
      end
      command.concat(["-output", output])
      run_command!(command, File.join(logs_root, "create-xcframework.log"))
      raise Assembly::VerificationError, "Xcode did not create #{output}" unless File.directory?(output)

      output
    end

    def check_toolchain!(xcode, swift)
      unless xcode.match?(/\AXcode 27\.1\nBuild version 27A9275\s*\z/)
        raise Assembly::VerificationError, "expected Xcode 27.1 (27A9275); found:\n#{xcode}"
      end
      unless swift.match?(/Apple Swift version 6\.4 \(swiftlang-6\.4\.0\.34\.1 clang-2100\.3\.34\.1\)/)
        raise Assembly::VerificationError, "expected Apple Swift 6.4 swiftlang-6.4.0.34.1 / clang 2100.3.34.1; found:\n#{swift}"
      end
    end

    def validate_options!(options)
      unless options[:version]&.match?(/\A\d+\.\d+\.\d+\z/)
        raise Assembly::VerificationError, "--version must use major.minor.patch form"
      end
      unless options[:build_number]&.match?(/\A[1-9]\d*\z/)
        raise Assembly::VerificationError, "--build-number must be a positive integer"
      end
      unless options[:run_id]&.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
        raise Assembly::VerificationError, "--run-id must contain only letters, numbers, dot, underscore, and hyphen"
      end
    end

    def git_output(*arguments)
      output, status = Open3.capture2("git", *arguments, chdir: File.expand_path("..", __dir__))
      raise Assembly::VerificationError, "git #{arguments.join(' ')} failed" unless status.success?

      output.strip
    end

    def safe_git_output(*arguments)
      git_output(*arguments)
    rescue StandardError
      "unavailable"
    end

    def ensure_source_unchanged!(source, source_tree)
      current_commit = git_output("rev-parse", "HEAD")
      current_tree = git_output("rev-parse", "HEAD^{tree}")
      dirty = git_output("status", "--porcelain", "--untracked-files=all")
      unless current_commit == source && current_tree == source_tree && dirty.empty?
        raise Assembly::VerificationError, "source checkout changed during assembly; expected clean commit #{source}, found #{current_commit} with paths:\n#{dirty}"
      end
    end

    def run_command!(command, log)
      puts "Running: #{command.join(' ')}"
      output, status = Open3.capture2e(*command)
      File.write(log, "$ #{command.join(' ')}\n#{output}")
      return output if status.success?

      warn output
      raise Assembly::VerificationError, "#{command.first} failed (#{status.exitstatus}); full output retained in #{log}"
    end
  end
end

options = {version: nil, build_number: nil, run_id: nil}
parser = OptionParser.new do |arguments|
  arguments.banner = "Usage: scripts/assemble-xcframework.rb --version X.Y.Z --build-number N [--run-id ID]"
  arguments.on("--version VERSION", "Three-part framework marketing version") { |value| options[:version] = value }
  arguments.on("--build-number NUMBER", "Monotonic framework build number") { |value| options[:build_number] = value }
  arguments.on("--run-id ID", "Unique candidate run identifier; an unused ID is required") { |value| options[:run_id] = value }
  arguments.on("-h", "--help", "Show this help") { puts arguments; exit 0 }
end
parser.parse!
options[:run_id] ||= "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"

begin
  UndoKit::XCFrameworkCommand.execute(options)
rescue UndoKit::XCFrameworkAssembly::VerificationError => error
  warn "XCFramework assembly failed: #{error.message}"
  exit 1
end
