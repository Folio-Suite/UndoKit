#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'fileutils'
require 'digest'
require 'json'
require 'open3'
require 'tmpdir'

package = File.expand_path(__dir__)
scratch = File.join(Dir.tmpdir, 'folio-native-proof-build')
bundle = File.join(Dir.tmpdir, 'FolioNativeUndoProof.app')
fixture = File.join(Dir.tmpdir, 'folio-native-proof-scratch')
default_fixture = File.join(Dir.tmpdir, 'folio-native-proof')
timeout = Integer(ENV.fetch('NATIVE_PROOF_TIMEOUT', '180'))
memory_mib = Integer(ENV.fetch('NATIVE_PROOF_MEMORY_MIB', '2048'))
disk_mib = Integer(ENV.fetch('NATIVE_PROOF_DISK_MIB', '12288'))
free_mib = Integer(ENV.fetch('NATIVE_PROOF_FREE_MIB', '20480'))
abort 'Resource limits must be positive' unless [timeout, memory_mib, disk_mib, free_mib].all?(&:positive?)
abort 'Timeout exceeds the accepted 600-second ceiling' if timeout > 600
abort 'Memory limit exceeds the accepted 2 GiB ceiling' if memory_mib > 2048
abort 'Disk limit exceeds the accepted 12 GiB ceiling' if disk_mib > 12_288
abort 'Free-space floor is below the accepted 20 GiB minimum' if free_mib < 20_480
memory_limit = memory_mib * 1024 * 1024
disk_limit = disk_mib * 1024 * 1024
free_floor = free_mib * 1024 * 1024
watcher_fault = ENV['NATIVE_PROOF_WATCHER_FAULT']
abort 'Unknown watcher fault hook' unless watcher_fault.nil? || %w[ps du df].include?(watcher_fault)

def checked_output(*command)
  output, status = Open3.capture2e(*command)
  raise "Watcher #{command.first} failed (#{status.exitstatus}): #{output.strip}" unless status.success?
  output
end

def free_bytes(path)
  Integer(checked_output('df', '-k', path).lines.last.split[3]) * 1024
end

def used_bytes(paths)
  paths.select { |path| File.exist?(path) }.sum do |path|
    Integer(checked_output('du', '-sk', path).split.first) * 1024
  end
end

def descendants(root)
  rows = checked_output('ps', '-axo', 'pid=,ppid=,rss=').lines.map { |line| line.split.map(&:to_i) }
  ids = [root]
  loop do
    children = rows.select { |pid, parent, _| ids.include?(parent) && !ids.include?(pid) }.map(&:first)
    break if children.empty?
    ids.concat(children)
  end
  [ids, rows.select { |pid, _, _| ids.include?(pid) }.sum { |_, _, rss| rss * 1024 }]
end

def stop_tree(root, tracked_ids, root_reaped: false)
  cleanup = { tracked_pids: tracked_ids.uniq, signaled_pids: [], root_reaped: root_reaped, errors: [] }
  begin
    fresh_ids, = descendants(root)
    cleanup[:tracked_pids] |= fresh_ids
  rescue StandardError => error
    cleanup[:errors] << "Fresh descendant scan: #{error.class}: #{error.message}"
  end
  cleanup[:tracked_pids].reverse_each do |id|
    begin
      Process.kill('KILL', id)
      cleanup[:signaled_pids] << id
    rescue Errno::ESRCH
      nil
    rescue StandardError => error
      cleanup[:errors] << "Kill #{id}: #{error.class}: #{error.message}"
    end
  end
  begin
    Process.kill('KILL', -root)
    cleanup[:signaled_group] = root
  rescue Errno::ESRCH
    nil
  rescue StandardError => error
    cleanup[:errors] << "Kill group #{root}: #{error.class}: #{error.message}"
  end
  unless cleanup[:root_reaped]
    begin
      Process.waitpid(root)
      cleanup[:root_reaped] = true
    rescue Errno::ECHILD
      cleanup[:root_reaped] = true
    rescue StandardError => error
      cleanup[:errors] << "Reap #{root}: #{error.class}: #{error.message}"
    end
  end
  cleanup
end

def bounded!(command, directory:, timeout:, memory_limit:, disk_limit:, free_floor:, owned_paths:, fault:, diagnostics:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  pid = Process.spawn(*command, chdir: directory, pgroup: true)
  diagnostics[:child_pid] = pid
  peak_memory = 0
  peak_disk = 0
  tracked_ids = [pid]
  root_reaped = false
  begin
    loop do
      complete = Process.waitpid2(pid, Process::WNOHANG)
      if complete
        root_reaped = true
        raise "Command failed with exit #{complete.last.exitstatus}" unless complete.last.success?
        return { seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
                 peak_sampled_memory_bytes: peak_memory, peak_sampled_owned_disk_bytes: peak_disk }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      raise 'Injected ps watcher failure' if fault == 'ps'
      ids, memory = descendants(pid)
      tracked_ids |= ids
      raise 'Injected du watcher failure' if fault == 'du'
      disk = used_bytes(owned_paths)
      peak_memory = [peak_memory, memory].max
      peak_disk = [peak_disk, disk].max
      raise 'Injected df watcher failure' if fault == 'df'
      free = free_bytes(owned_paths.first)
      raise 'Time limit exceeded' if elapsed > timeout
      raise 'Memory limit exceeded' if memory > memory_limit
      raise 'Disk limit exceeded' if disk > disk_limit
      raise 'Free-space floor crossed' if free < free_floor
      sleep 0.2
    end
  rescue Exception => error
    diagnostics[:failure] = { class: error.class.to_s, message: error.message,
                              phase: 'build_and_tests', elapsed_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started }
    diagnostics[:peak_sampled_memory_bytes] = peak_memory
    diagnostics[:peak_sampled_owned_disk_bytes] = peak_disk
    diagnostics[:cleanup] = stop_tree(pid, tracked_ids, root_reaped: root_reaped)
    raise
  end
end

FileUtils.mkdir_p(scratch)
FileUtils.mkdir_p(fixture)
abort 'SKIP: insufficient free disk for configured floor' if free_bytes(scratch) < free_floor
env = {
  'CLANG_MODULE_CACHE_PATH' => File.join(scratch, 'clang-cache'),
  'SWIFTPM_MODULECACHE_OVERRIDE' => File.join(scratch, 'swiftpm-cache')
}
command = ['env'] + env.map { |key, value| "#{key}=#{value}" } +
          ['swift', 'test', '--package-path', package, '--scratch-path', scratch,
           '-Xswiftc', '-strict-concurrency=complete', '-Xswiftc', '-warnings-as-errors']
source_files = Dir.glob(File.join(package, '**', '*.swift')) + [File.join(package, 'Package.swift'), File.expand_path(__FILE__)]
source_hashes = source_files.sort.to_h do |path|
  [path.delete_prefix(package + '/'), Digest::SHA256.file(path).hexdigest]
end
source_head = IO.popen(['git', '-C', package, 'rev-parse', 'HEAD'], &:read).strip
diagnostics = {}
report_path = File.join(scratch, 'last-run.json')
begin
  run = bounded!(command, directory: package, timeout: timeout, memory_limit: memory_limit,
                 disk_limit: disk_limit, free_floor: free_floor,
                 owned_paths: [scratch, bundle, fixture, default_fixture],
                 fault: watcher_fault, diagnostics: diagnostics)
rescue Exception => error
  failure_path = File.join(scratch, "failure-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{Process.pid}.json")
  failure_report = { status: 'failed', source_base: source_head, source_sha256: source_hashes,
                     limits: { timeout_seconds: timeout, memory_bytes: memory_limit,
                               owned_disk_bytes: disk_limit, free_floor_bytes: free_floor },
                     watcher_fault: watcher_fault, diagnostics: diagnostics,
                     note: 'Child tree terminated and root reaped after watcher or build failure.' }
  File.write(failure_path, JSON.pretty_generate(failure_report) + "\n")
  File.write(report_path, JSON.pretty_generate(failure_report) + "\n")
  warn "Native proof runner failed: #{error.class}: #{error.message}; preserved report: #{failure_path}"
  exit 1
end

binary = File.join(scratch, 'out', 'Products', 'Debug', 'NativeProof')
abort "Missing executable: #{binary}" unless File.executable?(binary)
contents = File.join(bundle, 'Contents')
FileUtils.mkdir_p(File.join(contents, 'MacOS'))
FileUtils.cp(binary, File.join(contents, 'MacOS', 'NativeProof'))
File.write(File.join(contents, 'Info.plist'), <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
  <key>CFBundleName</key><string>Folio Native Undo Proof</string>
  <key>CFBundleDisplayName</key><string>Folio Native Undo Proof</string>
  <key>CFBundleIdentifier</key><string>org.foliosuite.NativeUndoProof</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>NativeProof</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  </dict></plist>
PLIST
report = {
  source_base: source_head, source_sha256: source_hashes,
  os: IO.popen(%w[sw_vers -productVersion], &:read).strip,
  architecture: IO.popen(%w[uname -m], &:read).strip,
  swift: IO.popen(%w[swift --version], &:read).strip,
  configuration: 'Debug, Swift 6 strict concurrency, warnings as errors',
  app: bundle, app_executable_sha256: Digest::SHA256.file(File.join(contents, 'MacOS', 'NativeProof')).hexdigest,
  scratch_fixture: fixture, report: report_path,
  launch: "open --env NATIVE_PROOF_DIR=#{fixture} -a #{bundle}",
  limits: { timeout_seconds: timeout, memory_bytes: memory_limit,
            owned_disk_bytes: disk_limit, free_floor_bytes: free_floor },
  build_and_tests: run,
  note: 'Runner limits cover build/tests only. Native interactive session is separately observed.'
}
File.write(report[:report], JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report)
