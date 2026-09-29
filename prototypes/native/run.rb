#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'fileutils'
require 'digest'
require 'json'
require 'tmpdir'

package = File.expand_path(__dir__)
scratch = File.join(Dir.tmpdir, 'folio-native-proof-build')
bundle = File.join(Dir.tmpdir, 'FolioNativeUndoProof.app')
fixture = File.join(Dir.tmpdir, 'folio-native-proof-scratch')
timeout = Integer(ENV.fetch('NATIVE_PROOF_TIMEOUT', '180'))
memory_limit = Integer(ENV.fetch('NATIVE_PROOF_MEMORY_MIB', '2048')) * 1024 * 1024
disk_limit = Integer(ENV.fetch('NATIVE_PROOF_DISK_MIB', '12288')) * 1024 * 1024
free_floor = Integer(ENV.fetch('NATIVE_PROOF_FREE_MIB', '20480')) * 1024 * 1024
abort 'Resource limits must be positive' unless [timeout, memory_limit, disk_limit, free_floor].all?(&:positive?)

def free_bytes(path)
  Integer(IO.popen(['df', '-k', path], &:read).lines.last.split[3]) * 1024
end

def used_bytes(paths)
  paths.select { |path| File.exist?(path) }.sum do |path|
    Integer(IO.popen(['du', '-sk', path], &:read).split.first) * 1024
  end
end

def descendants(root)
  rows = IO.popen(%w[ps -axo pid=,ppid=,rss=], &:read).lines.map { |line| line.split.map(&:to_i) }
  ids = [root]
  loop do
    children = rows.select { |pid, parent, _| ids.include?(parent) && !ids.include?(pid) }.map(&:first)
    break if children.empty?
    ids.concat(children)
  end
  [ids, rows.select { |pid, _, _| ids.include?(pid) }.sum { |_, _, rss| rss * 1024 }]
end

def stop_tree(root, ids)
  ids.reverse_each do |id|
    Process.kill('KILL', id)
  rescue Errno::ESRCH
    nil
  end
  Process.kill('KILL', -root)
rescue Errno::ESRCH
  nil
end

def bounded!(command, directory:, timeout:, memory_limit:, disk_limit:, free_floor:, owned_paths:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  pid = Process.spawn(*command, chdir: directory, pgroup: true)
  peak_memory = 0
  peak_disk = 0
  loop do
    complete = Process.waitpid2(pid, Process::WNOHANG)
    if complete && complete.last.success?
      return { seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
               peak_sampled_memory_bytes: peak_memory, peak_sampled_owned_disk_bytes: peak_disk }
    end
    abort "Command failed: #{command.join(' ')}" if complete
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    ids, memory = descendants(pid)
    disk = used_bytes(owned_paths)
    peak_memory = [peak_memory, memory].max
    peak_disk = [peak_disk, disk].max
    memory_exceeded = memory > memory_limit
    disk_exceeded = disk > disk_limit
    free_exceeded = free_bytes(owned_paths.first) < free_floor
    if elapsed > timeout || memory_exceeded || disk_exceeded || free_exceeded
      stop_tree(pid, ids)
      Process.waitpid(pid)
      reason = if elapsed > timeout then 'time' elsif memory_exceeded then 'memory'
               elsif disk_exceeded then 'disk' else 'free-space floor' end
      abort "Command exceeded #{reason} limit"
    end
    sleep 0.2
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
run = bounded!(command, directory: package, timeout: timeout, memory_limit: memory_limit,
               disk_limit: disk_limit, free_floor: free_floor,
               owned_paths: [scratch, bundle, fixture])

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
  scratch_fixture: fixture, report: File.join(scratch, 'last-run.json'),
  launch: "open --env NATIVE_PROOF_DIR=#{fixture} -a #{bundle}",
  limits: { timeout_seconds: timeout, memory_bytes: memory_limit,
            owned_disk_bytes: disk_limit, free_floor_bytes: free_floor },
  build_and_tests: run,
  note: 'Runner limits cover build/tests only. Native interactive session is separately observed.'
}
File.write(report[:report], JSON.pretty_generate(report) + "\n")
puts JSON.pretty_generate(report)
