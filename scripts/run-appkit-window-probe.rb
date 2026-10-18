#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require_relative 'build-support'

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/run-appkit-window-probe.rb\nBuild and launch a standalone AppKit comparison; exercise its windows and Settings manually, then quit normally."
end.parse!
abort 'Unexpected arguments' unless ARGV.empty?
repository = File.expand_path('..', __dir__)
source = File.join(__dir__, 'diagnostics', 'AppKitWindowProbe.swift')
cache = UndoKitBuild.directory('AppKitWindowProbe')
evidence = UndoKitBuild.directory('Evidence', 'AppKitWindowProbe', "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
app = File.join(cache, 'Native Window Probe.app')
executable = File.join(app, 'Contents', 'MacOS', 'NativeWindowProbe')
File.open(File.join(cache, '.runner.lock'), 'w') do |lock|
  abort 'Another AppKit probe build is using the cache' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
  FileUtils.mkdir_p(File.dirname(executable))
  log = File.join(evidence, 'Build.log')
  File.open(log, 'w') do |output|
    abort "Probe compilation failed: #{log}" unless system('swiftc', '-swift-version', '6', '-strict-concurrency=complete', source, '-o', executable, out: output, err: output)
  end
  File.write(File.join(app, 'Contents', 'Info.plist'), <<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>app.foliosuite.diagnostics.AppKitWindowProbe</string>
    <key>CFBundleName</key><string>Native Window Probe</string>
    <key>CFBundleExecutable</key><string>NativeWindowProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    </dict></plist>
  PLIST
  abort 'Cannot sign probe' unless system('codesign', '--force', '--sign', '-', '--timestamp=none', app, out: File::NULL)
  capture = lambda do |*command|
    text, status = Open3.capture2(*command)
    abort "Cannot record #{command.first}" unless status.success?
    text.strip
  end
  File.write(File.join(evidence, 'Setup.json'), JSON.pretty_generate(
    source: capture.call('git', '-C', repository, 'rev-parse', 'HEAD'),
    dirty_paths: capture.call('git', '-C', repository, 'status', '--porcelain').lines.map(&:chomp),
    probe_source_sha256: Digest::SHA256.file(source).hexdigest,
    executable_sha256: Digest::SHA256.file(executable).hexdigest,
    xcode: capture.call('xcodebuild', '-version'), host: capture.call('sw_vers'),
    command: ['ruby', 'scripts/run-appkit-window-probe.rb'], app: app,
    limitations: 'Standalone AppKit comparison only; no UndoKit or simulator compositor qualification.'))
  abort 'Cannot launch probe' unless system('open', '-n', app, '--args', '--output', File.join(evidence, 'Fixture'))
end
puts "Probe launched. Use Window menu to switch editors, visit System Settings, return, and quit normally. Evidence: #{evidence}"
