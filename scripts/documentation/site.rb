#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'pathname'
require 'time'
require 'tmpdir'

module UndoKitDocumentation
  module_function

  def tree_hash(root)
    root = File.expand_path(root)
    entries = Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| ['.', '..'].include?(File.basename(path)) }.sort
    digest = Digest::SHA256.new
    entries.each do |path|
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

  def fail!(message)
    raise ArgumentError, message
  end

  def copy_tree(source, destination)
    FileUtils.mkdir_p(destination)
    Dir.children(source).each do |name|
      from = File.join(source, name)
      to = File.join(destination, name)
      if File.symlink?(from)
        File.symlink(File.readlink(from), to)
      elsif File.directory?(from)
        copy_tree(from, to)
      else
        FileUtils.copy_file(from, to)
      end
    end
  end

  def normalize_root_entrypoint(site, base_path)
    index = File.join(site, 'index.html')
    fail!('static output has no root index.html') unless File.file?(index)
    content = File.read(index)
    content = content.gsub('var baseUrl = "/"', "var baseUrl = \"#{base_path}\"")
    content = content.gsub(/(href|src)=["']\/(?!UndoKit\/)/, "\\1=\"#{base_path}")
    File.write(index, content)
  end

  def add_identity_banner(site, version, source_commit, dirty)
    label = "UndoKit #{dirty ? 'development' : version} · source #{source_commit}#{dirty ? ' · dirty source' : ''}"
    banner = "<aside role=\"note\" style=\"padding:.65rem 1rem;background:#fff3cd;color:#222;font:14px/1.4 sans-serif\">#{label}</aside>"
    Dir.glob(File.join(site, '**', '*.html')).each do |path|
      html = File.read(path)
      html.sub!(/<body([^>]*)>/i) { |opening| "#{opening}#{banner}" }
      File.write(path, html)
    end
  end

  def validate_site(site, base_path)
    fail!('static output is empty') unless File.directory?(site) && !Dir.empty?(site)
    fail!('static output must not contain symlinks') if Dir.glob(File.join(site, '**', '*'), File::FNM_DOTMATCH).any? { |path| File.symlink?(path) }
    html_files = Dir.glob(File.join(site, '**', '*.html'))
    fail!('static output has no HTML entry point') if html_files.empty?
    fail!('static output has no root index.html') unless File.file?(File.join(site, 'index.html'))
    fail!('static output has no DocC search JavaScript') unless Dir.glob(File.join(site, 'js', '*.js')).any?
    fail!('static output has no DocC search index') unless File.file?(File.join(site, 'index', 'index.json')) && File.file?(File.join(site, 'index', 'navigator.index'))

    index = JSON.parse(File.read(File.join(site, 'index', 'index.json')))
    indexed_routes = []
    collect = lambda do |value|
      case value
      when Hash
        indexed_routes << value['path'] if value['path'].is_a?(String) && value['path'].start_with?('/')
        value.each_value { |child| collect.call(child) }
      when Array
        value.each { |child| collect.call(child) }
      end
    end
    collect.call(index)
    fail!('DocC search index contains no topic routes') if indexed_routes.empty?
    indexed_routes.uniq.each do |route|
      route = route.split(/[?#]/, 2).first
      target = File.join(site, route.delete_prefix('/'))
      target += '/index.html' if File.directory?(target)
      fail!("indexed symbol or guide has no deep-refresh page: #{route}") unless File.file?(target)
    end

    html_files.each do |file|
      source = File.read(file)
      source.scan(/(?:href|src)=["']([^"']+)["']/i).flatten.each do |url|
        next if url.start_with?('#', 'data:', 'http:', 'https:', 'mailto:', 'javascript:')
        if url.start_with?('/')
          fail!("absolute link escapes configured base path: #{url}") unless url.start_with?(base_path)
          route = url.delete_prefix(base_path).split(/[?#]/, 2).first
          next if route.empty?
          path = File.join(site, route)
          resolved = File.directory?(path) ? File.join(path, 'index.html') : path
          resolved += '.html' if !File.exist?(resolved) && File.file?(resolved + '.html')
          fail!("deep link has no static target: #{url}") unless File.file?(resolved)
        elsif !url.match?(/^[a-z][a-z0-9+.-]*:/i)
          target = url.split(/[?#]/, 2).first
          next if target.empty?
          resolved = File.expand_path(target, File.dirname(file))
          fail!("relative link escapes static output: #{url}") unless resolved.start_with?(File.expand_path(site) + '/')
          resolved += '/index.html' if File.directory?(resolved)
          fail!("relative link has no static target: #{url} (from #{file.delete_prefix(site + '/')})") unless File.file?(resolved)
        end
      end
    end
  end

  def stage(options)
    required = %i[archive producer output version channel base_path]
    missing = required.reject { |key| options[key] }
    fail!("missing options: #{missing.join(', ')}") unless missing.empty?
    archive = File.expand_path(options[:archive])
    output = File.expand_path(options[:output])
    fail!('archive must be an existing .doccarchive directory') unless archive.end_with?('.doccarchive') && File.directory?(archive)
    producer = JSON.parse(File.read(File.expand_path(options[:producer])))
    fail!('unsupported producer provenance schema') unless producer['schemaVersion'] == 1
    fail!('producer provenance does not match archive bytes') unless producer['archiveTreeSHA256'] == tree_hash(archive)
    source_commit = producer.fetch('sourceCommit')
    fail!('source commit must be a full 40-character SHA') unless source_commit.match?(/\A[0-9a-f]{40}\z/i)
    fail!('dirty source cannot produce release documentation') if options[:channel] == 'release' && producer.fetch('sourceDirty')
    if options[:channel] == 'release'
      fail!('release documentation requires Xcode 27.0 build 27A266a') unless producer.dig('toolchain', 'xcode').match?(/\AXcode 27\.0\nBuild version 27A266a\z/)
      swift = producer.dig('toolchain', 'swift')
      fail!('release documentation requires Apple Swift 6.4 / swiftlang-6.4.0.34.1') unless swift.start_with?('Apple Swift version 6.4 ') && swift.include?('swiftlang-6.4.0.34.1')
      fail!('release documentation must record the selected Xcode clang identity') unless producer.dig('toolchain', 'clang').start_with?('Apple clang version 21.0.0 ')
    end
    fail!('version must be a three-part numeric version') unless options[:version].match?(/\A\d+\.\d+\.\d+\z/)
    fail!('channel must be release or development') unless %w[release development].include?(options[:channel])
    base = options[:base_path]
    fail!('base path must start and end with /') unless base.start_with?('/') && base.end_with?('/') && !base.include?('//')
    expected_base = options[:channel] == 'release' ? "/UndoKit/versions/#{options[:version]}/" : "/UndoKit/development/#{source_commit.downcase}/"
    fail!("base path must be #{expected_base}") unless base == expected_base
    fail!('output already exists; staging never overwrites artifacts') if File.exist?(output)
    parent = File.dirname(output)
    FileUtils.mkdir_p(parent)
    working = Dir.mktmpdir('.undokit-doc-stage-', parent)
    begin
      archive_copy = File.join(working, 'archive')
      copy_tree(archive, archive_copy)
      site = File.join(working, 'site')
      if options[:static_output]
        copy_tree(File.expand_path(options[:static_output]), site)
      else
        command = ['xcrun', 'docc', 'process-archive', 'transform-for-static-hosting', archive_copy,
                   '--output-path', site, '--hosting-base-path', base.delete_suffix('/')]
        _stdout, stderr, status = Open3.capture3(*command)
        fail!("DocC transform failed: #{stderr.strip}") unless status.success?
      end
      normalize_root_entrypoint(site, base)
      add_identity_banner(site, options[:version], source_commit.downcase, producer.fetch('sourceDirty'))
      validate_site(site, base)
      producer_copy = File.join(working, 'producer.json')
      FileUtils.copy_file(File.expand_path(options[:producer]), producer_copy)
      manifest = {
        'schemaVersion' => 1,
        'version' => options[:version],
        'channel' => options[:channel],
        'sourceCommit' => source_commit.downcase,
        'sourceDirty' => producer.fetch('sourceDirty'),
        'basePath' => base,
        'toolchain' => producer.fetch('toolchain'),
        'archivePath' => 'archive',
        'archiveTreeSHA256' => tree_hash(archive_copy),
        'sitePath' => 'site',
        'producerPath' => 'producer.json',
        'producerCommand' => producer.fetch('command'),
        'producerSHA256' => Digest::SHA256.file(producer_copy).hexdigest,
        'siteTreeSHA256' => tree_hash(site)
      }
      File.write(File.join(working, 'manifest.json'), JSON.pretty_generate(manifest) + "\n")
      File.rename(working, output)
    rescue StandardError
      FileUtils.remove_entry(working) if File.exist?(working)
      raise
    end
  end

  def build(options)
    required = %i[source derived_data producer_output]
    missing = required.reject { |key| options[key] }
    fail!("missing options: #{missing.join(', ')}") unless missing.empty?
    source = File.expand_path(options[:source])
    derived = File.expand_path(options[:derived_data])
    output = File.expand_path(options[:producer_output])
    commit, status = Open3.capture2('git', '-C', source, 'rev-parse', 'HEAD')
    fail!('source directory is not a Git checkout') unless status.success?
    commit = commit.strip
    dirty, status = Open3.capture2('git', '-C', source, 'status', '--porcelain')
    fail!('could not inspect source worktree') unless status.success?
    xcode, xcode_status = Open3.capture2('xcodebuild', '-version')
    swift, swift_status = Open3.capture2('xcrun', 'swift', '--version')
    clang, clang_status = Open3.capture2('xcrun', 'clang', '--version')
    fail!('could not capture selected Xcode/Swift/clang toolchain') unless xcode_status.success? && swift_status.success? && clang_status.success?
    command = ['xcodebuild', '-project', 'UndoKit.xcodeproj', '-scheme', 'UndoKit',
               '-destination', 'generic/platform=macOS', '-derivedDataPath', '<derived-data>', 'docbuild']
    _stdout, stderr, result = Open3.capture3(*command.map { |part| part == '<derived-data>' ? derived : part }, chdir: source)
    fail!("docbuild failed: #{stderr.strip}") unless result.success?
    final_commit, final_commit_status = Open3.capture2('git', '-C', source, 'rev-parse', 'HEAD')
    final_dirty, final_dirty_status = Open3.capture2('git', '-C', source, 'status', '--porcelain')
    fail!('could not recheck source checkout after docbuild') unless final_commit_status.success? && final_dirty_status.success?
    fail!('source checkout changed during docbuild') unless final_commit.strip == commit && final_dirty == dirty
    archive = File.join(derived, 'Build', 'Products', 'Debug', 'UndoKit.doccarchive')
    fail!("docbuild produced no archive at #{archive}") unless File.directory?(archive)
    provenance = {
      'schemaVersion' => 1,
      'sourceCommit' => commit,
      'sourceDirty' => !dirty.empty? ,
      'toolchain' => { 'xcode' => xcode.strip, 'swift' => swift.strip, 'clang' => clang.strip },
      'command' => command,
      'archiveTreeSHA256' => tree_hash(archive)
    }
    FileUtils.mkdir_p(File.dirname(output))
    temp = "#{output}.tmp-#{Process.pid}"
    File.write(temp, JSON.pretty_generate(provenance) + "\n")
    File.rename(temp, output)
  end

  def approved_documentation!(manifest, provenance_path)
    fail!('published candidate manifest is required') unless provenance_path
    approved = JSON.parse(File.read(File.expand_path(provenance_path)))
    fail!('unsupported published candidate manifest schema') unless approved.fetch('schemaVersion') == 1
    fail!('published candidate version differs from documentation') unless approved.fetch('releaseVersion') == manifest.fetch('version')
    fail!('published candidate source differs from documentation') unless approved.fetch('sourceCommit') == manifest.fetch('sourceCommit')
    fail!('published candidate documentation identity differs from staged artifact') unless approved.fetch('documentation') == manifest
  end

  def verify_release(manifest, provenance_path)
    fail!('only release documentation can be published') unless manifest.fetch('channel') == 'release'
    fail!('release documentation must come from a clean source checkout') if manifest.fetch('sourceDirty')
    version = manifest.fetch('version')
    fail!('candidate version is invalid') unless version.match?(/\A\d+\.\d+\.\d+\z/)
    fail!('candidate source commit is invalid') unless manifest.fetch('sourceCommit').match?(/\A[0-9a-f]{40}\z/)
    fail!('candidate base path is invalid') unless manifest.fetch('basePath') == "/UndoKit/versions/#{version}/"
    toolchain = manifest.fetch('toolchain')
    fail!('release Xcode identity is not qualified') unless toolchain.fetch('xcode').match?(/\AXcode 27\.0\nBuild version 27A266a\z/)
    fail!('release Swift identity is not qualified') unless toolchain.fetch('swift').start_with?('Apple Swift version 6.4 ') && toolchain.fetch('swift').include?('swiftlang-6.4.0.34.1')
    fail!('release clang identity is missing') unless toolchain.fetch('clang').start_with?('Apple clang version 21.0.0 ')
    approved_documentation!(manifest, provenance_path)
    release_json, release_status = Open3.capture2('gh', 'release', 'view', version, '--json', 'tagName,isDraft,isPrerelease')
    fail!("GitHub release #{version} is unavailable") unless release_status.success?
    release = JSON.parse(release_json)
    fail!('GitHub release is still a draft') if release.fetch('isDraft')
    fail!('GitHub release is not marked as a prerelease') unless release.fetch('isPrerelease')
    tag = release.fetch('tagName')
    fail!('GitHub release tag must match documentation version') unless tag == version
    repository = ENV['GITHUB_REPOSITORY']
    if repository.to_s.empty?
      repository, repository_status = Open3.capture2('gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
      fail!('could not identify the GitHub repository') unless repository_status.success?
      repository = repository.strip
    end
    ref_json, ref_status = Open3.capture2('gh', 'api', "repos/#{repository}/git/ref/tags/#{tag}")
    fail!('could not verify published tag on GitHub') unless ref_status.success?
    object = JSON.parse(ref_json).fetch('object')
    if object.fetch('type') == 'tag'
      tag_json, tag_status = Open3.capture2('gh', 'api', "repos/#{repository}/git/tags/#{object.fetch('sha')}")
      fail!('could not resolve annotated release tag') unless tag_status.success?
      tag_object = JSON.parse(tag_json).fetch('object')
      fail!('release tag does not point directly to a commit') unless tag_object.fetch('type') == 'commit'
      tag_commit = tag_object.fetch('sha')
    else
      tag_commit = object.fetch('sha')
    end
    fail!('published release tag does not match documentation source commit') unless tag_commit == manifest.fetch('sourceCommit')
  end

  def update_latest(options)
    fail!('missing --artifact PATH') unless options[:artifact]
    artifact = File.expand_path(options[:artifact])
    manifest = JSON.parse(File.read(File.join(artifact, 'manifest.json')))
    approved_documentation!(manifest, options[:release_provenance])
    destination = File.expand_path(options.fetch(:destination))
    version = manifest.fetch('version')
    latest_metadata = File.join(destination, 'latest.json')
    if File.file?(latest_metadata)
      latest = JSON.parse(File.read(latest_metadata))
      current_order = latest.fetch('version').split('.').map(&:to_i)
      candidate_order = version.split('.').map(&:to_i)
      fail!('latest release cannot move backward') if (candidate_order <=> current_order).negative?
      if candidate_order == current_order
        fail!('same-version latest correction must retain its source commit') unless latest.fetch('sourceCommit') == manifest.fetch('sourceCommit')
      end
    end
    snapshot = JSON.parse(File.read(File.join(destination, 'versions', version, 'manifest.json')))
    fail!('promoted snapshot does not match candidate identity') unless snapshot.fetch('version') == version && snapshot.fetch('sourceCommit') == manifest.fetch('sourceCommit')
    latest_dir = File.join(destination, 'latest')
    latest_tmp = File.join(destination, ".latest-#{Process.pid}")
    FileUtils.mkdir_p(latest_tmp)
    target_url = "/UndoKit/versions/#{version}/"
    redirect = "<!doctype html><meta http-equiv=\"refresh\" content=\"0; url=#{target_url}\"><title>UndoKit latest documentation</title><a href=\"#{target_url}\">UndoKit #{version}</a>\n"
    File.write(File.join(latest_tmp, 'index.html'), redirect)
    metadata_tmp = File.join(destination, ".latest-metadata-#{Process.pid}")
    File.write(metadata_tmp, JSON.pretty_generate({ version: version, sourceCommit: manifest.fetch('sourceCommit') }) + "\n")
    root_tmp = File.join(destination, ".index-#{Process.pid}")
    landing = "<!doctype html><meta charset=\"utf-8\"><title>UndoKit documentation</title><h1>UndoKit documentation</h1><p>Latest release: <a href=\"/UndoKit/latest/\">#{version}</a>.</p><p><a href=\"#{target_url}\">Browse UndoKit #{version}</a></p>\n"
    File.write(root_tmp, landing)
    if File.exist?(latest_dir)
      backup = File.join(destination, ".latest-backup-#{Process.pid}")
      File.rename(latest_dir, backup)
      begin
        File.rename(latest_tmp, latest_dir)
      rescue StandardError
        File.rename(backup, latest_dir)
        raise
      end
      FileUtils.remove_entry(backup)
    else
      File.rename(latest_tmp, latest_dir)
    end
    File.rename(metadata_tmp, latest_metadata)
    File.rename(root_tmp, File.join(destination, 'index.html'))
  end

  def verify_release_artifact(options)
    fail!('missing --artifact PATH') unless options[:artifact]
    manifest = JSON.parse(File.read(File.join(File.expand_path(options[:artifact]), 'manifest.json')))
    verify_release(manifest, options[:release_provenance])
  end

  def promote(options)
    required = %i[artifact destination]
    missing = required.reject { |key| options[key] }
    fail!("missing options: #{missing.join(', ')}") unless missing.empty?
    artifact = File.expand_path(options[:artifact])
    destination = File.expand_path(options[:destination])
    manifest_path = File.join(artifact, 'manifest.json')
    fail!('artifact manifest is missing') unless File.file?(manifest_path)
    manifest = JSON.parse(File.read(manifest_path))
    fail!('unsupported artifact manifest schema') unless manifest['schemaVersion'] == 1
    fail!('only release candidates can be promoted to Pages') unless manifest['channel'] == 'release' && manifest['sourceDirty'] == false
    version = manifest.fetch('version')
    fail!('candidate version is invalid') unless version.match?(/\A\d+\.\d+\.\d+\z/)
    fail!('candidate source commit is invalid') unless manifest.fetch('sourceCommit').match?(/\A[0-9a-f]{40}\z/)
    fail!('candidate base path is invalid') unless manifest.fetch('basePath') == "/UndoKit/versions/#{version}/"
    approved_documentation!(manifest, options[:release_provenance])
    fail!('artifact paths do not match schema') unless manifest['archivePath'] == 'archive' && manifest['sitePath'] == 'site' && manifest['producerPath'] == 'producer.json'
    archive = File.join(artifact, manifest.fetch('archivePath'))
    site = File.join(artifact, manifest.fetch('sitePath'))
    producer_path = File.join(artifact, manifest.fetch('producerPath'))
    fail!('producer provenance checksum does not match manifest') unless Digest::SHA256.file(producer_path).hexdigest == manifest['producerSHA256']
    producer = JSON.parse(File.read(producer_path))
    fail!('producer provenance does not match manifest identity') unless producer.fetch('sourceCommit') == manifest.fetch('sourceCommit') && producer.fetch('sourceDirty') == manifest.fetch('sourceDirty') && producer.fetch('toolchain') == manifest.fetch('toolchain') && producer.fetch('command') == manifest.fetch('producerCommand')
    fail!('producer provenance does not match archive identity') unless producer.fetch('archiveTreeSHA256') == manifest.fetch('archiveTreeSHA256')
    fail!('archive checksum does not match manifest') unless tree_hash(archive) == manifest['archiveTreeSHA256']
    fail!('site checksum does not match manifest') unless tree_hash(site) == manifest['siteTreeSHA256']
    validate_site(site, manifest.fetch('basePath'))
    releases = File.join(destination, 'versions')
    target = File.join(releases, version)
    fail!('version path escapes destination') unless target.start_with?(releases + '/')
    exists = File.exist?(target)
    if exists
      prior_manifest = File.join(target, 'manifest.json')
      fail!('existing release has no identity manifest') unless File.file?(prior_manifest)
      prior_source = JSON.parse(File.read(prior_manifest)).fetch('sourceCommit')
      fail!('correction must retain the originally published source commit') unless prior_source == manifest.fetch('sourceCommit')
    end
    fail!('existing release is immutable; pass --correction with visible guidance to amend') if exists && options[:correction].to_s.strip.empty?
    FileUtils.mkdir_p(releases)
    temp = Dir.mktmpdir(".#{version}-", releases)
    begin
      copy_tree(site, temp)
      FileUtils.cp(manifest_path, File.join(temp, 'manifest.json'))
      if exists
        history = File.join(destination, 'history', version)
        FileUtils.mkdir_p(history)
        prior = File.join(history, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{manifest.fetch('siteTreeSHA256')[0, 12]}")
        copy_tree(target, prior)
        correction_path = File.join(temp, 'corrections.json')
        prior_corrections = File.join(target, 'corrections.json')
        corrections = File.file?(prior_corrections) ? JSON.parse(File.read(prior_corrections)) : { 'corrections' => [] }
        corrections['corrections'] << { 'date' => Time.now.utc.strftime('%Y-%m-%d'), 'note' => options[:correction].strip,
                                        'sourceCommit' => manifest.fetch('sourceCommit') }
        File.write(File.join(temp, 'corrections.json'), JSON.pretty_generate(corrections) + "\n")
        index_path = File.join(temp, 'index.html')
        index_html = File.read(index_path)
        note = "<aside role=\"note\">Documentation correction: #{options[:correction].strip}</aside>"
        if index_html.match?(%r{</body>}i)
          index_html.sub!(%r{</body>}i, "#{note}</body>")
        else
          index_html = "#{note}\n#{index_html}"
        end
        File.write(index_path, index_html)
      end
      old = "#{target}.previous-#{Process.pid}"
      File.rename(target, old) if exists
      begin
        File.rename(temp, target)
      rescue StandardError
        File.rename(old, target) if exists && File.exist?(old)
        raise
      end
      FileUtils.remove_entry(old) if File.exist?(old)
    rescue StandardError
      FileUtils.remove_entry(temp) if File.exist?(temp)
      raise
    end
  end

  def run(argv)
    command = argv.shift
    options = {}
    parser = OptionParser.new do |flags|
      flags.on('--archive PATH') { |value| options[:archive] = value }
      flags.on('--static-output PATH', 'Use already transformed DocC output (validation/fixture seam)') { |value| options[:static_output] = value }
      flags.on('--output PATH') { |value| options[:output] = value }
      flags.on('--version VERSION') { |value| options[:version] = value }
      flags.on('--channel CHANNEL') { |value| options[:channel] = value }
      flags.on('--producer PATH', 'Provenance JSON emitted by build') { |value| options[:producer] = value }
      flags.on('--base-path PATH') { |value| options[:base_path] = value }
      flags.on('--xcode-version TEXT') { |value| options[:xcode_version] = value }
      flags.on('--swift-version TEXT') { |value| options[:swift_version] = value }
      flags.on('--artifact PATH') { |value| options[:artifact] = value }
      flags.on('--release-provenance PATH', 'Published UndoKit-<version>-manifest.json candidate asset') { |value| options[:release_provenance] = value }
      flags.on('--destination PATH') { |value| options[:destination] = value }
      flags.on('--correction TEXT') { |value| options[:correction] = value }
      flags.on('--source PATH') { |value| options[:source] = value }
      flags.on('--derived-data PATH') { |value| options[:derived_data] = value }
      flags.on('--producer-output PATH') { |value| options[:producer_output] = value }
    end
    parser.parse!(argv)
    case command
    when 'stage' then stage(options)
    when 'build' then build(options)
    when 'promote' then promote(options)
    when 'update-latest' then update_latest(options)
    when 'verify-release' then verify_release_artifact(options)
    else fail!('usage: site.rb stage|promote [options]')
    end
  rescue StandardError => error
    warn "documentation: #{error.message}"
    exit 1
  end
end

UndoKitDocumentation.run(ARGV) if $PROGRAM_NAME == __FILE__
