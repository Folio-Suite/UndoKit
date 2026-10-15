#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'

options = { configuration: 'Debug', check: true }
invocation = ARGV.dup
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/run-durable-notes-swiftui-ios.rb --device UDID [--configuration Debug|Release] [--launch]'
  parser.on('--device UDID') { |value| options[:device] = value }
  parser.on('--configuration NAME', %w[Debug Release]) { |value| options[:configuration] = value }
  parser.on('--launch', 'Launch the interactive host instead of checks') { options[:check] = false }
end.parse!
abort 'Supply --device and no positional arguments' unless options[:device] && ARGV.empty?

repository = File.expand_path('..', __dir__)
project = File.join(repository, 'Examples/DurableNotes/SwiftUI/DurableNotesSwiftUI.xcodeproj')
fixture = options[:check] ? "Check-#{SecureRandom.uuid}" : 'Interactive'
evidence = File.join(repository, 'build/Evidence/SwiftUI', "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
FileUtils.mkdir_p(evidence)
log = File.join(evidence, 'Run.log')
bundle = 'app.foliosuite.UndoKit.DurableNotesSwiftUI'

def run!(command, log, environment = {})
  output, status = Open3.capture2e(environment, *command)
  File.open(log, 'a') { |file| file.puts(command.join(' ')); file.write(output) }
  raise "Command failed (#{status.exitstatus}): #{command.join(' ')}; see #{log}" unless status.success?
  output
end

booted_here = false
begin
  devices = JSON.parse(run!(['xcrun', 'simctl', 'list', 'devices', '--json'], log)).fetch('devices')
  selected = devices.values.flatten.find { |device| device['udid'] == options[:device] && device['isAvailable'] }
  raise 'Requested simulator is unavailable' unless selected
  others = devices.values.flatten.select { |device| device['state'] == 'Booted' && device['udid'] != options[:device] }
  raise 'Shut down other simulators before running this check' unless others.empty?

  common = ['xcodebuild', '-project', project, '-scheme', 'DurableNotesSwiftUI',
            '-configuration', options[:configuration], '-destination', "id=#{options[:device]}",
            'CODE_SIGN_IDENTITY=-', 'ONLY_ACTIVE_ARCH=YES']
  # Let Xcode resolve its configured default DerivedData; no custom build cache.
  run!([*common, 'build'], log)
  settings = JSON.parse(run!([*common, '-showBuildSettings', '-json'], log))
    .find { |target| target['target'] == 'DurableNotesSwiftUI' }.fetch('buildSettings')
  built_app = File.join(settings.fetch('TARGET_BUILD_DIR'), settings.fetch('FULL_PRODUCT_NAME'))
  app = File.join(evidence, 'Installed.app')
  FileUtils.cp_r(built_app, app)
  executable = File.join(app, settings.fetch('EXECUTABLE_NAME'))
  library = File.join(app, 'Frameworks/UndoKit.framework/UndoKit')
  raise 'Embedded UndoKit runtime is missing' unless File.file?(library)
  load_commands = run!(['otool', '-l', executable], log)
  load_commands.scan(/cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset/).flatten.uniq.each do |path|
    next unless path.start_with?('/') && path != '/usr/lib/swift'
    run!(['install_name_tool', '-delete_rpath', path, executable], log)
  end
  run!(['codesign', '--force', '--sign', '-', '--timestamp=none', app], log)
  run!(['codesign', '--verify', '--deep', '--strict', app], log)
  raise 'Installed compiled history model is missing' if Dir.glob(File.join(app, '**/History.momd/*.mom')).empty?
  raise 'Installed privacy manifest is missing' if Dir.glob(File.join(app, '**/PrivacyInfo.xcprivacy')).empty?

  changed = run!(['git', '-C', repository, 'ls-files', '-z', '--modified', '--others', '--exclude-standard'], log)
  hashes = changed.split("\0").uniq.each_with_object({}) do |path, result|
    full = File.join(repository, path)
    result[path] = Digest::SHA256.file(full).hexdigest if File.file?(full)
  end
  setup = {
    source: run!(['git', '-C', repository, 'rev-parse', 'HEAD'], log).strip,
    changed_source_sha256: hashes, configuration: options[:configuration],
    xcode: run!(['xcodebuild', '-version'], log).strip,
    swift: run!(['swift', '--version'], log).strip,
    simulator: selected, command: ['ruby', 'scripts/run-durable-notes-swiftui-ios.rb', *invocation],
    app: app, executable_sha256: Digest::SHA256.file(executable).hexdigest,
    undokit_sha256: Digest::SHA256.file(library).hexdigest,
    build_directory: settings.fetch('TARGET_BUILD_DIR')
  }
  File.write(File.join(evidence, 'Setup.json'), JSON.pretty_generate(setup))

  if selected['state'] != 'Booted'
    run!(['xcrun', 'simctl', 'boot', options[:device]], log)
    booted_here = true
  end
  run!(['xcrun', 'simctl', 'bootstatus', options[:device], '-b'], log)
  jobs = run!(['xcrun', 'simctl', 'spawn', options[:device], 'launchctl', 'list'], log)
  if jobs.lines.any? { |line| line.include?(bundle) && line.split.first.to_s.match?(/\A\d+\z/) }
    raise 'Close the running SwiftUI sample gracefully before starting another run'
  end
  run!(['xcrun', 'simctl', 'install', options[:device], app], log)
  run!(['xcrun', 'simctl', 'launch', options[:device], bundle], log,
       'SIMCTL_CHILD_UNDOKIT_SWIFTUI_FIXTURE' => fixture,
       'SIMCTL_CHILD_UNDOKIT_SWIFTUI_CHECK' => options[:check] ? '1' : '0')
  if options[:check]
    container = run!(['xcrun', 'simctl', 'get_app_container', options[:device], bundle, 'data'], log).strip
    root = File.join(container, 'Library/Application Support/DurableNotesSwiftUI', fixture)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 180
    background_started = false
    until File.file?(File.join(root, 'Report.json'))
      raise "Installed checks failed: #{File.read(File.join(root, 'Failure.txt'))}" if File.file?(File.join(root, 'Failure.txt'))
      stage = File.join(root, 'Stage.json')
      if !background_started && File.file?(stage) && JSON.parse(File.read(stage))['phase'] == 'background'
        background_started = true
        run!(['xcrun', 'simctl', 'launch', options[:device], 'com.apple.Preferences'], log)
        closure_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 45
        until File.file?(File.join(root, 'BackgroundClosed.json'))
          raise 'Actual background closure was not observed' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > closure_deadline
          sleep 0.2
        end
        run!(['xcrun', 'simctl', 'launch', options[:device], bundle], log)
      end
      raise "Installed checks timed out: #{root}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.2
    end
    FileUtils.cp_r(root, File.join(evidence, 'Fixture'))
    report = JSON.parse(File.read(File.join(root, 'Report.json')))
    # Verify authoritative bytes outside the process that exercised the binding.
    note_path = File.join(root, report.fetch('sceneID'), 'Note.json')
    state = JSON.parse(File.read(note_path))
    raise 'Independent note readback differs' unless state.fetch('note') == report.fetch('finalNote')
    raise 'Independent receipt count differs' unless state.fetch('receipts').length == report.fetch('receiptCount')
    raise 'Independent application count differs' unless state.fetch('applicationCount') == report.fetch('applicationCount')
    File.write(File.join(evidence, 'IndependentReadback.json'), JSON.pretty_generate(state))
    puts "Installed SwiftUI checks and independent receipt readback passed: #{evidence}"
  else
    puts "Interactive SwiftUI host launched: #{app}"
  end
rescue StandardError => error
  if defined?(root) && root && File.directory?(root) && !File.exist?(File.join(evidence, 'Fixture'))
    FileUtils.cp_r(root, File.join(evidence, 'Fixture'))
  end
  warn "#{error.message}\nEvidence retained: #{evidence}"
  exit 1
ensure
  if booted_here && options[:check]
    run!(['xcrun', 'simctl', 'shutdown', options[:device]], log)
  end
end
