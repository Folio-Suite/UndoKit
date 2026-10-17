#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'digest'
require 'timeout'
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

def run!(arguments, log, environment = {}, timeout: nil)
  output = nil; status = nil
  if timeout
    raise 'External transition command exceeded its deadline' unless timeout.positive?
    Open3.popen2e(environment, *arguments, pgroup: true) do |input, stream, process|
      input.close
      reader = Thread.new { stream.read }
      finished = false
      begin
        Timeout.timeout(timeout) { status = process.value; output = reader.value; finished = true }
      rescue Timeout::Error
        raise 'External transition command exceeded its deadline'
      ensure
        unless finished
          begin
            Process.kill('KILL', -process.pid)
          rescue Errno::ESRCH
            # The command already exited.
          end
          process.join
        end
        reader.join
        output ||= reader.value
        File.open(log, 'a') { |file| file.puts(arguments.join(' ')); file.write(output) }
      end
    end
  else
    output, status = Open3.capture2e(environment, *arguments)
    File.open(log, 'a') { |file| file.puts(arguments.join(' ')); file.write(output) }
  end
  raise "Command failed: #{arguments.join(' ')}; see #{log}" unless status.success?
  output
end

def foreground_check(device, bundle_id, process_id, log, timeout)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  jobs = run!(['xcrun', 'simctl', 'spawn', device, 'launchctl', 'list'], log, {}, timeout: timeout)
  running = jobs.lines.any? { |line| line.include?(bundle_id) && line.split.first == process_id.to_s }
  raise 'Original installed check process exited; refusing fixture restart' unless running
  remaining = timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  run!(['xcrun', 'simctl', 'launch', device, bundle_id], log, {}, timeout: remaining)
end

# Files are an explicit check-only handshake, never a substitute for UIKit state.
def write_authorization(path, value)
  raise "Refusing existing transition authorization: #{path}" if File.exist?(path)
  File.write(path + '.tmp', JSON.pretty_generate(value))
  File.rename(path + '.tmp', path)
end

def check_uikit_fixture(root, fixture, process_id, device, bundle_id, log)
  now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  deadline = now.call + 180
  bootstrap_deadline = now.call + 30
  requests = {}
  completed = []
  loop do
    raise 'Native checks timed out' if now.call > deadline
    failure = File.join(root, 'Failure.txt')
    raise "Native checks failed: #{File.read(failure)}" if File.file?(failure)
    bootstrap_path = File.join(root, 'Bootstrap.json')
    unless File.file?(bootstrap_path)
      raise 'Installed app did not confirm the requested fixture/check bootstrap' if now.call > bootstrap_deadline
      sleep 0.1
      next
    end
    bootstrap = JSON.parse(File.read(bootstrap_path))
    unless bootstrap == {'version' => 1, 'fixture' => fixture, 'check' => true,
                         'bundleIdentifier' => bundle_id, 'processID' => process_id}
      raise 'Installed check bootstrap does not match launch identity'
    end
    directories = Dir.glob(File.join(root, 'Transitions', '*')).sort_by do |directory|
      path = File.join(directory, 'Request.json')
      File.file?(path) ? JSON.parse(File.read(path)).fetch('sequence', 0).to_i : 0
    end
    directories.each do |directory|
      request_path = File.join(directory, 'Request.json')
      unless File.file?(request_path)
        raise 'Orphan transition authorization without request' if %w[Dispatch.json Foreground.json Complete.json Status.json].any? { |name| File.exist?(File.join(directory, name)) }
        next
      end
      request = JSON.parse(File.read(request_path))
      id = request['id']
      unless request.keys.sort == %w[action fixture id priorBackgroundClosures priorBackgroundEvents priorSceneIDs sceneID sequence version].sort &&
             request['version'] == 1 && request['fixture'] == fixture && id == File.basename(directory) &&
             id.is_a?(String) && id.match?(/\A[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\z/) &&
             request['sequence'].is_a?(Integer) && request['sequence'].positive? &&
             %w[start create activate background].include?(request['action']) && request['sceneID'].is_a?(String) &&
             (request['action'] == 'create' ? request['sceneID'].empty? : !request['sceneID'].empty?) &&
             request['priorSceneIDs'].is_a?(Array) && request['priorSceneIDs'].all? { |value| value.is_a?(String) } &&
             request['priorSceneIDs'].uniq == request['priorSceneIDs'] && request['priorBackgroundClosures'].is_a?(Integer) && request['priorBackgroundClosures'] >= 0 &&
             request['priorBackgroundEvents'].is_a?(Integer) && request['priorBackgroundEvents'] >= 0 &&
             request['sceneID'].match?(/\A[A-Za-z0-9-]*\z/)
        raise 'Malformed or uncorrelated transition request'
      end
      state = requests[id]
      if state
        raise 'Transition request changed after dispatch' unless state[:request] == request
        next if completed.include?(id)
      else
        raise 'Overlapping or out-of-order transition request' unless completed.length == requests.length && request['sequence'] == requests.length + 1
        raise 'Orphan transition authorization before dispatch' if %w[Dispatch.json Foreground.json Complete.json].any? { |name| File.exist?(File.join(directory, name)) }
        state = {request: request, deadline: now.call + 30, recovery: false, settings: false, ready_observation: nil}
        requests[id] = state
        write_authorization(File.join(directory, 'Dispatch.json'), request: request, command: 'dispatch')
      end
      raise "External #{request['action']} transition timed out" if now.call > state[:deadline]
      status_path = File.join(directory, 'Status.json')
      next unless File.file?(status_path)
      status = JSON.parse(File.read(status_path))
      unless status['request'] == request && status['observation'].is_a?(Integer) && status['observation'].positive? &&
             %w[waiting dispatched ready completed error].include?(status['phase']) && %w[active inactive background].include?(status['applicationState'])
        raise 'Uncorrelated or malformed transition status'
      end
      raise 'Transition observation moved backwards' if state[:last_observation] && status['observation'] < state[:last_observation]
      state[:last_observation] = status['observation']
      raise "UIKit transition refused: #{status['error']}" if status['phase'] == 'error' || status['error']
      if request['action'] == 'background' && !state[:settings] && status['phase'] == 'dispatched'
        state[:settings] = true
        state[:background_deadline] = now.call + 45
        run!(['xcrun', 'simctl', 'launch', device, 'com.apple.Preferences'], log, {}, timeout: [state[:deadline], deadline].min - now.call)
      end
      if state[:settings] && !state[:returned]
        events_path = File.join(root, "Events-#{request.fetch('sceneID')}.json")
        events = File.file?(events_path) ? JSON.parse(File.read(events_path)) : []
        closed = events.count('Outcome drained and store closed: background') > request['priorBackgroundClosures'] &&
          events.count('UIKit scene entered background') > request['priorBackgroundEvents']
        raise 'Real background store closure was not observed' if now.call > state[:background_deadline]
        if closed
          state[:returned] = true
          state[:ready_observation] = nil; state[:after_recovery_observation] = status['observation']
          write_authorization(File.join(directory, 'Foreground.json'), request: request, command: 'foreground')
          foreground_check(device, bundle_id, process_id, log, [state[:deadline], deadline].min - now.call)
        end
        next
      end
      state[:inactive_since] = status['applicationState'] == 'active' ? nil : state[:inactive_since] || now.call
      if !state[:recovery] && request['action'] != 'background' && state[:inactive_since] &&
         (status['applicationState'] == 'background' || now.call - state[:inactive_since] >= 1)
        state[:recovery] = true
        state[:ready_observation] = nil; state[:after_recovery_observation] = status['observation']
        foreground_check(device, bundle_id, process_id, log, [state[:deadline], deadline].min - now.call)
        next
      end
      ready = (!state[:after_recovery_observation] || status['observation'] > state[:after_recovery_observation]) && status['applicationState'] == 'active' && status['foregroundActive'] == true &&
        status['presentationReady'] == true && status['currentOwner'] == true && status['sceneID'].is_a?(String) && !status['sceneID'].empty? &&
        (request['action'] == 'create' ? !request['priorSceneIDs'].include?(status['sceneID']) : status['sceneID'] == request['sceneID']) &&
        (request['action'] != 'background' || state[:returned] && status['backgroundClosures'].is_a?(Integer) && status['backgroundClosures'] > request['priorBackgroundClosures'] &&
          status['backgroundEvents'].is_a?(Integer) && status['backgroundEvents'] > request['priorBackgroundEvents'])
      if status['phase'] == 'completed'
        raise 'App completed without correlated runner readiness approval' unless state[:approved] && ready && status['sceneID'] == state[:approved_scene]
        completed << id
      elsif status['phase'] == 'ready' && ready
        if !state[:approved] && state[:ready_observation] && status['observation'] > state[:ready_observation] && state[:ready_scene] == status['sceneID']
          write_authorization(File.join(directory, 'Complete.json'), request: request, command: 'complete', sceneID: status['sceneID'])
          state[:approved] = true; state[:approved_scene] = status['sceneID']
        end
        state[:ready_observation] = status['observation']; state[:ready_scene] = status['sceneID']
      else
        state[:ready_observation] = nil
      end
    end
    report_path = File.join(root, 'Report.json')
    if File.file?(report_path)
      report = JSON.parse(File.read(report_path))
      raise 'Incomplete external scene-transition evidence' unless !completed.empty? && completed.length == requests.length && report['transitionIDs'] == completed
      return
    end
    sleep 0.1
  end
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
  container = run!(['xcrun', 'simctl', 'get_app_container', options[:device], bundle_id, 'data'], simulation_log).strip
  root = File.join(container, 'Library', 'Application Support', 'DurableNotesUIKit', fixture)
  raise 'Refusing pre-existing check fixture' if options[:check] && File.exist?(root)
  arguments = ['xcrun', 'simctl', 'launch', options[:device], bundle_id]
  arguments += ['--undokit-uikit-check', '--undokit-uikit-fixture', fixture] if options[:check]
  launch = run!(arguments, simulation_log,
    'SIMCTL_CHILD_UNDOKIT_UIKIT_FIXTURE' => fixture, 'SIMCTL_CHILD_UNDOKIT_UIKIT_CHECK' => options[:check] ? '1' : '0')
  if options[:check]
    begin
      process_id = Integer(launch.match(/#{Regexp.escape(bundle_id)}: (\d+)/)&.captures&.first || raise('Missing launched app PID'))
      check_uikit_fixture(root, fixture, process_id, options[:device], bundle_id, simulation_log)
    ensure
      FileUtils.cp_r(root, File.join(evidence, 'Fixture')) if File.directory?(root)
    end
    puts "UIKit installed native checks passed: #{evidence}"
  else
    puts "Interactive UIKit app launched on #{options[:device]}: #{app}"
  end
end
