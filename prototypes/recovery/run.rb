#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'tmpdir'
require 'timeout'
require 'fileutils'

package = File.expand_path(__dir__)
disk = IO.popen(['df', '-k', Dir.tmpdir], &:read).lines.last.split
free_bytes = Integer(disk[3]) * 1024
floor = 20 * 1024**3
abort "SKIP: less than 20 GiB free on temporary volume" if free_bytes < floor

timeout_seconds = Integer(ENV.fetch('RECOVERY_PROBE_TIMEOUT', '180'))
abort 'Timeout must be between 1 and 600 seconds' unless (1..600).cover?(timeout_seconds)
puts "Recovery probe: small deterministic #47 suite; free temporary disk #{free_bytes} bytes; watchdog #{timeout_seconds}s"
puts "Source: #{package}"

fixture_dir = Dir.mktmpdir('folio-recovery-')
memory_limit = 2 * 1024**3
disk_limit = 12 * 1024**3
reason = nil
running = true
pid = Process.spawn({ 'TMPDIR' => fixture_dir }, 'swift', 'test', '--package-path', package,
                    '-Xswiftc', '-strict-concurrency=complete', '-Xswiftc', '-warnings-as-errors',
                    chdir: package, pgroup: true, out: $stdout, err: $stderr)
watchdog = Thread.new do
  while running
    sleep 0.5
    break unless running
    resident_kib = IO.popen(['ps', '-axo', 'pgid=,rss='], &:read).lines.sum do |line|
      fields = line.split
      fields.length == 2 && fields[0].to_i == pid ? fields[1].to_i : 0
    end
    owned_kib = IO.popen(['du', '-sk', fixture_dir, File.join(package, '.build')], &:read).lines.sum do |line|
      line.split.first.to_i
    end
    remaining = Integer(IO.popen(['df', '-k', fixture_dir], &:read).lines.last.split[3]) * 1024
    reason = if resident_kib * 1024 > memory_limit
               "combined process-group RSS exceeded 2 GiB (#{resident_kib} KiB)"
             elsif owned_kib * 1024 > disk_limit
               "fixture and build footprint exceeded 12 GiB (#{owned_kib} KiB)"
             elsif remaining < floor
               "remaining temporary disk fell below 20 GiB (#{remaining} bytes)"
             end
    next unless reason
    warn "FAIL: watchdog stopped recovery probe: #{reason}; fixtures retained at #{fixture_dir}"
    File.write(File.join(fixture_dir, 'watchdog-diagnostic.txt'), reason + "\n")
    Process.kill('KILL', -pid)
    break
  end
rescue Errno::ESRCH
  nil
end
begin
  Timeout.timeout(timeout_seconds) { Process.wait(pid) }
rescue Timeout::Error
  reason = "runtime exceeded #{timeout_seconds}s"
  warn "FAIL: watchdog stopped recovery probe: #{reason}; fixtures retained at #{fixture_dir}"
  File.write(File.join(fixture_dir, 'watchdog-diagnostic.txt'), reason + "\n")
  Process.kill('KILL', -pid)
  Process.wait(pid)
ensure
  running = false
  watchdog.join
end
status = $?.exitstatus || 1
FileUtils.remove_entry(fixture_dir) if reason.nil?
exit(reason.nil? ? status : 124)
