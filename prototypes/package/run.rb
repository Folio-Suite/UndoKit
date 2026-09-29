#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'tmpdir'
require 'fileutils'
require 'json'
require 'digest'

def setting(name, fallback, maximum)
  value = Integer(ENV.fetch(name, fallback.to_s))
  abort "#{name} must be between 1 and #{maximum}" unless (1..maximum).cover?(value)
  value
end

def free_bytes(path)
  output = IO.popen(['df', '-k', path], &:read)
  raise 'Could not read free disk space' unless $?.success?
  Integer(output.lines.last.split[3]) * 1024
end

def descendants(root)
  output = IO.popen(['ps', '-axo', 'pid=,ppid=,rss='], &:read)
  raise 'Could not inspect child processes' unless $?.success?
  rows = output.lines.map { |line| line.split.map(&:to_i) }
  ids = [root]
  loop do
    children = rows.select { |pid, parent, _| ids.include?(parent) && !ids.include?(pid) }.map(&:first)
    break if children.empty?
    ids.concat(children)
  end
  [ids, rows.select { |pid, _, _| ids.include?(pid) }.sum { |_, _, rss| rss * 1024 }]
end

def stop_children(root, ids)
  errors = []
  # The child starts in its own process group; kill it first so newly spawned
  # grandchildren are included even if the last ps sample missed them.
  begin
    Process.kill('KILL', -root)
  rescue Errno::ESRCH
    nil
  rescue SystemCallError => error
    errors << "process group #{root}: #{error.class}: #{error.message}"
  end
  ids.reverse_each do |child|
    begin
      Process.kill('KILL', child)
    rescue Errno::ESRCH
      nil
    rescue SystemCallError => error
      errors << "process #{child}: #{error.class}: #{error.message}"
    end
  end
  errors
end

def reap_child(pid, timeout_seconds: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
  loop do
    completed = Process.waitpid2(pid, Process::WNOHANG)
    return completed.last if completed
    return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
rescue Errno::ECHILD
  nil
end

package = File.expand_path(__dir__)
limits = {
  timeout_seconds: setting('PACKAGE_PROBE_TIMEOUT', 180, 600),
  memory_bytes: setting('PACKAGE_PROBE_MEMORY_MIB', 2048, 2048) * 1024**2,
  disk_bytes: setting('PACKAGE_PROBE_DISK_MIB', 12_288, 12_288) * 1024**2,
  free_floor_bytes: 20_480 * 1024**2
}
puts "Package probe limits: #{limits.to_json}"
if [free_bytes(Dir.tmpdir), free_bytes(package)].min < limits[:free_floor_bytes]
  warn 'SKIP: less than 20 GiB free'
  exit 77
end

build = File.join(package, '.build')
FileUtils.mkdir_p(build)
fixture_dir = Dir.mktmpdir('folio-package-run-')
log_path = File.join(build, 'package-last-run.log')
report_path = File.join(build, 'package-last-run.json')
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
source_head = IO.popen(['git', '-C', package, 'rev-parse', 'HEAD'], &:read).strip
source_files = Dir.glob(File.join(package, '**', '*.swift')) + [File.join(package, 'run.rb')]
source_hashes = source_files.sort.to_h { |path| [path.delete_prefix(package + '/'), Digest::SHA256.file(path).hexdigest] }
report = { source: package, source_head: source_head, source_sha256: source_hashes,
           fixture_directory: fixture_dir, limits: limits,
           peak_sampled_memory_bytes: 0, peak_sampled_owned_bytes: 0 }
reason = nil
child_status = nil
child_ids = []
pid = nil
phase = 'spawn'
stop_errors = []
begin
  File.open(log_path, 'w') do |log|
    pid = Process.spawn({ 'TMPDIR' => fixture_dir, 'PACKAGE_PROBE_KEEP_FIXTURES' => '1' },
                        'xcrun', 'swift', 'test', '--package-path', package,
                        '-Xswiftc', '-strict-concurrency=complete', '-Xswiftc', '-warnings-as-errors',
                        chdir: package, pgroup: true, out: log, err: log)
    report[:child_pid] = pid
    phase = 'monitor'
    loop do
      completed = Process.waitpid2(pid, Process::WNOHANG)
      if completed
        child_status = completed.last
        break
      end
      raise 'injected monitor failure' if ENV['PACKAGE_PROBE_INJECT_MONITOR_FAILURE'] == '1'
      child_ids, resident = descendants(pid)
      usage = IO.popen(['du', '-sk', fixture_dir, build], &:read)
      raise 'Could not read owned disk usage' unless $?.success?
      owned = usage.lines.sum { |line| Integer(line.split.first) * 1024 }
      report[:peak_sampled_memory_bytes] = [report[:peak_sampled_memory_bytes], resident].max
      report[:peak_sampled_owned_bytes] = [report[:peak_sampled_owned_bytes], owned].max
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      reason = if elapsed > limits[:timeout_seconds]
                 'runtime limit exceeded'
               elsif resident > limits[:memory_bytes]
                 'combined descendant RSS limit exceeded'
               elsif owned > limits[:disk_bytes]
                 'fixture and build footprint limit exceeded'
               elsif [free_bytes(fixture_dir), free_bytes(build)].min < limits[:free_floor_bytes]
                 'remaining disk below 20 GiB floor'
               end
      break if reason
      sleep 0.25
    end
  end
rescue StandardError, Interrupt => error
  reason = "runner failure during #{phase}: #{error.class}: #{error.message}"
ensure
  if pid && child_status.nil?
    stop_errors = stop_children(pid, child_ids)
    child_status = reap_child(pid)
    unless child_status
      stop_errors.concat(stop_children(pid, child_ids))
      child_status = reap_child(pid, timeout_seconds: 1)
    end
    reason = [reason, 'child could not be reaped after termination'].compact.join('; ') unless child_status
  end
  report[:elapsed_seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  report[:reason] = reason
  report[:child_exit_status] = child_status&.exitstatus
  report[:child_signal] = child_status&.termsig
  report[:child_reaped] = !child_status.nil?
  report[:failure_phase] = reason ? phase : nil
  report[:termination_errors] = stop_errors
  begin
    File.write(report_path, JSON.pretty_generate(report) + "\n")
  rescue StandardError => error
    warn "Could not save runner report: #{error.message}"
  end
end
puts File.read(log_path) if File.file?(log_path)
succeeded = reason.nil? && child_status&.success?
FileUtils.remove_entry(fixture_dir) if succeeded
warn "FAIL: #{reason || 'test command failed'}; fixtures retained at #{fixture_dir}" unless succeeded
puts "Runner report: #{report_path}"
puts 'Memory and disk peaks are sampled watchdog observations, not calibrated benchmarks.'
exit(reason ? 124 : (child_status&.exitstatus || 1))
