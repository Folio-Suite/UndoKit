#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'digest'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'uri'

OPTIONS = { root: Dir.pwd }
OptionParser.new do |parser|
  parser.banner = 'Usage: ruby scripts/maintenance/check.rb [--root PATH]'
  parser.on('--root PATH', 'Repository root to check (defaults to the current directory)') do |path|
    OPTIONS[:root] = File.expand_path(path)
  end
end.parse!

ROOT = File.realpath(OPTIONS.fetch(:root))
BASELINE_PATH = File.join(ROOT, 'scripts/maintenance/swiftlint-baseline.json')
CHECKSUM_PATH = File.join(ROOT, 'docs/imported-design/preservation-checksums.json')
RESOLVED_PACKAGES_PATH = File.join(ROOT, 'UndoKit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
SWIFTLINT_VERSION = '0.65.1'
SWIFTLINT_PLUGIN_REVISION = 'ef7d692fc6706e8f5628e26bcafaefa445c58a97'
$failures = []

def relative_path(path)
  canonical_path = File.exist?(path) ? File.realpath(path) : File.expand_path(path)
  Pathname.new(canonical_path).relative_path_from(Pathname.new(ROOT)).to_s
end

def fail_check(message)
  $failures << message
  false
end

def tracked_or_present_paths(pattern)
  Dir.glob(File.join(ROOT, pattern), File::FNM_DOTMATCH)
    .select { |path| File.file?(path) }
    .reject do |path|
      Pathname.new(path).relative_path_from(Pathname.new(ROOT)).each_filename.any? do |part|
        %w[.git .build build DerivedData dist node_modules].include?(part)
      end
    end
    .sort
end

def swiftlint_executable
  cache = File.expand_path('~/Library/Developer/Xcode/DerivedData')
  candidates = Dir.glob(File.join(cache,
                                 'UndoKit-*/SourcePackages/artifacts/swiftlintplugins/' \
                                 'SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint'))
  candidates.each do |candidate|
    version, status = Open3.capture2(candidate, 'version')
    return candidate if status.success? && version.strip == SWIFTLINT_VERSION
  end

  project = File.join(ROOT, 'UndoKit.xcodeproj')
  command = ['xcodebuild', '-resolvePackageDependencies', '-project', project, '-scheme', 'UndoKit']
  output, status = Open3.capture2e(*command)
  return fail_check("Could not resolve the pinned SwiftLint tool with `#{command.join(' ')}`:\n#{output}") unless
    status.success?

  candidates = Dir.glob(File.join(cache,
                                 'UndoKit-*/SourcePackages/artifacts/swiftlintplugins/' \
                                 'SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint'))
  candidates.each do |candidate|
    version, version_status = Open3.capture2(candidate, 'version')
    return candidate if version_status.success? && version.strip == SWIFTLINT_VERSION
  end
  fail_check("SwiftLint #{SWIFTLINT_VERSION} was not found in Xcode's resolved package artifacts.")
end

def lint_context(path, line)
  lines = File.readlines(path, chomp: true)
  index = line - 1
  [index.positive? ? lines[index - 1] : '', lines.fetch(index), lines[index + 1] || '']
end

def lint_identity(path, rule, context)
  normalized = context.map { |line| line.strip }.join("\n")
  Digest::SHA256.hexdigest([relative_path(path), rule, normalized].join("\0"))
end

def lint_check
  config = File.join(ROOT, '.swiftlint.yml')
  return fail_check("Missing SwiftLint configuration: #{relative_path(config)}") unless File.file?(config)
  return fail_check("Missing reviewed SwiftLint baseline: #{relative_path(BASELINE_PATH)}") unless File.file?(BASELINE_PATH)
  return fail_check("Missing pinned Xcode package lock: #{relative_path(RESOLVED_PACKAGES_PATH)}") unless File.file?(RESOLVED_PACKAGES_PATH)

  baseline = JSON.parse(File.read(BASELINE_PATH))
  unless baseline.fetch('tool').fetch('version') == SWIFTLINT_VERSION
    return fail_check("Baseline expects SwiftLint #{baseline.dig('tool', 'version')}; expected #{SWIFTLINT_VERSION}.")
  end
  unless Digest::SHA256.file(config).hexdigest == baseline.fetch('config_sha256')
    return fail_check('SwiftLint configuration changed; review the rules and thresholds before updating its baseline.')
  end
  resolved = JSON.parse(File.read(RESOLVED_PACKAGES_PATH))
  pin = resolved.fetch('pins').find { |item| item.fetch('identity') == 'swiftlintplugins' }
  unless pin && pin.dig('state', 'version') == SWIFTLINT_VERSION &&
         pin.dig('state', 'revision') == SWIFTLINT_PLUGIN_REVISION &&
         pin.fetch('location') == 'https://github.com/SimplyDanny/SwiftLintPlugins'
    return fail_check('SwiftLint package pin changed; review the tool version and update the reviewed baseline explicitly.')
  end
  executable = swiftlint_executable
  return false unless executable

  command = [executable, 'lint', '--config', config, '--quiet', '--no-cache', '--reporter', 'json', ROOT]
  output, status = Open3.capture2e(*command)
  begin
    diagnostics = JSON.parse(output)
  rescue JSON::ParserError
    return fail_check("SwiftLint did not return JSON diagnostics (exit #{status.exitstatus}):\n#{output}")
  end

  entries = baseline.fetch('violations')
  malformed = entries.find do |entry|
    context = entry.fetch('context')
    expected_identity = Digest::SHA256.hexdigest(
      [entry.fetch('file'), entry.fetch('rule'), context.map(&:strip).join("\n")].join("\0")
    )
    expected_identity != entry.fetch('identity') || entry.fetch('disposition').empty? || entry.fetch('rationale').empty?
  end
  return fail_check("Malformed reviewed baseline entry: #{malformed.inspect}") if malformed

  approved = entries.group_by { |entry| entry.fetch('identity') }.transform_values(&:length)
  seen = Hash.new(0)
  new_findings = []
  diagnostics.each do |diagnostic|
    path = diagnostic.fetch('file')
    rule = diagnostic.fetch('rule_id')
    line = diagnostic.fetch('line')
    context = lint_context(path, line)
    identity = lint_identity(path, rule, context)
    if seen[identity] < approved.fetch(identity, 0)
      seen[identity] += 1
    else
      new_findings << [relative_path(path), line, rule, diagnostic.fetch('reason'), context[1]]
    end
  end

  # A repeated identity is an independent finding and must match the same number of baseline records.
  stale = entries.group_by { |entry| entry.fetch('identity') }.flat_map do |identity, matches|
    seen_count = diagnostics.count do |diagnostic|
      lint_identity(diagnostic.fetch('file'), diagnostic.fetch('rule_id'),
                    lint_context(diagnostic.fetch('file'), diagnostic.fetch('line'))) == identity
    end
    seen_count < matches.length ? matches.drop(seen_count) : []
  end

  valid_status = status.exitstatus == 0 || (status.exitstatus == 2 && !diagnostics.empty?)
  unless valid_status
    $failures << "SwiftLint exited with status #{status.exitstatus}."
  end
  unless new_findings.empty?
    $failures << "New SwiftLint findings (rule, source context, and disposition required):\n" +
      new_findings.map { |path, line, rule, reason, source| "  #{path}:#{line} [#{rule}] #{reason}\n    #{source.strip}" }.join("\n")
  end
  unless stale.empty?
    $failures << "Removed or changed SwiftLint baseline entries; delete obsolete exemptions:\n" +
      stale.map { |entry| "  #{entry.fetch('file')}:#{entry.fetch('line')} [#{entry.fetch('rule')}]" }.join("\n")
  end
  $failures.empty?
end

def markdown_check
  paths = tracked_or_present_paths('**/*.md')
  missing = []
  pattern = /\[[^\]]*\]\((<[^>]*>|[^)\s]+)(?:\s+[^)]*)?\)/
  paths.each do |source|
    File.read(source).scan(pattern).flatten.each do |target_text|
      target = target_text.delete_prefix('<').delete_suffix('>')
      next if target.empty? || target.match?(/\A[a-z][a-z0-9+.-]*:/i) || target.start_with?('#')

      local_destination = URI::DEFAULT_PARSER.unescape(target.split(/[?#]/, 2).first)
      destination = local_destination.start_with?('/') ?
        File.join(ROOT, local_destination.delete_prefix('/')) :
        File.expand_path(local_destination, File.dirname(source))
      missing << "#{relative_path(source)}: #{target}" unless File.file?(destination) || File.directory?(destination)
    end
  end
  return true if missing.empty?

  $failures << "Missing local Markdown destinations (external links and anchors are excluded):\n  #{missing.join("\n  ")}"
  false
end

def script_syntax_check
  ruby_paths = tracked_or_present_paths('scripts/**/*.rb')
  shell_paths = tracked_or_present_paths('scripts/**/*.sh')
  results = []
  ruby_paths.each do |path|
    output, status = Open3.capture2e('ruby', '-c', path)
    results << [path, output, status] unless status.success?
  end
  shell_paths.each do |path|
    output, status = Open3.capture2e('bash', '-n', path)
    results << [path, output, status] unless status.success?
  end
  return true if results.empty?

  $failures << "Invalid maintained Ruby/shell runner syntax:\n" +
    results.map { |path, output, status| "  #{relative_path(path)} (exit #{status.exitstatus}): #{output.strip}" }.join("\n")
  false
end

def checksum_check
  return fail_check("Missing preservation checksum manifest: #{relative_path(CHECKSUM_PATH)}") unless File.file?(CHECKSUM_PATH)

  manifest = JSON.parse(File.read(CHECKSUM_PATH))
  failures_found = manifest.each_with_object([]) do |(path, expected), problems|
    artifact = File.join(ROOT, 'docs/imported-design', path)
    if !File.file?(artifact)
      problems << "#{relative_path(artifact)} is missing (expected SHA-256 #{expected})"
    else
      actual = Digest::SHA256.file(artifact).hexdigest
      problems << "#{relative_path(artifact)} checksum mismatch: expected #{expected}, got #{actual}" unless actual == expected
    end
  end
  return true if failures_found.empty?

  $failures << "Preserved artifact checksums failed:\n  #{failures_found.join("\n  ")}"
  false
end

checks = {
  'SwiftLint baseline' => method(:lint_check),
  'local Markdown destinations' => method(:markdown_check),
  'maintained script syntax' => method(:script_syntax_check),
  'preserved artifact checksums' => method(:checksum_check)
}
checks.each do |name, check|
  begin
    check.call
  rescue StandardError => error
    $failures << "#{name} could not complete: #{error.class}: #{error.message}"
  end
end

if $failures.empty?
  puts "Maintenance checks passed (SwiftLint #{SWIFTLINT_VERSION}; configured source/test inventory)."
  exit 0
end

$failures.each { |failure| warn failure }
exit 1
