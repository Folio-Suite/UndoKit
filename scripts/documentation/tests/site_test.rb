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
      toolchain: { xcode: "Xcode 27.1\nBuild version 27A9275", swift: 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1, clang-2100.3.34.1)', clang: 'Apple clang version 21.0.0 (clang-2100.3.34.1)' }, command: ['xcodebuild', 'docbuild'],
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
    assert_equal "Xcode 27.1\nBuild version 27A9275", manifest.dig('toolchain', 'xcode')
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

  def git_source(*args)
    out, err, status = Open3.capture3('git', '-C', @source, *args)
    assert status.success?, err
    out.strip
  end

  def prepare_correction
    @source = File.join(@tmp, 'source')
    FileUtils.mkdir_p(File.join(@source, 'UndoKit', 'UndoKit.docc'))
    git_source('init', '-q')
    git_source('config', 'user.email', 'docs@example.invalid')
    git_source('config', 'user.name', 'Documentation test')
    File.write(File.join(@source, 'UndoKit', 'UndoKit.docc', 'Guide.md'), 'Original guide')
    File.write(File.join(@source, 'Engine.swift'), 'Original API')
    File.write(File.join(@source, 'Settings.xcconfig'), 'Original settings')
    git_source('add', '.')
    git_source('commit', '-qm', 'Original release')
    @release_sha = git_source('rev-parse', 'HEAD')
    producer = JSON.parse(File.read(@producer))
    producer['sourceCommit'] = @release_sha
    File.write(@producer, JSON.generate(producer))
    _, err, status = run_cli(*stage_args)
    assert status.success?, err
    @released = release_provenance
    released = JSON.parse(File.read(@released))
    released['sourceCommit'] = @release_sha
    File.write(@released, JSON.generate(released))
    @destination = File.join(@tmp, 'public')
    _, err, status = run_cli('promote', '--artifact', @artifact, '--release-provenance', @released, '--destination', @destination)
    assert status.success?, err
    @previous = File.join(@destination, 'versions', '0.2.0')
    @artifact = File.join(@tmp, 'correction-artifact')
    commit_guidance('Corrected installation instruction')
  end

  def commit_guidance(text)
    File.write(File.join(@source, 'UndoKit', 'UndoKit.docc', 'Guide.md'), text)
    git_source('add', '.')
    git_source('commit', '-qm', text)
    @doc_sha = git_source('rev-parse', 'HEAD')
    producer = JSON.parse(File.read(@producer))
    producer['sourceCommit'] = @doc_sha
    File.write(File.join(@archive, 'data', 'documentation.json'), JSON.generate({ guide: text }))
    producer['archiveTreeSHA256'] = tree_hash(@archive)
    File.write(@producer, JSON.generate(producer))
    File.write(File.join(@static, 'documentation', 'undokit', 'example', 'index.html'), "<body>#{text}</body>")
  end

  def correction_stage_args(note = 'Corrected <installation> & guidance.')
    ['stage-correction', '--archive', @archive, '--producer', @producer, '--static-output', @static,
     '--output', @artifact, '--release-provenance', @released, '--source', @source,
     '--previous-snapshot', @previous, '--correction', note]
  end

  def correction_promote_args(approved: true)
    args = ['promote', '--artifact', @artifact, '--release-provenance', @released,
            '--source', @source, '--destination', @destination,
            '--correction-provenance', File.join(@artifact, 'correction-provenance.json')]
    args += ['--approved-correction-sha256', Digest::SHA256.file(File.join(@artifact, 'correction-provenance.json')).hexdigest] if approved
    args
  end

  def test_changed_guidance_requires_external_approval_and_preserves_exact_staged_bytes
    prepare_correction
    _, err, status = run_cli(*correction_stage_args)
    assert status.success?, err
    prior_hash = tree_hash(@destination)
    _, err, status = run_cli(*correction_promote_args(approved: false))
    refute status.success?
    assert_match(/approved correction SHA-256/, err)
    assert_equal prior_hash, tree_hash(@destination)
    _, err, status = run_cli(*correction_promote_args)
    assert status.success?, err
    html = File.read(File.join(@previous, 'documentation', 'undokit', 'example', 'index.html'))
    assert_includes html, 'Corrected installation instruction'
    assert_includes html, @release_sha
    assert_includes html, @doc_sha
    assert_includes html, 'Corrected &lt;installation&gt; &amp; guidance.'
    refute_includes html, 'Corrected <installation>'
    manifest = JSON.parse(File.read(File.join(@previous, 'manifest.json')))
    assert_equal @release_sha, manifest.fetch('sourceCommit')
    assert_equal @doc_sha, manifest.fetch('documentationSourceCommit')
    Dir.glob(File.join(@artifact, 'site', '**', '*')).select { |path| File.file?(path) }.each do |path|
      assert_equal File.binread(path), File.binread(path.sub(File.join(@artifact, 'site'), @previous))
    end
    assert_equal 1, Dir.children(File.join(@destination, 'history', '0.2.0')).length
    hash = tree_hash(@destination)
    _, err, status = run_cli(*correction_promote_args)
    assert status.success?, err
    assert_equal hash, tree_hash(@destination)
  end

  def test_correction_refuses_code_settings_symlinks_and_dirty_checkout
    ['Engine.swift', 'Settings.xcconfig', 'UndoKit/UndoKit.docc/Linked.md'].each do |path|
      prepare_correction
      full = File.join(@source, path)
      if path.end_with?('Linked.md')
        File.symlink('Guide.md', full)
      else
        File.write(full, 'Changed contract')
      end
      git_source('add', '.')
      git_source('commit', '-qm', 'Unsupported correction')
      producer = JSON.parse(File.read(@producer))
      producer['sourceCommit'] = git_source('rev-parse', 'HEAD')
      File.write(@producer, JSON.generate(producer))
      _, err, status = run_cli(*correction_stage_args)
      refute status.success?
      assert_match(/only regular Markdown/, err)
      refute File.exist?(@artifact)
      teardown
      setup
    end
    prepare_correction
    File.write(File.join(@source, 'UndoKit', 'UndoKit.docc', 'Guide.md'), 'Uncommitted guidance')
    _, err, status = run_cli(*correction_stage_args)
    refute status.success?
    assert_match(/clean source checkout/, err)
  end

  def test_correction_refuses_wrong_documentation_or_original_source
    prepare_correction
    producer = JSON.parse(File.read(@producer))
    producer['sourceCommit'] = 'f' * 40
    File.write(@producer, JSON.generate(producer))
    _, err, status = run_cli(*correction_stage_args)
    refute status.success?
    assert_match(/documentation source commit/, err)
    producer['sourceCommit'] = @doc_sha
    File.write(@producer, JSON.generate(producer))
    release = JSON.parse(File.read(@released))
    release['sourceCommit'] = 'f' * 40
    File.write(@released, JSON.generate(release))
    _, err, status = run_cli(*correction_stage_args)
    refute status.success?
    assert_match(/original release/, err)
  end

  def test_correction_refuses_tampered_note_site_or_stale_predecessor_without_changing_output
    prepare_correction
    _, err, status = run_cli(*correction_stage_args)
    assert status.success?, err
    proposal = File.join(@artifact, 'correction-provenance.json')
    approved_sha = Digest::SHA256.file(proposal).hexdigest
    original = File.binread(proposal)
    File.write(proposal, original.sub('Corrected <installation>', 'Changed <installation>'))
    args = correction_promote_args(approved: false) + ['--approved-correction-sha256', approved_sha]
    before = tree_hash(@destination)
    _, err, status = run_cli(*args)
    refute status.success?
    assert_match(/correction provenance checksum/, err)
    assert_equal before, tree_hash(@destination)
    File.binwrite(proposal, original)
    page = File.join(@artifact, 'site', 'index.html')
    original_page = File.binread(page)
    File.write(page, 'tampered site')
    _, err, status = run_cli(*correction_promote_args)
    refute status.success?
    assert_match(/site checksum/, err)
    assert_equal before, tree_hash(@destination)
    File.binwrite(page, original_page)
    File.write(File.join(@previous, 'index.html'), 'newer successful correction')
    before = tree_hash(@destination)
    _, err, status = run_cli(*correction_promote_args)
    refute status.success?
    assert_match(/previous snapshot/, err)
    assert_equal before, tree_hash(@destination)
  end

  def test_successive_corrections_retain_history_and_older_version_does_not_change_latest
    prepare_correction
    _, err, status = run_cli(*correction_stage_args)
    assert status.success?, err
    _, err, status = run_cli(*correction_promote_args)
    assert status.success?, err
    @artifact = File.join(@tmp, 'second-correction')
    commit_guidance('Second corrected installation instruction')
    _, err, status = run_cli(*correction_stage_args('Second correction.'))
    assert status.success?, err
    _, err, status = run_cli(*correction_promote_args)
    assert status.success?, err
    records = JSON.parse(File.read(File.join(@previous, 'corrections.json'))).fetch('corrections')
    assert_equal 2, records.length
    assert_equal 2, Dir.children(File.join(@destination, 'history', '0.2.0')).length
    FileUtils.mkdir_p(File.join(@destination, 'latest'))
    File.write(File.join(@destination, 'latest', 'index.html'), 'newer version latest')
    File.write(File.join(@destination, 'latest.json'), JSON.generate({ version: '0.3.0', sourceCommit: 'e' * 40 }))
    before = tree_hash(@destination)
    args = correction_promote_args.drop(1)
    _, err, status = run_cli('update-latest', *args)
    assert status.success?, err
    assert_equal before, tree_hash(@destination)
  end

  def correction_github_fixture
    bin = File.join(@tmp, 'github-bin')
    FileUtils.mkdir_p(bin)
    fake = File.join(bin, 'gh')
    log = File.join(@tmp, 'correction-gh.jsonl')
    asset_name = "UndoKit-0.2.0-docs-correction-#{Digest::SHA256.file(File.join(@artifact, 'correction-provenance.json')).hexdigest}.json"
    File.write(fake, <<~RUBY)
      #!/usr/bin/env ruby
      require 'json'
      require 'fileutils'
      File.open(ENV.fetch('GH_CALL_LOG'), 'a') { |file| file.puts(JSON.generate(ARGV)) }
      case ARGV.take(2)
      when ['release', 'view']
        if ARGV.last == 'assets'
          puts JSON.generate({ assets: ENV['EXISTING_ASSET'] == 'yes' ? [{ name: '#{asset_name}' }] : [] })
        else
          puts JSON.generate({ tagName: '0.2.0', isDraft: false, isPrerelease: true })
        end
      when ['api', 'repos/Folio-Suite/UndoKit/git/ref/tags/0.2.0']
        puts JSON.generate({ object: { type: 'commit', sha: '#{@release_sha}' } })
      when ['release', 'download']
        destination = ARGV[ARGV.index('--dir') + 1]
        path = File.join(destination, '#{asset_name}')
        FileUtils.copy_file(ENV.fetch('ASSET_CONTENT'), path)
      when ['release', 'upload']
        exit 0
      else
        warn 'unexpected gh arguments'
        exit 1
      end
    RUBY
    FileUtils.chmod(0o755, fake)
    [{ 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'GH_CALL_LOG' => log,
       'ASSET_CONTENT' => File.join(@artifact, 'correction-provenance.json') }, log, asset_name]
  end

  def test_correction_provenance_is_an_additive_immutable_asset_with_exact_retry
    prepare_correction
    _, err, status = run_cli(*correction_stage_args)
    assert status.success?, err
    env, log, asset_name = correction_github_fixture
    args = correction_promote_args.drop(1)
    out, err, status = Open3.capture3(env, 'ruby', CLI, 'publish-correction-provenance', *args)
    assert status.success?, err
    assert_equal asset_name, out.strip
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    upload = calls.find { |call| call.take(2) == ['release', 'upload'] }
    assert_equal asset_name, File.basename(upload.fetch(3))
    assert_includes upload.each_cons(2).to_a, ['--repo', 'Folio-Suite/UndoKit']
    refute_includes upload, '--clobber'
    File.write(log, '')
    _, err, status = Open3.capture3(env.merge('EXISTING_ASSET' => 'yes'), 'ruby', CLI, 'publish-correction-provenance', *args)
    assert status.success?, err
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    refute calls.any? { |call| call.take(2) == ['release', 'upload'] }
    assert calls.any? { |call| call.take(2) == ['release', 'download'] }
    wrong = File.join(@tmp, 'wrong-asset.json')
    File.write(wrong, '{}')
    File.write(log, '')
    _, err, status = Open3.capture3(env.merge('EXISTING_ASSET' => 'yes', 'ASSET_CONTENT' => wrong), 'ruby', CLI, 'publish-correction-provenance', *args)
    refute status.success?
    assert_match(/existing immutable correction asset differs/, err)
    calls = File.readlines(log).map { |line| JSON.parse(line) }
    refute calls.any? { |call| call.take(2) == ['release', 'upload'] }
  end

  def test_correction_promotion_rechecks_source_and_original_release_bytes
    prepare_correction
    _, err, status = run_cli(*correction_stage_args)
    assert status.success?, err
    before = tree_hash(@destination)
    File.write(@released, File.read(@released) + "\n")
    _, err, status = run_cli(*correction_promote_args)
    refute status.success?
    assert_match(/correction provenance does not match original release/, err)
    assert_equal before, tree_hash(@destination)
    File.write(@released, File.read(@released).delete_suffix("\n"))
    File.write(File.join(@source, 'Engine.swift'), 'Uncommitted API edit')
    _, err, status = run_cli(*correction_promote_args)
    refute status.success?
    assert_match(/clean source checkout/, err)
    assert_equal before, tree_hash(@destination)
  end

end
