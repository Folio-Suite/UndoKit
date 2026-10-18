#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'time'
require 'digest'
require 'timeout'
require_relative 'build-support'

options = {configuration: 'Release', groups: 10_000, repetitions: 3, reopens: 10}
OptionParser.new do |parser|
  parser.banner = 'Usage: scripts/check-scale-simulator.rb --device UDID [--output NEW_DIRECTORY] (full simulator evidence: 3 x 10,000 groups + 10 fresh-process reopens)'
  parser.on('--device UDID') { |v| options[:device] = v }
  parser.on('--output PATH') { |v| options[:output] = File.expand_path(v) }
  parser.on('--configuration NAME', %w[Debug Release]) { |v| options[:configuration] = v }
  parser.on('--groups N', Integer) { |v| options[:groups] = v }
  parser.on('--repetitions N', Integer) { |v| options[:repetitions] = v }
  parser.on('--reopens N', Integer) { |v| options[:reopens] = v }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!
abort '--device UDID is required' unless options[:device]
abort 'Invalid simulator workload dimensions' unless (100..10_000).cover?(options[:groups]) && (1..3).cover?(options[:repetitions]) && (1..10).cover?(options[:reopens])
full = options.values_at(:groups, :repetitions, :reopens) == [10_000, 3, 10]
root = File.expand_path('..', __dir__)
scale = UndoKitBuild.directory('Scale')
lock = File.open(File.join(scale, 'simulator-run.lock'), File::RDWR | File::CREAT, 0o600)
abort 'Another simulator scale runner is active' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
build_lock = File.open(File.join(scale, 'device-build.lock'), File::RDWR | File::CREAT, 0o600)
build_lock.flock(File::LOCK_EX)
evidence = options[:output] || File.join(scale, "simulator-evidence-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}")
abort 'Evidence directory already exists; choose a fresh output path' if File.exist?(evidence)
FileUtils.mkdir_p(evidence)
report = {result: 'incomplete', capturedAtUTC: Time.now.utc.iso8601, device: options[:device], groups: options[:groups],
          repetitions: options[:repetitions], reopens: options[:reopens], profile: full ? 'simulator-full' : 'simulator-smoke', runs: []}
write = -> { File.write(File.join(evidence, 'RunnerReport.json'), JSON.pretty_generate(report) + "\n") }
write.call
allocated = lambda do |path|
  attempts = 0
  loop do
    out, errors, status = Open3.capture3({'LC_ALL' => 'C'}, 'du', '-sk', path)
    if status.success? && errors.empty?
      size_kib = Integer(out.split.first)
      break size_kib * 1024
    end
    transient_disappearance = !errors.empty? && errors.lines.all? do |line|
      line.chomp.end_with?(': No such file or directory')
    end
    raise "Cannot inventory #{path}: #{errors.empty? ? out : errors}" unless transient_disappearance
    attempts += 1
    raise "Cannot inventory #{path} after #{attempts} attempts: #{errors}" if attempts >= 3
    sleep 0.05
  end
end
free = ->(path) { out, status = Open3.capture2e('df', '-k', path); raise "Cannot inspect free space: #{out}" unless status.success?; Integer(out.lines.last.split[3]) * 1024 }
run = lambda do |*cmd, allow_failure: false|
  output = +' '
  status = nil
  Open3.popen2e(*cmd, pgroup: true) do |_stdin, stream, wait|
    reader = Thread.new { stream.each_line { |line| output << line } rescue IOError }
    reader.report_on_exception = false
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
    begin
      loop do
        if wait.join(0.2)
          status = wait.value
          break
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "Command timed out after 900 seconds: #{cmd.inspect}"
        end
        owned_cache = allocated.call(UndoKitBuild.directory('Scale'))
        owned_cache += allocated.call(evidence) unless evidence.start_with?(UndoKitBuild.directory('Scale') + File::SEPARATOR)
        raise 'Xcode build/evidence cache exceeds 12 GiB guard' if owned_cache > 12 * 1024**3
        raise 'Host free space below 20 GiB guard' if free.call(evidence) < 20 * 1024**3
      end
    rescue StandardError, Interrupt
      Process.kill('TERM', -wait.pid) rescue nil
      sleep 0.2
      Process.kill('KILL', -wait.pid) rescue nil
      raise
    ensure
      reader.join
    end
  end
  raise "#{cmd.inspect} failed: #{output}" unless status.success? || allow_failure
  allow_failure ? [output.strip, status] : output.strip
end
bundle = 'org.foliosuite.undokit.scale'
active_pid = nil
booted_by_runner = false
begin
  owned_cache = allocated.call(UndoKitBuild.directory('Scale'))
  owned_cache += allocated.call(evidence) unless evidence.start_with?(UndoKitBuild.directory('Scale') + File::SEPARATOR)
  raise 'Xcode build/evidence cache exceeds 12 GiB guard' if owned_cache > 12 * 1024**3
  raise 'Host free space below 20 GiB guard' if free.call(evidence) < 20 * 1024**3
  booted = run.call('xcrun', 'simctl', 'list', 'devices', 'booted', '-j')
  booted_ids = JSON.parse(booted).fetch('devices').values.flatten.map { |d| d['udid'] }
  raise 'Refusing when another simulator is booted' unless booted_ids.empty? || booted_ids == [options[:device]]
  devices = JSON.parse(run.call('xcrun', 'simctl', 'list', 'devices', '-j')).fetch('devices').values.flatten
  device = devices.find { |d| d['udid'] == options[:device] }
  raise 'Selected simulator UDID was not found' unless device
  raise 'Selected simulator has unsupported state' unless %w[Booted Shutdown].include?(device['state'])
  initially_booted = device['state'] == 'Booted'
  if !initially_booted
    run.call('xcrun', 'simctl', 'boot', options[:device])
    booted_by_runner = true
    run.call('xcrun', 'simctl', 'bootstatus', options[:device], '-b')
  end
  runtime_key = JSON.parse(run.call('xcrun', 'simctl', 'list', 'devices', '-j')).fetch('devices').find { |_runtime, rows| rows.any? { |row| row['udid'] == options[:device] } }.first
  runtimes = JSON.parse(run.call('xcrun', 'simctl', 'list', 'runtimes', '-j')).fetch('runtimes')
  runtime = runtimes.find { |entry| entry.fetch('identifier') == runtime_key }
  raise 'Exact simulator runtime version/build unavailable' unless runtime && runtime['version'] && runtime['buildversion']
  report[:runtime] = {runtime: runtime, device: device}
  toolchain = run.call('xcodebuild', '-version')
  raise 'Pinned Xcode 27.1 (27A9275) is required' unless toolchain.match?(/\AXcode 27\.1\nBuild version 27A9275\s*\z/)
  swift = run.call('swift', '--version')
  raise 'Pinned Apple Swift 6.4 is required' unless swift.include?('Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)')
  ENV['UNDOKIT_SCALE_DEVICE_BUILD_LOCK_HELD'] = '1'
  build_output = run.call('ruby', File.join(__dir__, 'build-scale-device.rb'), '--sdk', 'iphonesimulator', '--profile', full ? 'simulator-full' : 'smoke', '--configuration', options[:configuration])
  report[:buildOutput] = build_output
  build_root = UndoKitBuild.directory('Scale', 'DeviceProject')
  manifest_path = File.join(build_root, 'BuildManifest.json')
  manifest = JSON.parse(File.read(manifest_path))
  app = File.join(UndoKitBuild.directory('Scale', 'DeviceBuild'), 'Build', 'Products', "#{options[:configuration]}-iphonesimulator", 'ScaleDevice.app')
  raise 'Build did not produce ScaleDevice.app' unless File.directory?(app) && manifest['buildSucceeded']
  FileUtils.cp_r(app, File.join(evidence, 'ScaleDevice.app'))
  evidence_manifest = File.join(evidence, 'BuildManifest.json')
  FileUtils.cp(manifest_path, evidence_manifest)
  manifest_path = evidence_manifest
  report[:buildManifest] = manifest_path
  report[:buildManifestSHA256] = Digest::SHA256.file(manifest_path).hexdigest
  existing_container, existing_status = run.call('xcrun', 'simctl', 'get_app_container', options[:device], bundle, 'data', allow_failure: true)
  if existing_status.success?
    existing_fixtures = File.join(existing_container.strip, 'Library', 'Application Support', 'UndoKitScaleEvidence')
    raise 'Refusing pre-existing simulator fixture evidence; no app data is removed' if File.exist?(existing_fixtures)
  end
  running = run.call('xcrun', 'simctl', 'spawn', options[:device], 'launchctl', 'list')
  raise 'Refusing to replace an already-running scale app' if running.include?(bundle)
  run.call('xcrun', 'simctl', 'install', options[:device], app)
  container = run.call('xcrun', 'simctl', 'get_app_container', options[:device], bundle, 'data')
  fixture_root = File.join(container, 'Library', 'Application Support', 'UndoKitScaleEvidence')
  installed_app = run.call('xcrun', 'simctl', 'get_app_container', options[:device], bundle, 'app')
  installed_inventory = Dir.glob(File.join(installed_app, '**/*'), File::FNM_DOTMATCH).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(installed_app + '/'), Digest::SHA256.file(p).hexdigest] }
  raise 'Installed simulator app identity differs from exact build manifest' unless installed_inventory == manifest.fetch('artifactSHA256')
  observed_pids = []
  options[:repetitions].times do |rep|
    seed = 11 + rep
    fixture = File.join(fixture_root, "seed-#{seed}")
    base = {seed: seed, phase: 'create', pids: [], samples: []}
    report[:runs] << base; write.call
    launch = lambda do |operation, sample|
      args = ['xcrun', 'simctl', 'launch', options[:device], bundle, '--scale-profile', full ? 'simulator-full' : 'smoke', '--scale-operation', operation, '--scale-seed', seed.to_s, '--scale-groups', options[:groups].to_s, '--scale-sample', sample.to_s]
      pid = Integer(run.call(*args).scan(/: (\d+)/).last.first)
      raise 'Fresh app launch PID repeated' if base[:pids].include?(pid)
      active_pid = pid
      base[:pids] << pid
      raise 'App process ID was reused across evidence samples' if observed_pids.include?(pid)
      observed_pids << pid
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 900
      expected = operation == 'create' ? File.join(fixture, 'WorkloadReport.json') : File.join(fixture, "Reopen-#{sample}.json")
      loop do
        if system('kill', '-0', pid.to_s, out: File::NULL, err: File::NULL)
          rss_text = run.call('ps', '-p', pid.to_s, '-o', 'rss=')
          base[:peakRSSBytes] = [base.fetch(:peakRSSBytes, 0), Integer(rss_text) * 1024].max unless rss_text.empty?
          raise 'Launched app exceeded 2 GiB RSS budget' if base[:peakRSSBytes] > 2 * 1024**3
        end
        failures = Dir.glob(File.join(fixture, 'Failure-*.json'))
        raise "App recorded failure: #{File.read(failures.first)}" unless failures.empty?
        raise 'Simulator operation exceeded 900 seconds' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        raise 'Host free space below 20 GiB guard' if free.call(evidence) < 20 * 1024**3
        raise 'Evidence + installed app exceeded 2 GiB guard' if (File.exist?(fixture_root) ? allocated.call(fixture_root) : 0) + allocated.call(installed_app) > 2 * 1024**3
        owned_cache = allocated.call(scale)
        owned_cache += allocated.call(evidence) unless evidence.start_with?(scale + File::SEPARATOR)
        raise 'Xcode build/evidence cache exceeds 12 GiB guard' if owned_cache > 12 * 1024**3
        break if File.file?(expected)
        raise 'Launched simulator process exited before writing its report' unless system('kill', '-0', pid.to_s, out: File::NULL, err: File::NULL)
        sleep 1
      end
      sample_report = JSON.parse(File.read(expected))
      raise 'Reported process ID differs from launched simulator PID' unless sample_report.fetch('processID') == pid
      rss_kib = Integer(run.call('ps', '-p', pid.to_s, '-o', 'rss='))
      base[:peakRSSBytes] = [base.fetch(:peakRSSBytes, 0), rss_kib * 1024].max
      raise 'Launched app exceeded 2 GiB RSS budget' if base[:peakRSSBytes] > 2 * 1024**3
      run.call('xcrun', 'simctl', 'terminate', options[:device], bundle)
      active_pid = nil
      pid
    end
    launch.call('create', 0)
    (1..options[:reopens]).each do |sample|
      base[:phase] = "reopen-#{sample}"; write.call
      base[:samples] << launch.call('reopen', sample)
    end
    report[:runs].last[:phase] = 'completed'; write.call
    FileUtils.cp_r(fixture, File.join(evidence, "seed-#{seed}"))
  end
  if full
    report[:result] = 'validating'; write.call
    checked = run.call('ruby', File.join(__dir__, 'check-scale-device-evidence.rb'), '--simulator-evidence', evidence, '--build-manifest', manifest_path)
    JSON.parse(checked).tap { |result| raise "Simulator checker rejected evidence: #{result.fetch('failure', result.fetch('result'))}" unless result.fetch('result') == 'simulator_evidence_complete_for_review' }
    report[:checkerResult] = 'simulator_evidence_complete_for_review'
  end
  report[:result] = full ? 'simulator_full_completed' : 'simulator_smoke_completed'
rescue StandardError, Interrupt => error
  report[:result] = 'failed'; report[:failure] = "#{error.class}: #{error.message}"
ensure
  if active_pid
    Open3.capture2e('xcrun', 'simctl', 'terminate', options[:device], bundle) rescue nil
  end
  if booted_by_runner
    Open3.capture2e('xcrun', 'simctl', 'shutdown', options[:device]) rescue nil
  end
  build_lock.close if build_lock && !build_lock.closed?
  lock.close if lock && !lock.closed?
  write.call
  puts "Result: #{report[:result]}; evidence: #{File.join(evidence, 'RunnerReport.json')}"
end
exit(report[:result] == 'failed' ? 1 : 0)
