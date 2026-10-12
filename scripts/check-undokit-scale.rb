#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'tmpdir'
require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'digest'
require 'time'
require_relative 'build-support'

options = {groups: 10_000, seed: 11, repetitions: 3, reopens: 10, configuration: 'Release',
           seconds: 600.0, rss: 2 * 1024**3, disk: 12 * 1024**3, free: 20 * 1024**3}
OptionParser.new do |parser|
  parser.banner = 'Usage: scripts/check-undokit-scale.rb [options] (Mac production default: 3 x 10,000 + 10 fresh reopen samples each)'
  parser.on('--groups N', Integer) { |v| options[:groups] = v }
  parser.on('--seed N', Integer) { |v| options[:seed] = v }
  parser.on('--repetitions N', Integer) { |v| options[:repetitions] = v }
  parser.on('--reopens N', Integer) { |v| options[:reopens] = v }
  parser.on('--configuration NAME', %w[Debug Release]) { |v| options[:configuration] = v }
  parser.on('--output PATH') { |v| options[:output] = File.expand_path(v) }
  # Only lowered guards are accepted here; larger experimental budgets need a deliberate code/contract review.
  parser.on('--max-seconds N', Float) { |v| options[:seconds] = v }
  parser.on('--max-rss-bytes N', Integer) { |v| options[:rss] = v }
  parser.on('--max-owned-bytes N', Integer) { |v| options[:disk] = v }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!
options[:groups] = Integer(ARGV.shift) unless ARGV.empty? # preserve the original positional group invocation
abort 'Unexpected arguments' unless ARGV.empty?
abort 'Groups must be 100..100000, seed 1..9990, repetitions 1..3, reopens 1..10' unless
  (100..100_000).cover?(options[:groups]) && (1..9990).cover?(options[:seed]) &&
  (1..3).cover?(options[:repetitions]) && (1..10).cover?(options[:reopens])
abort 'Guard overrides must be positive and at or below the Mac defaults' unless
  options[:seconds].positive? && options[:seconds] <= 600 && options[:rss].positive? && options[:rss] <= 2 * 1024**3 &&
  options[:disk].positive? && options[:disk] <= 12 * 1024**3

ROOT = File.expand_path('..', __dir__)
def output(*command)
  value, status = Open3.capture2e(*command)
  raise "Command failed: #{command.inspect}: #{value}" unless status.success?
  value
end
def allocated(path)
  return 0 unless File.exist?(path)
  value, errors, status = Open3.capture3('du', '-sk', path)
  # Compilers atomically replace short-lived .tmp files during this sampled walk.
  # A vanished file contributes no remaining allocation; permission/I/O errors
  # still refuse the measurement instead of quietly omitting owned material.
  vanished = !errors.empty? && errors.lines.all? { |line| line.include?('No such file or directory') }
  raise "Disk inventory failed for #{path}: #{errors}" unless status.success? || vanished
  Integer(value.split.first) * 1024
end
def free_bytes(path)
  Integer(output('df', '-k', path).lines.last.split[3]) * 1024
end
def combined_rss(pid)
  rows = output('ps', '-axo', 'pid=,ppid=,rss=').lines.map { |line| line.split.map(&:to_i) }
  descendants = [pid]
  loop do
    children = rows.select { |id, parent, _| descendants.include?(parent) && !descendants.include?(id) }.map(&:first)
    break if children.empty?
    descendants.concat(children)
  end
  rows.select { |id, _, _| descendants.include?(id) }.sum { |_, _, memory| memory * 1024 }
end
def persist(report, directory)
  File.write(File.join(directory, 'report.json'), JSON.pretty_generate(report) + "\n")
end
def distribution(samples, key)
  values = samples.map { |sample| sample.fetch(key) }.sort
  percentile = ->(fraction) { values[[values.length - 1, (values.length * fraction).ceil - 1].min] }
  {'count' => values.length, 'p50' => percentile.call(0.5), 'p95' => percentile.call(0.95),
   'p99' => percentile.call(0.99), 'maximum' => values.last,
   'outliers' => samples.each_with_index.sort_by { |sample, _| -sample.fetch(key) }.map { |sample, index| {'sample' => index + 1, 'seconds' => sample.fetch(key)} }}
end
def guarded(command, options, evidence, cache, record, log, deadline)
  FileUtils.mkdir_p(File.dirname(log))
  pid = Process.spawn(*command, out: log, err: log, pgroup: true)
  status = nil
  begin
    loop do
      rss = combined_rss(Process.pid)
      disk = allocated(evidence) + allocated(cache)
      record['peakCombinedRSSBytes'] = [record.fetch('peakCombinedRSSBytes', 0), rss].max
      record['peakFullOwnedAllocatedBytes'] = [record.fetch('peakFullOwnedAllocatedBytes', 0), disk].max
      record['peakEvidenceAllocatedBytes'] = [record.fetch('peakEvidenceAllocatedBytes', 0), allocated(evidence)].max
      record['peakSharedPackageCacheAllocatedBytes'] = [record.fetch('peakSharedPackageCacheAllocatedBytes', 0), allocated(cache)].max
      raise 'Ten-minute case budget exceeded (or predeclared lowered guard)' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      raise 'Combined runner + descendant RSS budget exceeded' if rss > options[:rss]
      raise 'Full owned footprint (evidence + shared package cache) budget exceeded' if disk > options[:disk]
      raise 'Remaining free disk below 20 GiB' if free_bytes(evidence) < options[:free] || free_bytes(cache) < options[:free]
      pair = Process.waitpid2(pid, Process::WNOHANG)
      if pair
        status = pair.last
        raise "Command failed (#{status.exitstatus}); see #{log}" unless status.success?
        break
      end
      sleep 0.2
    end
  ensure
    unless status
      begin
        Process.kill('KILL', -pid); Process.waitpid(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end

# Both the heavy fixture and shared package build database have stable, cross-checkout locks.
scale_parent = UndoKitBuild.directory('Scale')
lock = File.open(File.join(scale_parent, 'run.lock'), File::RDWR | File::CREAT, 0o600)
abort 'Another scale runner is active' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
cache = UndoKitBuild.directory('Package')
directory = options[:output] || Dir.mktmpdir('evidence-', scale_parent)
FileUtils.mkdir_p(directory)
abort 'Output already contains a scale report; choose a new evidence directory' if File.exist?(File.join(directory, 'report.json'))
report = {'capturedAtUTC' => Time.now.utc.iso8601, 'result' => 'incomplete', 'options' => options,
          'budgetsDeclaredBeforeBuild' => true, 'runs' => [], 'evidenceDirectory' => directory,
          'sharedBuildCache' => cache, 'footprintAccounting' => 'all allocated evidence files, logs, host receipts/resources, History.sqlite/WAL/SHM plus entire reused Package build cache; components reported separately',
          'sourceHead' => output('git', '-C', ROOT, 'rev-parse', 'HEAD').strip,
          'sourceDirtyPaths' => output('git', '-C', ROOT, 'status', '--short', '--untracked-files=all').lines.map(&:strip),
          'hardware' => output('sysctl', '-n', 'hw.model').strip, 'architecture' => output('uname', '-m').strip,
          'physicalMemoryBytes' => Integer(output('sysctl', '-n', 'hw.memsize').strip),
          'os' => output('sw_vers').strip, 'toolchain' => output('xcodebuild', '-version').strip,
          'swift' => output('swift', '--version').strip, 'configuration' => options[:configuration],
          'limitations' => ['Fresh processes do not establish cold filesystem cache or abrupt-termination recovery.',
                            'Main-actor heartbeat measures scheduling; physical/native interaction observations remain separate.',
                            'Mac source-package evidence does not qualify physical iOS, Intel, floor OS or binary distribution.']}
source_files = Dir.glob(File.join(ROOT, '{UndoKit,scripts/scale}/**/*')).select { |p| File.file?(p) }
source_files += [File.join(ROOT, 'Package.swift'), __FILE__]
report['sourceFileSHA256'] = source_files.sort.to_h { |p| [p.delete_prefix(ROOT + '/'), Digest::SHA256.file(p).hexdigest] }
persist(report, directory)
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  report['initialEvidenceAllocatedBytes'] = allocated(directory)
  report['initialSharedPackageCacheAllocatedBytes'] = allocated(cache)
  if options[:groups] == 10_000 && options[:repetitions] == 3 && options[:reopens] == 10 && !report['sourceDirtyPaths'].empty?
    raise 'Mandatory production evidence requires a clean committed source; stage with smaller fixtures first'
  end
  raise 'Free space cannot accommodate estimated 1 GiB fixture plus 20 GiB floor' if free_bytes(directory) < options[:free] + 1024**3
  package_lock = File.open(File.join(UndoKitBuild.root, 'package.lock'), File::RDWR | File::CREAT, 0o600)
  package_lock.flock(File::LOCK_EX)
  build_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  report['build'] = {'phase' => 'build'}
  guarded(['swift', 'build', '--package-path', ROOT, '--scratch-path', cache, '-c', options[:configuration].downcase,
           '--product', 'ScaleProbe'], options, directory, cache, report['build'], File.join(directory, 'build.log'), build_start + options[:seconds])
  bin_path = output('swift', 'build', '--package-path', ROOT, '--scratch-path', cache, '-c', options[:configuration].downcase, '--show-bin-path').strip
  binary = File.join(bin_path, 'ScaleProbe')
  report['build']['elapsedSeconds'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - build_start
  report['artifactSHA256'] = Dir.glob(File.join(bin_path, '**/*')).select do |path|
    File.file?(path) && (path == binary || path.end_with?('.dylib', '.mom', '.xcprivacy'))
  end.to_h { |p| [p.delete_prefix(bin_path + '/'), Digest::SHA256.file(p).hexdigest] }
  report['binary'] = binary
  # Keep the package lock across probes so another checkout cannot replace the binary/runtime while sampling.
  options[:repetitions].times do |repetition|
    fixture = File.join(directory, "repetition-#{repetition + 1}")
    FileUtils.mkdir_p(fixture)
    seed = options[:seed] + repetition
    record = {'seed' => seed, 'repetition' => repetition + 1, 'reopens' => [], 'phase' => 'construction'}
    report['runs'] << record
    persist(report, directory)
    case_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    deadline = case_start + options[:seconds]
    workload_report = File.join(fixture, 'WorkloadReport.json')
    guarded([binary, 'create', fixture, workload_report, options[:groups].to_s, seed.to_s], options,
            directory, cache, record, File.join(fixture, 'create.log'), deadline)
    record['workload'] = JSON.parse(File.read(workload_report))
    options[:reopens].times do |sample|
      record['phase'] = "fresh-process-reopen-#{sample + 1}"
      path = File.join(fixture, "Reopen-#{sample + 1}.json")
      guarded([binary, 'reopen', fixture, path], options, directory, cache, record, File.join(fixture, "reopen-#{sample + 1}.log"), deadline)
      record['reopens'] << JSON.parse(File.read(path))
      persist(report, directory)
    end
    processes = record['reopens'].map { |sample| sample.fetch('processID') }
    raise 'Reopen samples did not use distinct processes' unless processes.uniq.length == options[:reopens]
    record['elapsedSecondsIncludingReopens'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - case_start
    record['phase'] = 'completed'
    record['reopenAvailability'] = distribution(record['reopens'], 'availabilitySeconds')
    record['reopenTotal'] = distribution(record['reopens'], 'totalSeconds')
    record['finalEvidenceAllocatedBytes'] = allocated(directory)
    record['finalSharedPackageCacheAllocatedBytes'] = allocated(cache)
    puts "SCALE repetition=#{repetition + 1} groups=#{options[:groups]} seed=#{seed} elapsed=#{record['elapsedSecondsIncludingReopens'].round(3)}"
  end
  mandatory = options[:groups] == 10_000 && options[:repetitions] == 3 && options[:reopens] == 10
  report['result'] = mandatory ? 'mac_workload_completed' : (options[:groups] > 10_000 ? 'advisory_completed' : 'smoke_completed')
rescue StandardError, Interrupt => error
  report['result'] = 'failed'
  report['failure'] = "#{error.class}: #{error.message}"
  report['lastFixturePhase'] = Dir.glob(File.join(directory, 'repetition-*', 'Phase.txt')).map { |path| File.read(path) }.last
ensure
  report['elapsedSecondsIncludingBuild'] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  persist(report, directory)
  puts "Result: #{report['result']}; evidence: #{File.join(directory, 'report.json')}"
  warn report['failure'] if report['failure']
  package_lock&.close
end
exit(report['result'] == 'failed' ? 1 : 0)
