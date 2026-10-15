# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'json'
require_relative 'fixture'

class ReleaseCandidateCommandTest < Minitest::Test
  include CandidateFixture

  COMMAND = File.expand_path('candidate.rb', __dir__)

  def test_refuses_a_published_build_before_accessing_signing_keys
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      source = File.join(directory, 'source')
      Dir.mkdir(source)
      system('git', 'init', '-q', source, exception: true)
      system('git', '-C', source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
             'commit', '--allow-empty', '-qm', 'fixture', exception: true)
      commit, = Open3.capture2('git', '-C', source, 'rev-parse', 'HEAD')
      inventory = File.join(directory, 'published.json')
      File.write(inventory, JSON.generate(schemaVersion: 1, repository: 'Folio-Suite/UndoKit',
        observedAtUTC: '2026-10-15T00:00:00Z', evidence: 'fixture only',
        published: [{version: '0.1.0', frameworkBuildNumber: '8', sourceCommit: 'a' * 40, archiveSHA256: 'b' * 64}]))
      output = File.join(directory, 'attempt')
      text, result = Open3.capture2e(RbConfig.ruby, '--disable-gems', COMMAND, 'prepare', '--output', output,
        '--source', source, '--commit', commit.strip, '--version', '0.2.0', '--build-number', '8',
        '--assembly', File.join(directory, 'assembly'), '--docs', File.join(directory, 'docs'), '--publisher-approval', 'missing.json',
        '--published-inventory', inventory)
      refute result.success?
      assert_includes text, 'build number must exceed published build 8'
      assert File.file?(File.join(output, 'preparation-failure.json'))
    end
  end

  def test_development_identity_is_rejected_even_if_approval_claims_it
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      approval = JSON.parse(File.read(options[:publisher_approval]))
      approval['publisher'] = 'Apple Development: Fixture'
      File.write(options[:publisher_approval], JSON.generate(approval))
      text, result = candidate_command(options)
      refute result.success?
      assert_includes text, 'approved publisher must be Apple Distribution'
      assert File.file?(File.join(options[:output], 'preparation-failure.json'))
    end
  end

  def test_tampered_original_archive_fails_and_preserves_all_original_inputs
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      original = File.join(options[:assembly], 'archives', 'macos.xcarchive', 'retained-original')
      File.write(original, 'tampered')
      text, result = candidate_command(options)
      refute result.success?
      assert_includes text, 'archive bytes differ'
      assert_equal 'tampered', File.read(original)
      assert File.file?(File.join(options[:output], 'preparation-failure.json'))
      refute File.exist?(File.join(options[:output], 'manifest.json'))
    end
  end

  def test_documentation_must_come_from_the_exact_clean_candidate_source
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      path = File.join(options[:docs], 'manifest.json')
      manifest = JSON.parse(File.read(path))
      manifest['sourceCommit'] = 'f' * 40
      File.write(path, JSON.generate(manifest))
      text, result = candidate_command(options)
      refute result.success?
      assert_includes text, 'documentation must match candidate version and clean source commit'
      refute File.exist?(File.join(options[:output], 'manifest.json'))
    end
  end

  def test_prepares_retained_bytes_and_verifies_them_without_changing_inputs
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      environment = boundary_tools(directory)
      original = UndoKit::XCFrameworkAssembly.tree_sha256(options[:assembly])
      text, result = candidate_command(options, environment)
      assert result.success?, text
      manifest = JSON.parse(File.read(File.join(options[:output], 'manifest.json')))
      assert_equal '0.2.0', manifest.fetch('releaseVersion')
      assert_equal options[:commit], manifest.fetch('sourceCommit')
      assert_equal original, UndoKit::XCFrameworkAssembly.tree_sha256(options[:assembly])
      assert_equal 'not-yet-qualified', manifest.fetch('qualificationStatus')
      assert_match(/\A[0-9a-f]{64}\z/, manifest.fetch('archiveSHA256'))
      text, result = Open3.capture2e(environment, RbConfig.ruby, '--disable-gems', COMMAND, 'verify', '--candidate', options[:output])
      assert result.success?, text
      assert_includes text, manifest.fetch('candidateID')
    end
  end

  def test_timestamp_failure_retains_original_inputs_and_no_qualified_manifest
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      original = UndoKit::XCFrameworkAssembly.tree_sha256(options[:assembly])
      environment = boundary_tools(directory).merge('UNDOKIT_FIXTURE_NO_TIMESTAMP' => '1')
      text, result = candidate_command(options, environment)
      refute result.success?
      assert_includes text, 'no secure timestamp'
      assert_equal original, UndoKit::XCFrameworkAssembly.tree_sha256(options[:assembly])
      assert File.file?(File.join(options[:output], 'preparation-failure.json'))
      refute File.exist?(File.join(options[:output], 'manifest.json'))
    end
  end

  def test_modified_download_is_rejected_without_resigning_or_repacking
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      environment = boundary_tools(directory)
      text, result = candidate_command(options, environment)
      assert result.success?, text
      manifest = JSON.parse(File.read(File.join(options[:output], 'manifest.json')))
      archive = File.join(options[:output], manifest.fetch('archivePath'))
      File.open(archive, 'ab') { |file| file.write('tampered') }
      before = Digest::SHA256.file(archive).hexdigest
      text, result = Open3.capture2e(environment, RbConfig.ruby, '--disable-gems', COMMAND, 'verify', '--candidate', options[:output])
      refute result.success?
      assert_includes text, 'download ZIP differs'
      assert_equal before, Digest::SHA256.file(archive).hexdigest
    end
  end

  def test_historical_source_only_release_reserves_version_without_inventing_a_binary_build
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      inventory = JSON.parse(File.read(options[:published_inventory]))
      inventory['published'] << {'version' => '0.1.0', 'tag' => '0.1.0', 'sourceCommit' => 'a' * 40,
        'installationRoute' => 'source-only', 'frameworkBuildNumber' => nil, 'archiveSHA256' => nil,
        'evidence' => 'Synthetic source-only release record'}
      File.write(options[:published_inventory], JSON.generate(inventory))
      text, result = candidate_command(options, boundary_tools(directory))
      assert result.success?, text
    end
  end

  def test_documentation_records_standalone_clang_independently_of_swift_embedded_clang
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      text, result = candidate_command(options, boundary_tools(directory))
      assert result.success?, text
      manifest = JSON.parse(File.read(File.join(options[:output], 'manifest.json')))
      assert_equal 'Apple clang version 21.0.0 (clang-2100.3.34.2)', manifest.fetch('documentation').fetch('toolchain').fetch('clang')
      assert_includes manifest.fetch('documentation').fetch('toolchain').fetch('swift'), 'clang-2100.3.34.1'
    end
  end

  def test_failed_final_verification_preserves_an_unverified_manifest
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      environment = boundary_tools(directory)
      # Only the external ZIP executable is replaced: its output is independently
      # rejected by real extraction, proving failure after signing cannot succeed.
      fake = File.join(directory, 'bin', 'ditto')
      File.write(fake, "#!/bin/sh\nif [ \"$1\" = '-c' ]; then touch \"$5\"; else exec /usr/bin/ditto \"$@\"; fi\n")
      File.chmod(0755, fake)
      text, result = candidate_command(options, environment)
      refute result.success?
      assert_includes text, 'ditto failed'
      assert File.file?(File.join(options[:output], 'unverified-manifest.json'))
      refute File.exist?(File.join(options[:output], 'manifest.json'))
      text, result = Open3.capture2e(environment, RbConfig.ruby, '--disable-gems', COMMAND, 'verify', '--candidate', options[:output])
      refute result.success?
      assert_includes text, 'failed preparation cannot be verified'
    end
  end

  def test_known_source_only_framework_build_is_reserved_for_monotonicity
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      options[:build_number] = '1'
      inventory = JSON.parse(File.read(options[:published_inventory]))
      inventory['published'] << {'version' => '0.1.0', 'tag' => '0.1.0', 'sourceCommit' => 'a' * 40,
        'installationRoute' => 'source-only', 'frameworkBuildNumber' => '1', 'archiveSHA256' => nil,
        'evidence' => 'Synthetic git show 0.1.0:Project.xcconfig CURRENT_PROJECT_VERSION = 1'}
      File.write(options[:published_inventory], JSON.generate(inventory))
      text, result = candidate_command(options)
      refute result.success?
      assert_includes text, 'build number must exceed published build 1'
    end
  end

  def test_unsafe_output_never_changes_original_inputs_even_through_a_symlink_parent
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      roots = options.values_at(:source, :assembly, :docs)
      original_hashes = roots.map { |path| UndoKit::XCFrameworkAssembly.tree_sha256(path) }
      alias_path = File.join(directory, 'documentation-alias')
      File.symlink(options[:docs], alias_path)
      unsafe_outputs = roots.map { |path| File.join(path, 'new-attempt') } + [File.join(alias_path, 'nested', 'attempt')]
      unsafe_outputs.each do |unsafe|
        options[:output] = unsafe
        text, result = candidate_command(options)
        refute result.success?
        assert_includes text, 'candidate output must be outside source and input directories'
        refute File.exist?(unsafe), text
        assert_equal original_hashes, roots.map { |path| UndoKit::XCFrameworkAssembly.tree_sha256(path) }
      end
    end
  end

  def test_binary_consumer_verifies_the_full_candidate_before_any_build
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      options = fixture(directory)
      artifacts(options)
      environment = boundary_tools(directory)
      text, result = candidate_command(options, environment)
      assert result.success?, text
      manifest = JSON.parse(File.read(File.join(options[:output], 'manifest.json')))
      archive_path = File.join(options[:output], manifest.fetch('archivePath'))
      original_archive = File.binread(archive_path)
      File.open(archive_path, 'ab') { |file| file.write('tampered') }
      build_marker = File.join(directory, 'build-started')
      xcodebuild = File.join(directory, 'bin', 'xcodebuild')
      File.write(xcodebuild, "#!/bin/sh\ntouch \"#{build_marker}\"\nexit 89\n")
      File.chmod(0755, xcodebuild)
      text, result = Open3.capture2e(environment, RbConfig.ruby, '--disable-gems',
        File.expand_path('../check-binary-consumer.rb', __dir__), '--xcframework', File.join(options[:output], 'UndoKit.xcframework'))
      refute result.success?
      assert_includes text, 'release candidate verification failed'
      assert_includes text, 'download ZIP differs'
      refute File.exist?(build_marker)
      refute File.exist?(File.join(options[:output], 'BinaryConsumerRuns'))
      File.binwrite(archive_path, original_archive)
      text, result = Open3.capture2e(environment.merge('UNDOKIT_FIXTURE_BAD_SIGNATURE' => '1'), RbConfig.ruby, '--disable-gems',
        File.expand_path('../check-binary-consumer.rb', __dir__), '--xcframework', File.join(options[:output], 'UndoKit.xcframework'))
      refute result.success?
      assert_includes text, 'release candidate verification failed'
      assert_includes text, 'synthetic invalid signature'
      refute File.exist?(build_marker)
      refute File.exist?(File.join(options[:output], 'BinaryConsumerRuns'))
    end
  end

  def test_missing_publisher_approval_fails_with_retained_diagnostic
    Dir.mktmpdir('undokit-candidate-test-') do |directory|
      output = File.join(directory, 'attempt')
      text, result = Open3.capture2e(RbConfig.ruby, '--disable-gems', COMMAND, 'prepare', '--output', output)
      refute result.success?
      failure = JSON.parse(File.read(File.join(output, 'preparation-failure.json')))
      assert_includes failure.fetch('error'), 'missing options'
      assert_includes text, 'missing options'
      refute File.exist?(File.join(output, 'manifest.json'))
    end
  end
end
