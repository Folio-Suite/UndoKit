#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'digest'
require_relative 'build-support'

invocation = ARGV.dup
options = { configuration: 'Debug', device: nil, check: true }
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/run-durable-notes-uikit.rb [--device UDID] [--configuration Debug|Release] [--launch]'
  parser.on('--device UDID') { |value| options[:device] = value }
  parser.on('--configuration NAME', %w[Debug Release]) { |value| options[:configuration] = value }
  parser.on('--launch', 'Launch interactive sample instead of checks') { options[:check] = false }
end.parse!
abort 'Unexpected arguments' unless ARGV.empty?
abort 'Provide --device UDID from xcrun simctl list devices available' unless options[:device]
repository = File.expand_path('..', __dir__)
cache = UndoKitBuild.directory('UIKitNotes')
evidence = UndoKitBuild.directory('Evidence', 'UIKitNotes', "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
bundle_id = 'app.foliosuite.UndoKit.DurableNotesUIKit'
fixture = options[:check] ? File.basename(evidence) : 'Interactive'

def run!(arguments, log, environment = {})
  output, status = Open3.capture2e(environment, *arguments)
  File.open(log, 'a') { |file| file.puts(arguments.join(' ')); file.write(output) }
  raise "Command failed: #{arguments.join(' ')}; see #{log}" unless status.success?
  output
end

File.open(File.join(cache, '.runner.lock'), 'w') do |lock|
  abort 'Another UIKit Notes runner owns the shared cache' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
  project = File.join(repository, 'Examples', 'DurableNotes', 'UIKit', 'DurableNotesUIKit.xcodeproj')
  run!(['xcodebuild', '-project', project, '-scheme', 'DurableNotesUIKit', '-configuration', options[:configuration],
        '-sdk', 'iphonesimulator', '-destination', "id=#{options[:device]}", '-derivedDataPath', cache,
        'CODE_SIGN_IDENTITY=-', 'ONLY_ACTIVE_ARCH=YES', 'ALWAYS_SEARCH_USER_PATHS=NO', 'build'], File.join(evidence, 'Build.log'))
  app = File.join(cache, 'Build', 'Products', "#{options[:configuration]}-iphonesimulator", 'DurableNotesUIKit.app')
  install_log = File.join(evidence, 'InstalledClosure.log')
  executable = File.join(app, 'DurableNotesUIKit')
  commands = run!(['otool', '-l', executable], install_log)
  commands.scan(/cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset/).flatten.uniq.each do |path|
    next unless path.start_with?('/') && path != '/usr/lib/swift'
    run!(['install_name_tool', '-delete_rpath', path, executable], install_log)
  end
  embedded = File.join(app, 'Frameworks', 'UndoKit.framework')
  raise 'Embedded UndoKit runtime missing' unless File.file?(File.join(embedded, 'UndoKit'))
  run!(['codesign', '--force', '--sign', '-', '--timestamp=none', app], install_log)
  run!(['codesign', '--verify', '--deep', '--strict', app], install_log)
  source, = Open3.capture2('git', '-C', repository, 'rev-parse', 'HEAD')
  dirty, = Open3.capture2('git', '-C', repository, 'status', '--porcelain')
  xcode, = Open3.capture2('xcodebuild', '-version')
  swift, = Open3.capture2('swift', '--version')
  changed, = Open3.capture2('git', '-C', repository, 'ls-files', '--modified', '--others', '--exclude-standard')
  hashes = changed.lines.map(&:chomp).uniq.map do |path|
    full = File.join(repository, path)
    [path, Digest::SHA256.file(full).hexdigest] if File.file?(full)
  end.compact.to_h
  File.write(File.join(evidence, 'Setup.json'), JSON.pretty_generate(source: source.strip, dirty_paths: dirty.lines.map(&:chomp),
    changed_source_sha256: hashes, xcode: xcode.strip, swift: swift.strip, configuration: options[:configuration],
    simulator: options[:device], command: ['ruby', 'scripts/run-durable-notes-uikit.rb', *invocation],
    app: app, executable_sha256: Digest::SHA256.file(executable).hexdigest,
    undokit_sha256: Digest::SHA256.file(File.join(embedded, 'UndoKit')).hexdigest))
  simulation_log = File.join(evidence, 'Simulator.log')
  devices = JSON.parse(run!(['xcrun', 'simctl', 'list', 'devices', '--json'], simulation_log))
  device = devices.fetch('devices').values.flatten.find { |entry| entry['udid'] == options[:device] }
  raise 'Requested simulator is unavailable' unless device && device['isAvailable']
  run!(['xcrun', 'simctl', 'boot', options[:device]], simulation_log) unless device['state'] == 'Booted'
  run!(['xcrun', 'simctl', 'bootstatus', options[:device], '-b'], simulation_log)
  jobs = run!(['xcrun', 'simctl', 'spawn', options[:device], 'launchctl', 'list'], simulation_log)
  if options[:check] && jobs.lines.any? { |line| line.include?(bundle_id) && line.split.first.to_s.match?(/\A\d+\z/) }
    raise 'The sample is already running; finish its graceful close before starting a fresh check fixture'
  end
  run!(['xcrun', 'simctl', 'install', options[:device], app], simulation_log)
  run!(['xcrun', 'simctl', 'launch', options[:device], bundle_id], simulation_log,
    'SIMCTL_CHILD_UNDOKIT_UIKIT_FIXTURE' => fixture, 'SIMCTL_CHILD_UNDOKIT_UIKIT_CHECK' => options[:check] ? '1' : '0')
  if options[:check]
    container = run!(['xcrun', 'simctl', 'get_app_container', options[:device], bundle_id, 'data'], simulation_log).strip
    root = File.join(container, 'Library', 'Application Support', 'DurableNotesUIKit', fixture)
    deadline = Time.now + 180
    lifecycle_started = false
    until File.file?(File.join(root, 'Report.json'))
      if File.file?(File.join(root, 'Failure.txt'))
        FileUtils.cp_r(root, File.join(evidence, 'Fixture'))
        raise "Native checks failed: #{File.read(File.join(root, 'Failure.txt'))}; evidence #{evidence}"
      end
      if !lifecycle_started && File.file?(File.join(root, 'Stage.json'))
        stage = JSON.parse(File.read(File.join(root, 'Stage.json')))
        if stage['phase'] == 'background'
          lifecycle_started = true
          run!(['xcrun', 'simctl', 'launch', options[:device], 'com.apple.Preferences'], simulation_log)
          events = File.join(root, "Events-#{stage.fetch('scene')}.json")
          background_deadline = Time.now + 45
          prior_closures = stage.fetch('priorBackgroundClosures').to_i
          until File.file?(events) && JSON.parse(File.read(events)).count { |event| event == 'Outcome drained and store closed: background' } > prior_closures
            raise 'Real background store closure was not observed' if Time.now > background_deadline
            sleep 0.2
          end
          run!(['xcrun', 'simctl', 'launch', options[:device], bundle_id], simulation_log)
        end
      end
      raise "Native checks timed out; fixture retained at #{root}" if Time.now > deadline
      sleep 0.5
    end
    FileUtils.cp_r(root, File.join(evidence, 'Fixture'))
    puts "UIKit installed native checks passed: #{evidence}"
  else
    puts "Interactive UIKit app launched on #{options[:device]}: #{app}"
  end
end
