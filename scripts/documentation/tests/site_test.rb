#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'fileutils'
require 'digest'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class DocumentationSiteTest < Minitest::Test
  CLI = File.expand_path('../site.rb', __dir__)
  SHA = 'a' * 40

  def setup
    @tmp = Dir.mktmpdir('undokit-docs-')
    @archive = File.join(@tmp, 'UndoKit.doccarchive')
    FileUtils.mkdir_p(File.join(@archive, 'data'))
    File.write(File.join(@archive, 'data', 'documentation.json'), '{"topic":"/documentation/undokit"}')
    File.write(File.join(@archive, 'index.html'), '<html>DocC archive</html>')
    @artifact = File.join(@tmp, 'release-artifact')
    @producer = File.join(@tmp, 'producer.json')
    @static = File.join(@tmp, 'static-output')
    create_site(@static)
    create_producer
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def run_cli(*args)
    Open3.capture3('ruby', CLI, *args)
  end

  def tree_hash(root)
    digest = Digest::SHA256.new
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| ['.', '..'].include?(File.basename(path)) }.sort.each do |path|
      relative = path.delete_prefix(root + '/')
      if File.symlink?(path)
        digest.update("L\0#{relative}\0#{File.readlink(path)}\0")
      elsif File.file?(path)
        digest.update("F\0#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0")
      elsif File.directory?(path)
        digest.update("D\0#{relative}\0")
      end
    end
    digest.hexdigest
  end

  def create_producer
    File.write(@producer, JSON.generate({ schemaVersion: 1, sourceCommit: SHA, sourceDirty: false,
      toolchain: { xcode: "Xcode 27.0\nBuild version 27A266a", swift: 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1, clang-2100.3.34.1)', clang: 'Apple clang version 21.0.0 (clang-2100.3.34.1)' }, command: ['xcodebuild', 'docbuild'],
      archiveTreeSHA256: tree_hash(@archive) }))
  end

  def stage_args
    ['stage', '--archive', @archive, '--producer', @producer, '--static-output', @static, '--output', @artifact,
     '--version', '0.2.0', '--channel', 'release', '--base-path', '/UndoKit/versions/0.2.0/']
  end

  def release_provenance
    manifest = JSON.parse(File.read(File.join(@artifact, 'manifest.json')))
    path = File.join(@tmp, 'UndoKit-0.2.0-manifest.json')
    File.write(path, JSON.generate({ schemaVersion: 1, releaseVersion: '0.2.0', sourceCommit: SHA, documentation: manifest }))
    path
  end

  def create_site(site)
    site = File.expand_path(site)
    FileUtils.mkdir_p(File.join(site, 'documentation', 'undokit'))
    FileUtils.mkdir_p(File.join(site, 'js'))
    FileUtils.mkdir_p(File.join(site, 'index'))
    File.write(File.join(site, 'index.html'), '<body><a href="/UndoKit/versions/0.2.0/documentation/undokit">UndoKit</a><script src="/UndoKit/versions/0.2.0/js/search.js"></script>')
    File.write(File.join(site, 'documentation', 'undokit', 'index.html'), '<body><a href="/UndoKit/versions/0.2.0/documentation/undokit/example">Example</a>')
    FileUtils.mkdir_p(File.join(site, 'documentation', 'undokit', 'example'))
    File.write(File.join(site, 'documentation', 'undokit', 'example', 'index.html'), '<body>symbol</body>')
    File.write(File.join(site, 'js', 'search.js'), 'search index')
    File.write(File.join(site, 'index', 'index.json'), JSON.generate({ path: '/documentation/undokit/example' }))
    File.write(File.join(site, 'index', 'navigator.index'), 'navigator index')
  end

  def test_stage_records_identity_and_hashes_generated_public_artifacts
    out, err, status = run_cli(*stage_args)
    assert status.success?, "#{out}\n#{err}"
    manifest = JSON.parse(File.read(File.join(@artifact, 'manifest.json')))
    assert_equal 1, manifest.fetch('schemaVersion')
    assert_equal '0.2.0', manifest.fetch('version')
    assert_equal 'release', manifest.fetch('channel')
    assert_equal SHA, manifest.fetch('sourceCommit')
    assert_equal false, manifest.fetch('sourceDirty')
    assert_equal '/UndoKit/versions/0.2.0/', manifest.fetch('basePath')
    assert_equal "Xcode 27.0\nBuild version 27A266a", manifest.dig('toolchain', 'xcode')
    assert_includes manifest.dig('toolchain', 'swift'), 'swiftlang-6.4.0.34.1'
    assert_includes manifest.dig('toolchain', 'clang'), 'clang-2100.3.34.1'
    assert_equal 64, manifest.fetch('archiveTreeSHA256').length
    assert_equal 64, manifest.fetch('siteTreeSHA256').length
    assert_equal 'archive', manifest.fetch('archivePath')
    assert_equal 'site', manifest.fetch('sitePath')
    assert File.file?(File.join(@artifact, manifest.fetch('producerPath')))
    assert_match(/UndoKit 0.2.0.*source #{SHA}/, File.read(File.join(@artifact, 'site', 'index.html')))
    assert File.file?(File.join(@artifact, 'archive', 'data', 'documentation.json'))
    topic = File.read(File.join(@artifact, 'site', 'documentation', 'undokit', 'example', 'index.html'))
    assert_match(/UndoKit 0.2.0.*source #{SHA}/, topic)
  end

  def test_stage_rejects_dirty_source_for_release
    producer = JSON.parse(File.read(@producer))
    producer['sourceDirty'] = true
    File.write(@producer, JSON.generate(producer))
    _, err, status = run_cli(*stage_args)
    refute status.success?
    assert_match(/dirty source/, err)
    refute File.exist?(@artifact)
  end

  def test_stage_rejects_unresolvable_deep_link
    File.write(File.join(@static, 'documentation', 'undokit', 'index.html'),
               '<a href="/UndoKit/versions/0.2.0/documentation/undokit/missing">Missing</a>')
    _, err, status = run_cli(*stage_args)
    refute status.success?
    assert_match(/deep link has no static target/, err)
    refute File.exist?(@artifact)
  end

  def test_dirty_development_candidate_is_labeled_and_separated
    producer = JSON.parse(File.read(@producer))
    producer['sourceDirty'] = true
    File.write(@producer, JSON.generate(producer))
    development_site = File.join(@tmp, 'development-site')
    FileUtils.cp_r(@static, development_site)
    Dir.glob(File.join(development_site, '**', '*.html')).each do |path|
      html = File.read(path).gsub('/UndoKit/versions/0.2.0/', "/UndoKit/development/#{SHA}/")
      File.write(path, html)
    end
    output = File.join(@tmp, 'development-artifact')
    args = ['stage', '--archive', @archive, '--producer', @producer, '--static-output', development_site,
            '--output', output, '--version', '0.2.0', '--channel', 'development',
            '--base-path', "/UndoKit/development/#{SHA}/"]
    _, err, status = run_cli(*args)
    assert status.success?, err
    manifest = JSON.parse(File.read(File.join(output, 'manifest.json')))
    assert_equal true, manifest.fetch('sourceDirty')
    assert_match(/development.*dirty source/, File.read(File.join(output, 'site', 'index.html')))
  end

  def test_clean_development_candidate_is_explicitly_labeled
    development_site = File.join(@tmp, 'development-site')
    FileUtils.cp_r(@static, development_site)
    Dir.glob(File.join(development_site, '**', '*.html')).each do |path|
      File.write(path, File.read(path).gsub('/UndoKit/versions/0.2.0/', "/UndoKit/development/#{SHA}/"))
    end
    output = File.join(@tmp, 'development-artifact')
    _, err, status = run_cli('stage', '--archive', @archive, '--producer', @producer,
                            '--static-output', development_site, '--output', output,
                            '--version', '0.2.0', '--channel', 'development',
                            '--base-path', "/UndoKit/development/#{SHA}/")
    assert status.success?, err
    html = File.read(File.join(output, 'site', 'index.html'))
    assert_match(/UndoKit development.*source #{SHA}/, html)
    refute_includes html, 'dirty source'
  end

  def test_stage_rejects_caller_supplied_toolchain_identity_flags
    %w[--xcode-version --swift-version].each do |flag|
      _, err, status = run_cli(*stage_args, flag, 'invented identity')
      refute status.success?, "#{flag} must not override producer provenance"
      assert_match(/invalid option/, err)
      refute File.exist?(@artifact)
    end
  end

  def test_verify_release_uses_explicit_repository_from_outside_checkout
    _, _, status = run_cli(*stage_args)
    assert status.success?
    provenance = release_provenance
    bin = File.join(@tmp, 'bin')
    FileUtils.mkdir_p(bin)
    log = File.join(@tmp, 'gh-calls.jsonl')
    fake_gh = File.join(bin, 'gh')
    File.write(fake_gh, <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      File.open(ENV.fetch('GH_CALL_LOG'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
      case ARGV.take(2)
      when ['release', 'view']
        puts JSON.generate({ tagName: '0.2.0', isDraft: false, isPrerelease: true })
      when ['api', 'repos/Folio-Suite/UndoKit/git/ref/tags/0.2.0']
        puts JSON.generate({ object: { type: 'tag', sha: '#{'c' * 40}' } })
      when ['api', 'repos/Folio-Suite/UndoKit/git/tags/#{'c' * 40}']
        puts JSON.generate({ object: { type: 'commit', sha: '#{SHA}' } })
      else
        warn 'unexpected gh arguments'
        exit 1
      end
    RUBY
    FileUtils.chmod(0o755, fake_gh)
    env = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'GH_CALL_LOG' => log,
            'GITHUB_REPOSITORY' => 'unrelated/repository' }
    _, err, status = Open3.capture3(env, 'ruby', CLI, 'verify-release', '--artifact', @artifact,
                                  '--release-provenance', provenance, chdir: @tmp)
    assert status.success?, err
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    assert_includes calls.first.each_cons(2).to_a, ['--repo', 'Folio-Suite/UndoKit']
    assert_equal 3, calls.length
    workflow = File.read(File.expand_path('../../../.github/workflows/documentation.yml', __dir__))
    assert_match(/gh release download .*--repo Folio-Suite\/UndoKit/, workflow)
  end

  def test_promote_keeps_previous_release_when_artifact_checksum_fails
    _, _, status = run_cli(*stage_args)
    assert status.success?
    destination = File.join(@tmp, 'public')
    old = File.join(destination, 'versions', '0.1.0')
    FileUtils.mkdir_p(old)
    File.write(File.join(old, 'keep.txt'), 'previous release')
    File.write(File.join(old, 'manifest.json'), JSON.generate({ sourceCommit: 'b' * 40 }))
    File.write(File.join(@artifact, 'site', 'index.html'), 'tampered')
    provenance = release_provenance
    _, err, status = run_cli('promote', '--artifact', @artifact, '--release-provenance', provenance, '--destination', destination)
    refute status.success?, err
    assert_equal 'previous release', File.read(File.join(old, 'keep.txt'))
    refute File.exist?(File.join(destination, '0.2.0'))
  end

  def test_promote_rejects_artifact_that_differs_from_published_candidate_manifest
    _, _, status = run_cli(*stage_args)
    assert status.success?
    destination = File.join(@tmp, 'public')
    old = File.join(destination, 'versions', '0.1.0')
    FileUtils.mkdir_p(old)
    File.write(File.join(old, 'keep.txt'), 'previous release')
    File.write(File.join(old, 'manifest.json'), JSON.generate({ sourceCommit: 'b' * 40 }))
    provenance = release_provenance
    approved = JSON.parse(File.read(provenance))
    approved['documentation']['siteTreeSHA256'] = '0' * 64
    File.write(provenance, JSON.generate(approved))
    _, err, status = run_cli('promote', '--artifact', @artifact, '--release-provenance', provenance, '--destination', destination)
    refute status.success?
    assert_match(/published candidate documentation identity differs/, err)
    assert_equal 'previous release', File.read(File.join(old, 'keep.txt'))
    refute File.exist?(File.join(destination, 'versions', '0.2.0'))
  end

  def test_promote_requires_visible_correction_for_existing_release_and_retains_prior_snapshot
    _, _, status = run_cli(*stage_args)
    assert status.success?
    destination = File.join(@tmp, 'public')
    FileUtils.mkdir_p(File.join(destination, 'versions', '0.2.0'))
    File.write(File.join(destination, 'versions', '0.2.0', 'old.html'), 'old')
    File.write(File.join(destination, 'versions', '0.2.0', 'manifest.json'), JSON.generate({ sourceCommit: SHA }))
    provenance = release_provenance
    _, _, status = run_cli('promote', '--artifact', @artifact, '--release-provenance', provenance, '--destination', destination)
    refute status.success?
    site_before = Dir.glob(File.join(@artifact, 'site', '**', '*')).select { |p| File.file?(p) }.to_h { |p| [p.delete_prefix(@artifact + '/site/'), Digest::SHA256.file(p).hexdigest] }
    out, err, status = run_cli('promote', '--artifact', @artifact, '--release-provenance', provenance,
                               '--destination', destination, '--correction', 'Corrected a link.')
    assert status.success?, "#{out}\n#{err}"
    site_after = Dir.glob(File.join(destination, 'versions', '0.2.0', '**', '*')).select { |p| File.file?(p) && !%w[corrections.json manifest.json].include?(File.basename(p)) }.to_h { |p| [p.delete_prefix(File.join(destination, 'versions', '0.2.0') + '/'), Digest::SHA256.file(p).hexdigest] }
    assert_equal site_before.keys.sort, site_after.keys.sort
    refute_equal site_before.fetch('index.html'), site_after.fetch('index.html')
    assert_includes File.read(File.join(destination, 'versions', '0.2.0', 'index.html')), 'Documentation correction: Corrected a link.'
    corrections = JSON.parse(File.read(File.join(destination, 'versions', '0.2.0', 'corrections.json')))
    assert_equal ['Corrected a link.'], corrections.fetch('corrections').map { |item| item.fetch('note') }
    refute File.exist?(File.join(destination, 'latest'))
    history = Dir.glob(File.join(destination, 'history', '0.2.0', '*')).first
    assert_equal 'old', File.read(File.join(history, 'old.html'))
  end
end
