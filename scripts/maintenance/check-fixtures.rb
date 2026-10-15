#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

REPOSITORY = File.expand_path('../..', __dir__)
CHECK_COMMAND = File.join(__dir__, 'check.rb')
PACKAGE_LOCK = File.join(REPOSITORY, 'UndoKit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')

def prepare_fixture(parent, name)
  root = File.join(parent, name)
  FileUtils.mkdir_p([
    File.join(root, 'UndoKit'),
    File.join(root, 'docs/imported-design'),
    File.join(root, 'scripts/maintenance'),
    File.dirname(File.join(root, 'UndoKit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))
  ])
  FileUtils.cp(File.join(REPOSITORY, '.swiftlint.yml'), File.join(root, '.swiftlint.yml'))
  FileUtils.cp(PACKAGE_LOCK, File.join(root, 'UndoKit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'))
  File.write(File.join(root, 'docs/imported-design/preservation-checksums.json'), "{}\n")
  baseline = {
    'tool' => { 'version' => '0.65.1' },
    'config_sha256' => Digest::SHA256.file(File.join(root, '.swiftlint.yml')).hexdigest,
    'violations' => []
  }
  File.write(File.join(root, 'scripts/maintenance/swiftlint-baseline.json'), JSON.pretty_generate(baseline) + "\n")
  File.write(File.join(root, 'UndoKit/Fixture.swift'), "import Foundation\nstruct Fixture {}\n")
  root
end

def expect_cli_result(root, name, expected_status, expected_diagnostic = nil)
  output, status = Open3.capture2e(RbConfig.ruby, CHECK_COMMAND, '--root', root)
  unless status.exitstatus == expected_status
    abort "#{name}: expected exit #{expected_status}, got #{status.exitstatus}\n#{output}"
  end
  if expected_diagnostic && !output.include?(expected_diagnostic)
    abort "#{name}: missing diagnostic #{expected_diagnostic.inspect}\n#{output}"
  end
  puts "PASS #{name} (exit #{status.exitstatus})"
end

Dir.mktmpdir('undokit-maintenance-fixtures-') do |temporary_root|
  clean = prepare_fixture(temporary_root, 'clean')
  File.write(File.join(clean, 'docs/README.md'), <<~MARKDOWN)
    [inline](target.md)
    [anchored](target.md#section)
    [guide][g]
    [external][remote]
    [fragment][section]

    [g]: <file with spaces.md> "local guide"
    [remote]: https://example.invalid/reference "external guide"
    [section]: #target
    [target](assets/)
  MARKDOWN
  File.write(File.join(clean, 'docs/target.md'), "# Target\n")
  File.write(File.join(clean, 'docs/file with spaces.md'), "# Guide\n")
  FileUtils.mkdir_p(File.join(clean, 'docs/assets'))
  artifact = File.join(clean, 'docs/imported-design/sample.txt')
  File.write(artifact, "fixture artifact\n")
  File.write(File.join(clean, 'docs/imported-design/preservation-checksums.json'), JSON.pretty_generate(
    'sample.txt' => Digest::SHA256.file(artifact).hexdigest
  ) + "\n")
  expect_cli_result(clean, 'clean fixture with inline, reference, spaced, directory, and checksum destinations', 0)

  lint = prepare_fixture(temporary_root, 'new-lint')
  File.write(File.join(lint, 'UndoKit/Fixture.swift'), "let fixtureLine = \"#{'x' * 130}\"\n")
  expect_cli_result(lint, 'new SwiftLint violation', 1, 'UndoKit/Fixture.swift:1 [line_length]')

  inline_link = prepare_fixture(temporary_root, 'broken-inline-link')
  File.write(File.join(inline_link, 'docs/README.md'), "[missing](missing.md)\n")
  expect_cli_result(inline_link, 'broken inline Markdown destination', 1, 'README.md:1: missing.md')

  reference_link = prepare_fixture(temporary_root, 'broken-reference-link')
  File.write(File.join(reference_link, 'docs/README.md'), "[guide][g]\n\n[g]: <missing path.md> 'guide title'\n")
  expect_cli_result(reference_link, 'broken reference Markdown destination', 1, 'README.md:3: missing path.md')

  ruby_syntax = prepare_fixture(temporary_root, 'broken-ruby-syntax')
  File.write(File.join(ruby_syntax, 'scripts/broken.rb'), "def broken(\n")
  expect_cli_result(ruby_syntax, 'invalid Ruby runner syntax', 1, 'scripts/broken.rb (exit 1)')

  shell_syntax = prepare_fixture(temporary_root, 'broken-shell-syntax')
  File.write(File.join(shell_syntax, 'scripts/broken.sh'), "if then\n")
  expect_cli_result(shell_syntax, 'invalid shell runner syntax', 1, 'scripts/broken.sh (exit 2)')

  checksum = prepare_fixture(temporary_root, 'checksum-mismatch')
  File.write(File.join(checksum, 'docs/imported-design/sample.txt'), "fixture artifact\n")
  File.write(File.join(checksum, 'docs/imported-design/preservation-checksums.json'), JSON.pretty_generate(
    'sample.txt' => '0' * 64
  ) + "\n")
  expect_cli_result(checksum, 'preserved artifact checksum mismatch', 1, 'sample.txt checksum mismatch')
end
