#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'timeout'
require_relative 'build-support'

options = { configuration: 'Debug', mode: :build }
invocation = ARGV.dup
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/run-durable-notes-swiftui-macos.rb [--check | --launch] [--configuration Debug|Release]'
  parser.on('--check', 'Run public host tests and installed SwiftUI/AppKit checks') { options[:mode] = :check }
  parser.on('--launch', 'Open the built sample for interactive use') { options[:mode] = :launch }
  parser.on('--configuration NAME', %w[Debug Release]) { |value| options[:configuration] = value }
end.parse!
abort 'Unexpected arguments' unless ARGV.empty?

repository = File.expand_path('..', __dir__)
package = File.join(repository, 'Examples', 'DurableNotes')
cache = UndoKitBuild.directory('DurableNotesSwiftUI')
evidence = UndoKitBuild.directory('Evidence', 'DurableNotesSwiftUI', "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
configuration = options[:configuration]
swift_configuration = configuration.downcase

def run!(arguments, log)
  File.open(log, 'a') do |output|
    output.puts(arguments.join(' '))
    output.flush
    success = system(*arguments, out: output, err: output)
    abort "Command failed; see #{log}" unless success
  end
end

File.open(File.join(cache, '.runner.lock'), 'w') do |lock|
  abort 'Another Durable Notes build is using the shared cache' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
  common = ['--package-path', package, '--scratch-path', cache, '--configuration', swift_configuration]
  if options[:mode] == :check
    run!(['swift', 'test', *common, '--filter', 'Notes'], File.join(evidence, 'HostTests.log'))
  else
    run!(['swift', 'build', *common, '--product', 'DurableNotesSwiftUIApp'], File.join(evidence, 'Build.log'))
  end
  binary_path, status = Open3.capture2('swift', 'build', *common, '--show-bin-path')
  abort 'Cannot resolve sample product directory' unless status.success?
  binary_path = binary_path.strip
  app = File.join(cache, 'Installed', configuration, 'Durable Notes SwiftUI.app')
  executable = File.join(app, 'Contents', 'MacOS', 'DurableNotesSwiftUIApp')
  frameworks = File.join(app, 'Contents', 'Frameworks')
  resources = File.join(app, 'Contents', 'Resources')
  if File.exist?(app)
    previous_info = File.join(app, 'Contents', 'Info.plist')
    abort "Refusing to replace an unrecognized app at #{app}" unless File.file?(previous_info) &&
      File.read(previous_info).include?('app.foliosuite.UndoKit.DurableNotesSwiftUI')
    # Replace only this runner's generated bundle, never its user-data directory.
    FileUtils.remove_entry(app)
  end
  FileUtils.mkdir_p([File.dirname(executable), frameworks, resources])
  FileUtils.cp(File.join(binary_path, 'DurableNotesSwiftUIApp'), executable)
  library = File.join(frameworks, 'libUndoKit.dylib')
  FileUtils.cp(File.join(binary_path, 'libUndoKit.dylib'), library)
  FileUtils.cp_r(File.join(binary_path, 'UndoKit_UndoKit.bundle'), resources)
  File.write(File.join(app, 'Contents', 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.foliosuite.UndoKit.DurableNotesSwiftUI</string>
    <key>CFBundleName</key><string>Durable Notes SwiftUI</string>
    <key>CFBundleExecutable</key><string>DurableNotesSwiftUIApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    </dict></plist>
  PLIST
  install_log = File.join(evidence, 'Install.log')
  load_commands, load_status = Open3.capture2('otool', '-l', executable)
  abort 'Cannot inspect native loader paths' unless load_status.success?
  load_commands.scan(/cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset/).flatten.each do |path|
    next unless path.start_with?('/') && path != '/usr/lib/swift'
    run!(['install_name_tool', '-delete_rpath', path, executable], install_log)
  end
  run!(['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', executable], install_log)
  run!(['codesign', '--force', '--sign', '-', '--timestamp=none', library], install_log)
  run!(['codesign', '--force', '--sign', '-', '--timestamp=none', app], install_log)
  run!(['codesign', '--verify', '--deep', '--strict', app], install_log)
  source, = Open3.capture2('git', '-C', repository, 'rev-parse', 'HEAD')
  dirty, = Open3.capture2('git', '-C', repository, 'status', '--porcelain')
  xcode, = Open3.capture2('xcodebuild', '-version')
  swift, = Open3.capture2('swift', '--version')
  changed_paths, = Open3.capture2('git', '-C', repository, 'ls-files', '--modified', '--others', '--exclude-standard')
  changed_hashes = changed_paths.lines.map(&:chomp).uniq.map do |path|
    full_path = File.join(repository, path)
    [path, Digest::SHA256.file(full_path).hexdigest] if File.file?(full_path)
  end.compact.to_h
  File.write(File.join(evidence, 'Setup.json'), JSON.pretty_generate(
    source: source.strip, uncommitted_paths: dirty.lines.map(&:chomp), configuration: configuration,
    route: 'source-package-installed-SwiftUI-AppKit-app', application: app, xcode: xcode.strip, swift: swift.strip,
    evidence: evidence, command: ['ruby', 'scripts/run-durable-notes-swiftui-macos.rb', *invocation],
    changed_source_sha256: changed_hashes, executable_sha256: Digest::SHA256.file(executable).hexdigest,
    undokit_sha256: Digest::SHA256.file(library).hexdigest))

  if options[:mode] == :check
    fixture = File.join(evidence, 'NativeFixture')
    FileUtils.mkdir_p(fixture)
    log = File.join(evidence, 'Native.log')
    pid = Process.spawn({ 'UNDOKIT_SWIFTUI_NOTES_ROOT' => fixture }, executable, '--native-check', out: log, err: log)
    begin
      _, result = Timeout.timeout(120) { Process.wait2(pid) }
      abort "Native check failed; see #{log} and #{fixture}" unless result.success?
    rescue Timeout::Error
      Process.kill('TERM', pid)
      Process.wait(pid)
      abort "Native check timed out; see #{log}"
    end
    abort 'Native app exited without its report' unless File.file?(File.join(fixture, 'NativeReport.json'))
    puts "Public-session and installed SwiftUI/AppKit checks passed. Evidence: #{evidence}"
  elsif options[:mode] == :launch
    run!(['open', app], File.join(evidence, 'Launch.log'))
  end
  puts "Application: #{app}"
end
