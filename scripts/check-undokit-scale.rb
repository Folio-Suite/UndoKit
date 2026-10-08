#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'tmpdir'
require 'fileutils'
require 'json'

root = File.expand_path('..', __dir__)
groups = Integer(ARGV.fetch(0, '10000'))
abort 'Group count must be 100 through 100000' unless (100..100_000).cover?(groups)
lock = File.open(File.join(Dir.tmpdir, 'undokit-scale.lock'), File::RDWR | File::CREAT, 0o600)
abort 'Another scale runner is active' unless lock.flock(File::LOCK_EX | File::LOCK_NB)

def output(*args)
  value = IO.popen(args, &:read)
  raise "Command failed: #{args.first}" unless $?.success?
  value
end

def free_bytes(path)
  Integer(output('df', '-k', path).lines.last.split[3]) * 1024
end

abort 'Insufficient free disk: 20 GiB required' if free_bytes(Dir.tmpdir) < 20 * 1024**3
scratch = Dir.mktmpdir('undokit-production-scale-')
log = File.join(scratch, 'run.log')
report = {groups: groups, source_head: output('git', '-C', root, 'rev-parse', 'HEAD').strip,
          peak_rss_bytes: 0, peak_owned_bytes: 0, result: 'incomplete', log: log}
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pid = nil
status = nil
begin
  environment = {'UNDOKIT_SCALE_GROUPS' => groups.to_s, 'UNDOKIT_SCALE_DIRECTORY' => scratch}
  pid = Process.spawn(environment, 'swift', 'test', '-c', 'release', '--package-path',
                      root, '--scratch-path', File.join(scratch, 'build'),
                      '--filter', 'HistoryScaleTests', out: log, err: log, pgroup: true)
  loop do
    pair = Process.waitpid2(pid, Process::WNOHANG)
    if pair
      status = pair.last
      break
    end
    rows = output('ps', '-axo', 'pid=,ppid=,rss=').lines.map { |line| line.split.map(&:to_i) }
    descendants = [pid]
    loop do
      children = rows.select { |id, parent, _| descendants.include?(parent) && !descendants.include?(id) }.map(&:first)
      break if children.empty?
      descendants.concat(children)
    end
    rss = rows.select { |id, _, _| descendants.include?(id) }.sum { |_, _, memory| memory * 1024 }
    owned = Integer(output('du', '-sk', scratch).split.first) * 1024
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    report[:peak_rss_bytes] = [report[:peak_rss_bytes], rss].max
    report[:peak_owned_bytes] = [report[:peak_owned_bytes], owned].max
    raise 'Ten-minute case budget exceeded' if elapsed > 600
    raise '2 GiB combined descendant RSS budget exceeded' if rss > 2 * 1024**3
    raise '12 GiB temporary footprint budget exceeded' if owned > 12 * 1024**3
    raise 'Free disk fell below 20 GiB' if free_bytes(scratch) < 20 * 1024**3
    sleep 0.5
  end
  raise "Scale test failed: #{status}" unless status.success?
  metrics = File.foreach(log).grep(/^SCALE /)
  %w[fixture farBack divergent consolidation].each do |phase|
    raise "Missing scale result: #{phase}" unless metrics.any? { |line| line.start_with?("SCALE #{phase} ") }
  end
  report[:result] = 'completed'
rescue StandardError, Interrupt => error
  report[:failure] = "#{error.class}: #{error.message}"
ensure
  if pid && !status
    begin
      Process.kill('KILL', -pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
  report[:elapsed_seconds] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  report[:metrics] = File.exist?(log) ? File.foreach(log).grep(/^SCALE /).map(&:strip) : []
  File.write(File.join(scratch, 'report.json'), JSON.pretty_generate(report) + "\n")
  puts JSON.pretty_generate(report)
  puts "Evidence retained in #{scratch}"
end
exit(report[:result] == 'completed' ? 0 : 1)
