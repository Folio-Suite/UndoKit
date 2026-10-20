# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'json'
require 'digest'
require_relative 'site'

class DocumentationReleaseAssetTest < Minitest::Test
  COMMAND = File.expand_path('release-asset.rb', __dir__)

  def fixture(root)
    artifact = File.join(root, 'candidate')
    %w[archive site].each { |name| FileUtils.mkdir_p(File.join(artifact, name)) }
    File.write(File.join(artifact, 'archive', 'archive-data'), 'original archive')
    FileUtils.mkdir_p(File.join(artifact, 'archive', 'empty-directory'))
    site = File.join(artifact, 'site')
    FileUtils.mkdir_p(File.join(site, 'js'))
    FileUtils.mkdir_p(File.join(site, 'index'))
    File.write(File.join(site, 'index.html'), '<html><body>site</body></html>')
    File.write(File.join(site, 'js', 'search.js'), 'search')
    File.write(File.join(site, 'index', 'index.json'), '{"path":"/documentation/undokit/"}')
    File.write(File.join(site, 'index', 'navigator.index'), 'search-index')
    FileUtils.mkdir_p(File.join(site, 'documentation', 'undokit'))
    File.write(File.join(site, 'documentation', 'undokit', 'index.html'), '<html><body>docs</body></html>')
    toolchain = {'xcode' => "Xcode 27.1\nBuild version 27A9275", 'swift' => 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)', 'clang' => 'Apple clang version 21.0.0 (clang-2100.3.34.2)'}
    producer = {'schemaVersion' => 1, 'sourceCommit' => 'a' * 40, 'sourceDirty' => false, 'toolchain' => toolchain,
                'command' => ['xcodebuild', 'docbuild'], 'archiveTreeSHA256' => UndoKitDocumentation.tree_hash(File.join(artifact, 'archive'))}
    File.write(File.join(artifact, 'producer.json'), JSON.generate(producer))
    manifest = {'schemaVersion' => 1, 'version' => '0.2.2', 'channel' => 'release', 'sourceCommit' => 'a' * 40,
      'sourceDirty' => false, 'basePath' => '/UndoKit/versions/0.2.2/', 'toolchain' => toolchain,
      'archivePath' => 'archive', 'archiveTreeSHA256' => producer['archiveTreeSHA256'], 'sitePath' => 'site',
      'producerPath' => 'producer.json', 'producerCommand' => producer['command'],
      'producerSHA256' => Digest::SHA256.file(File.join(artifact, 'producer.json')).hexdigest,
      'siteTreeSHA256' => UndoKitDocumentation.tree_hash(site)}
    File.write(File.join(artifact, 'manifest.json'), JSON.generate(manifest))
    provenance = File.join(root, 'UndoKit-0.2.2-manifest.json')
    File.write(provenance, JSON.generate({'schemaVersion' => 1, 'releaseVersion' => '0.2.2', 'sourceCommit' => 'a' * 40, 'documentation' => manifest}))
    [artifact, provenance]
  end

  def command(artifact, provenance, output)
    Open3.capture2e(RbConfig.ruby, '--disable-gems', COMMAND, '--artifact', artifact,
                    '--release-provenance', provenance, '--output', output)
  end

  def test_packages_original_candidate_root_and_preserves_empty_directories
    Dir.mktmpdir('undokit-release-asset-') do |root|
      artifact, provenance = fixture(root)
      output = File.join(root, 'UndoKit-0.2.2-documentation.tar.gz')
      text, status = command(artifact, provenance, output)
      assert status.success?, text
      listing, list_status = Open3.capture2('tar', '-tzf', output)
      assert list_status.success?
      %w[archive/ site/ producer.json manifest.json].each { |entry| assert_includes listing.lines.map(&:chomp), entry }
      assert_includes listing, 'archive/empty-directory/'
      refute listing.lines.any? { |entry| entry.include?('candidate/') }
    end
  end

  def test_rejects_tampered_site_and_existing_output
    Dir.mktmpdir('undokit-release-asset-') do |root|
      artifact, provenance = fixture(root)
      File.write(File.join(artifact, 'site', 'index.html'), 'tampered')
      output = File.join(root, 'asset.tar.gz')
      text, status = command(artifact, provenance, output)
      refute status.success?
      assert_includes text, 'site checksum does not match manifest'
      refute File.exist?(output)
    end
  end
end
