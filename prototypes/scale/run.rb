#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'
require 'time'

ROOT = File.expand_path(__dir__)
KIND = ARGV.fetch(0) { abort 'Usage: ruby run.rb ordinary|large|kitchen|payload|smoke' }
abort 'Unknown fixture' unless %w[ordinary large kitchen payload smoke].include?(KIND)

def setting(name, fallback)
  value = Integer(ENV.fetch(name, fallback.to_s))
  abort "#{name} must be positive" unless value.positive?
  if name == 'SCALE_FREE_FLOOR_MIB'
    abort "#{name} cannot be below #{fallback} without a recorded override" if value < fallback
  else
    abort "#{name} cannot exceed #{fallback} without a recorded override" if value > fallback
  end
  value
end

LIMITS = {
  case_seconds: setting('SCALE_CASE_SECONDS', 600),
  memory_bytes: setting('SCALE_MEMORY_MIB', 2048) * 1024**2,
  owned_bytes: setting('SCALE_OWNED_MIB', 12_288) * 1024**2,
  free_floor_bytes: setting('SCALE_FREE_FLOOR_MIB', 20_480) * 1024**2
}.freeze

def output(*cmd)
  text = IO.popen(cmd, &:read)
  raise "Failed: #{cmd.join(' ')}" unless $?.success?
  text.strip
end

def free_bytes(path)
  Integer(output('df', '-k', path).lines.last.split[3]) * 1024
end

def owned_bytes(path)
  Integer(output('du', '-sk', path).split.first) * 1024
end

def descendants(root)
  rows = output('ps', '-axo', 'pid=,ppid=,rss=').lines.map { |line| line.split.map(&:to_i) }
  ids = [root]
  loop do
    children = rows.select { |pid, parent, _| ids.include?(parent) && !ids.include?(pid) }.map(&:first)
    break if children.empty?
    ids.concat(children)
  end
  [ids, rows.select { |pid, _, _| ids.include?(pid) }.sum { |_, _, rss| rss * 1024 }]
end

def kill_tree(root, ids)
  errors = []
  begin
    Process.kill('KILL', -root)
  rescue Errno::ESRCH
    nil
  rescue StandardError => error
    errors << "group: #{error.class}: #{error.message}"
  end
  ids.reverse_each do |pid|
    begin
      Process.kill('KILL', pid)
    rescue Errno::ESRCH
      nil
    rescue StandardError => error
      errors << "pid #{pid}: #{error.class}: #{error.message}"
    end
  end
  errors
end

def watched(command, log_path, fixture_dir, report, phase, deadline)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  status = nil
  ids = []
  reason = nil
  pid = nil
  peak_rss = 0
  peak_owned = 0
  termination_errors = []
  begin
    pid = Process.spawn(*command, chdir: ROOT, pgroup: true,
                        out: log_path, err: log_path + '.stderr.log')
    loop do
      pair = Process.waitpid2(pid, Process::WNOHANG)
      if pair
        status = pair.last
        break
      end
      raise 'injected monitor failure' if ENV['SCALE_INJECT_MONITOR_FAILURE'] == '1'
      ids, rss = descendants(pid)
      owned = owned_bytes(fixture_dir) + owned_bytes(File.join(ROOT, '.build'))
      peak_rss = [peak_rss, rss].max
      peak_owned = [peak_owned, owned].max
      report['peak_descendant_rss_bytes'] = [report['peak_descendant_rss_bytes'] || 0, rss].max
      report['peak_owned_bytes'] = [report['peak_owned_bytes'] || 0, owned].max
      reason = if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                 "case runtime exceeded #{LIMITS[:case_seconds]} seconds"
               elsif rss > LIMITS[:memory_bytes]
                 "descendant RSS exceeded #{LIMITS[:memory_bytes]} bytes"
               elsif owned > LIMITS[:owned_bytes]
                 "owned footprint exceeded #{LIMITS[:owned_bytes]} bytes"
               elsif [free_bytes(fixture_dir), free_bytes(File.join(ROOT, '.build'))].min < LIMITS[:free_floor_bytes]
                 "free space fell below #{LIMITS[:free_floor_bytes]} bytes"
               end
      break if reason
      sleep 0.25
    end
  rescue StandardError, Interrupt => error
    reason = "watchdog failure: #{error.class}: #{error.message}"
  ensure
    if pid && status.nil?
      begin
        termination_errors.concat(kill_tree(pid, ids))
      rescue StandardError => error
        termination_errors << "#{error.class}: #{error.message}"
      end
      reap_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      loop do
        begin
          pair = Process.waitpid2(pid, Process::WNOHANG)
          if pair
            status = pair.last
            break
          end
        rescue Errno::ECHILD
          termination_errors << 'child already reaped without captured status'
          break
        end
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > reap_deadline
        sleep 0.05
      end
      if status.nil?
        termination_errors << 'child not reaped within 3 seconds'
        reason = [reason, 'child reap timeout'].compact.join('; ')
      end
    end
  end
  events = File.file?(log_path) ? File.readlines(log_path).map { |line| JSON.parse(line) rescue nil }.compact : []
  required = if phase.start_with?('fixture-')
               %w[fixtureComplete smallOperations] +
                 (KIND == 'kitchen' ? ['allowance'] : []) +
                 (KIND == 'large' ? ['distantRecovery'] : [])
             elsif phase.start_with?('reopen-')
               ['reopen']
             elsif phase.start_with?('consolidate-')
               ['consolidation']
             else
               []
             end
  seen = events.map { |event| event['phase'] }
  missing = required - seen
  reason = [reason, "missing metric events: #{missing.join(', ')}"].compact.join('; ') unless missing.empty?
  entry = {
    'phase' => phase, 'command' => command, 'elapsed_seconds' => Process.clock_gettime(Process::CLOCK_MONOTONIC) - start,
    'exit_status' => status&.exitstatus, 'signal' => status&.termsig, 'reason' => reason,
    'child_pid' => pid, 'child_reaped' => !status.nil?, 'termination_errors' => termination_errors,
    'peak_descendant_rss_bytes' => peak_rss, 'peak_owned_bytes' => peak_owned,
    'events' => events, 'log' => log_path, 'stderr_log' => log_path + '.stderr.log'
  }
  report['steps'] << entry
  raise "#{phase}: #{reason || status&.exitstatus || status&.termsig}" unless reason.nil? && status&.success?
  entry
end

build = File.join(ROOT, '.build')
FileUtils.mkdir_p(build)
lock = File.open(File.join(build, 'scale-heavy.lock'), File::RDWR | File::CREAT, 0o600)
abort 'Another scale case owns the runner lock' unless lock.flock(File::LOCK_EX | File::LOCK_NB)
abort 'SKIP: insufficient free disk for configured floor' if free_bytes(Dir.tmpdir) < LIMITS[:free_floor_bytes]

stamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
result_dir = File.join(build, 'scale-results', "#{stamp}-#{KIND}")
FileUtils.mkdir_p(result_dir)
fixture_root = Dir.mktmpdir("folio-scale-#{KIND}-")
binary = File.join(build, 'release', 'ScaleChild')
source_files = Dir.glob(File.join(ROOT, '**', '*.swift')) +
               [File.join(ROOT, 'Package.swift'), File.join(ROOT, 'run.rb')]
source_files.reject! { |path| path.include?('/.build/') }
report = {
  'fixture' => KIND, 'source_head' => output('git', '-C', ROOT, 'rev-parse', 'HEAD'),
  'source_sha256' => source_files.sort.to_h { |p| [p.delete_prefix(ROOT + '/'), Digest::SHA256.file(p).hexdigest] },
  'swift_version' => output('swift', '--version'),
  'os_version' => output('sw_vers', '-productVersion'),
  'hardware' => output('sysctl', '-n', 'hw.model'),
  'cpu_brand' => output('sysctl', '-n', 'machdep.cpu.brand_string'),
  'physical_memory_bytes' => Integer(output('sysctl', '-n', 'hw.memsize')),
  'build_configuration' => 'release',
  'limits' => LIMITS, 'page_bytes' => 16 * 1024 * 1024,
  'fixture_directory' => fixture_root, 'steps' => [],
  'peak_descendant_rss_bytes' => 0, 'peak_owned_bytes' => 0
}
report_path = File.join(result_dir, 'report.json')
failed = nil
begin
  build_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LIMITS[:case_seconds]
  watched(['swift', 'build', '-c', 'release', '--package-path', ROOT],
          File.join(result_dir, 'build.log'), fixture_root, report, 'build', build_deadline)
  raise 'Release binary missing' unless File.executable?(binary)
  seeds = KIND == 'smoke' ? [17] : [17, 29, 43]
  seeds.each_with_index do |seed, index|
    run_dir = File.join(fixture_root, "run-#{index + 1}")
    FileUtils.mkdir_p(run_dir)
    db = File.join(run_dir, 'History.sqlite')
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LIMITS[:case_seconds]
    watched([binary, 'fixture', KIND, db, seed.to_s], File.join(result_dir, "fixture-#{index + 1}.jsonl"),
            fixture_root, report, "fixture-#{index + 1}", deadline)
    (KIND == 'smoke' ? 1 : 10).times do |reopen_index|
      watched([binary, 'reopen', db], File.join(result_dir, "reopen-#{index + 1}-#{reopen_index + 1}.jsonl"),
              fixture_root, report, "reopen-#{index + 1}-#{reopen_index + 1}", deadline)
    end
    if KIND == 'large'
      watched([binary, 'consolidate', db], File.join(result_dir, "consolidate-#{index + 1}.jsonl"),
              fixture_root, report, "consolidate-#{index + 1}", deadline)
    end
    FileUtils.remove_entry(run_dir) unless ENV['KEEP_FIXTURES'] == '1'
  end
rescue StandardError, Interrupt => error
  failed = "#{error.class}: #{error.message}"
ensure
  report['result'] = failed ? 'failed' : 'completed'
  report['failure'] = failed
  File.write(report_path, JSON.pretty_generate(report) + "\n")
  FileUtils.remove_entry(fixture_root) if failed.nil? && ENV['KEEP_FIXTURES'] != '1'
  puts "Scale report: #{report_path}"
  puts "Peak sampled descendant RSS: #{report['peak_descendant_rss_bytes']} bytes"
  puts "Peak sampled owned footprint: #{report['peak_owned_bytes']} bytes"
  warn "FAIL: #{failed}; fixtures retained at #{fixture_root}" if failed
end
exit(failed ? 1 : 0)
