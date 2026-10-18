#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'optparse'
require 'open3'
require 'tmpdir'

module UndoKitDocumentation
  module_function

  def tree_hash(root, except: [])
    root = File.expand_path(root)
    entries = Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| ['.', '..'].include?(File.basename(path)) }.sort
    digest = Digest::SHA256.new
    entries.each do |path|
      relative = path.delete_prefix(root + '/')
      next if except.include?(relative)
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
    target = "#{base_path}documentation/undokit/"
    content = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0; url=#{target}\"><title>UndoKit documentation</title></head><body><p><a href=\"#{target}\">Browse UndoKit documentation</a></p></body></html>\n"
    File.write(index, content)
  end

  def add_identity_banner(site, version, channel, source_commit, dirty, correction = nil)
    label = "UndoKit #{channel == 'development' ? 'development' : version} · source #{source_commit}#{dirty ? ' · dirty source' : ''}"
    if correction
      label += " · documentation source #{correction.fetch('documentationSourceCommit')}"
      label += " · Documentation correction: #{correction.fetch('note')}"
    end
    banner = "<aside role=\"note\" style=\"padding:.65rem 1rem;background:#fff3cd;color:#222;font:14px/1.4 sans-serif\">#{CGI.escapeHTML(label)}</aside>"
    Dir.glob(File.join(site, '**', '*.html')).each do |path|
      html = File.read(path)
      inserted = html.sub!(/<body([^>]*)>/i) { |opening| "#{opening}#{banner}" }
      html = banner + html unless inserted
      File.write(path, html)
    end
  end

  def original_release!(path)
    fail!('published candidate manifest is required') unless path
    release = JSON.parse(File.read(File.expand_path(path)))
    fail!('unsupported published candidate manifest schema') unless release.fetch('schemaVersion') == 1
    original = release.fetch('documentation')
    fail!('original release source does not match its documentation') unless release.fetch('sourceCommit') == original.fetch('sourceCommit')
    fail!('original release version does not match its documentation') unless release.fetch('releaseVersion') == original.fetch('version')
    fail!('original release must contain an uncorrected release snapshot') unless original.fetch('channel') == 'release' && !original.key?('documentationSourceCommit')
    release
  end

  def correction_source!(source, release_source, documentation_source)
    fail!('correction requires --source documentation checkout') unless source
    source = File.expand_path(source)
    head, head_status = Open3.capture2('git', '-C', source, 'rev-parse', 'HEAD')
    fail!('documentation source commit does not match checkout') unless head_status.success? && head.strip == documentation_source
    dirty, dirty_status = Open3.capture2('git', '-C', source, 'status', '--porcelain')
    fail!('correction requires a clean source checkout') unless dirty_status.success? && dirty.empty?
    _, ancestry_status = Open3.capture2('git', '-C', source, 'merge-base', '--is-ancestor', release_source, documentation_source)
    fail!('original release source must be an ancestor of documentation source') unless ancestry_status.success?
    diff, diff_status = Open3.capture2('git', '-C', source, 'diff', '--raw', '--no-abbrev', '--no-renames', '-z', release_source, documentation_source)
    fail!('could not inspect complete documentation source diff') unless diff_status.success?
    changes = diff.split("\0")
    fail!('correction must change guidance Markdown') if changes.empty?
    changes.each_slice(2) do |header, path|
      modes = header.to_s.split.take(2).map { |mode| mode.delete_prefix(':') }
      allowed = path && path.start_with?('UndoKit/UndoKit.docc/') && path.end_with?('.md')
      allowed &&= modes.length == 2 && modes.all? { |mode| %w[000000 100644 100755].include?(mode) }
      fail!("correction allows only regular Markdown under UndoKit/UndoKit.docc: #{path}") unless allowed
    end
  end

  def stage_correction(options)
    release = original_release!(options[:release_provenance])
    producer = JSON.parse(File.read(File.expand_path(options.fetch(:producer))))
    fail!('correction requires clean producer provenance') unless producer.fetch('sourceDirty') == false
    documentation_source = producer.fetch('sourceCommit')
    correction_source!(options[:source], release.fetch('sourceCommit'), documentation_source)
    fail!('correction requires --previous-snapshot PATH') unless options[:previous_snapshot]
    previous = File.expand_path(options[:previous_snapshot])
    prior_manifest = JSON.parse(File.read(File.join(previous, 'manifest.json')))
    fail!('previous snapshot does not match original release') unless prior_manifest.fetch('version') == release.fetch('releaseVersion') && prior_manifest.fetch('sourceCommit') == release.fetch('sourceCommit')
    fail!('previous snapshot bytes do not match its manifest') unless snapshot_matches?(previous, prior_manifest)
    note = options[:correction].to_s.strip
    fail!('correction requires a visible note') if note.empty?
    context = {
      'version' => release.fetch('releaseVersion'),
      'releaseSourceCommit' => release.fetch('sourceCommit'),
      'releaseManifestSHA256' => Digest::SHA256.file(options[:release_provenance]).hexdigest,
      'documentationSourceCommit' => documentation_source,
      'previousSnapshotSHA256' => tree_hash(previous),
      'note' => note
    }
    prior_records = File.join(previous, 'corrections.json')
    records = File.file?(prior_records) ? JSON.parse(File.read(prior_records)) : { 'corrections' => [] }
    records.fetch('corrections') << { 'note' => note, 'sourceCommit' => release.fetch('sourceCommit'),
                                    'documentationSourceCommit' => documentation_source,
                                    'previousSnapshotSHA256' => context.fetch('previousSnapshotSHA256') }
    stage(options.merge(version: release.fetch('releaseVersion'), channel: 'release',
                        base_path: "/UndoKit/versions/#{release.fetch('releaseVersion')}/",
                        correction_context: context, correction_records: records))
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
    correction = options[:correction_context]
    fail!('source commit must be a full 40-character SHA') unless source_commit.match?(/\A[0-9a-f]{40}\z/i)
    fail!('dirty source cannot produce release documentation') if options[:channel] == 'release' && producer.fetch('sourceDirty')
    if options[:channel] == 'release'
      fail!('release documentation requires Xcode 27.1 build 27A9275') unless producer.dig('toolchain', 'xcode').match?(/\AXcode 27\.1\nBuild version 27A9275\z/)
      swift = producer.dig('toolchain', 'swift')
      fail!('release documentation requires Apple Swift 6.4 / swiftlang-6.4.0.34.1') unless swift.start_with?('Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)')
      fail!('release documentation must record the selected Xcode clang identity') unless producer.dig('toolchain', 'clang').start_with?('Apple clang version 21.0.0 (clang-2100.3.34.2)')
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
      fail!('static output uses reserved manifest.json path') if File.exist?(File.join(site, 'manifest.json'))
      if correction
        File.write(File.join(site, 'corrections.json'), JSON.pretty_generate(options.fetch(:correction_records)) + "\n")
      end
      add_identity_banner(site, options[:version], options[:channel], correction ? correction.fetch('releaseSourceCommit') : source_commit.downcase, producer.fetch('sourceDirty'), correction)
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
      if correction
        manifest['sourceCommit'] = correction.fetch('releaseSourceCommit')
        manifest['documentationSourceCommit'] = correction.fetch('documentationSourceCommit')
        manifest['releaseManifestSHA256'] = correction.fetch('releaseManifestSHA256')
        manifest['previousSnapshotSHA256'] = correction.fetch('previousSnapshotSHA256')
        manifest['correctionNote'] = correction.fetch('note')
        proposal = { 'schemaVersion' => 1 }.merge(correction).merge('documentation' => manifest)
        File.write(File.join(working, 'correction-provenance.json'), JSON.pretty_generate(proposal) + "\n")
        correction_source!(options[:source], manifest.fetch('sourceCommit'), manifest.fetch('documentationSourceCommit'))
      end
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
    if ENV['GITHUB_ACTIONS'] == 'true'
      revision = 'ef7d692fc6706e8f5628e26bcafaefa445c58a97'
      resolved_path = File.join(source, 'UndoKit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
      resolved = JSON.parse(File.read(resolved_path))
      pin = resolved.fetch('pins').find { |item| item.fetch('identity') == 'swiftlintplugins' }
      fail!('Review SwiftLint plugin trust after changing its dependency pin') unless
        pin && pin.fetch('state').fetch('revision') == revision &&
        pin.fetch('location') == 'https://github.com/SimplyDanny/SwiftLintPlugins'
      command << '-skipPackagePluginValidation'
      command.concat(['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY='])
    end
    actual_command = command.map { |part| part == '<derived-data>' ? derived : part }
    stdout, stderr, result = Open3.capture3(*actual_command, chdir: source)
    diagnostic_path = "#{output}.docbuild.log"
    FileUtils.mkdir_p(File.dirname(diagnostic_path))
    File.write(diagnostic_path, JSON.pretty_generate(
      'command' => actual_command,
      'exitStatus' => result.exitstatus,
      'stdout' => stdout,
      'stderr' => stderr
    ) + "\n")
    unless result.success?
      output_text = [stdout, stderr].reject(&:empty?).join("\n")
      fail!("docbuild failed (exit #{result.exitstatus}); full command output: #{diagnostic_path}\n#{output_text}")
    end
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

  def approved_documentation!(manifest, provenance_path, options = {})
    approved = original_release!(provenance_path)
    fail!('published candidate version differs from documentation') unless approved.fetch('releaseVersion') == manifest.fetch('version')
    fail!('published candidate source differs from documentation') unless approved.fetch('sourceCommit') == manifest.fetch('sourceCommit')
    if manifest.key?('documentationSourceCommit')
      expected = options[:approved_correction_sha256].to_s
      fail!('maintainer-approved correction SHA-256 is required') unless expected.match?(/\A[0-9a-f]{64}\z/)
      path = options[:correction_provenance]
      fail!('correction provenance is required') unless path
      fail!('correction provenance checksum differs from approved SHA-256') unless Digest::SHA256.file(path).hexdigest == expected
      proposal = JSON.parse(File.read(path))
      bound = {
        'schemaVersion' => 1, 'version' => manifest.fetch('version'),
        'releaseSourceCommit' => manifest.fetch('sourceCommit'),
        'releaseManifestSHA256' => Digest::SHA256.file(provenance_path).hexdigest,
        'documentationSourceCommit' => manifest.fetch('documentationSourceCommit'),
        'previousSnapshotSHA256' => manifest.fetch('previousSnapshotSHA256'),
        'note' => manifest.fetch('correctionNote'), 'documentation' => manifest
      }
      fail!('correction provenance does not match original release and full corrected artifact') unless proposal == bound && manifest.fetch('releaseManifestSHA256') == bound.fetch('releaseManifestSHA256')
      correction_source!(options[:source], manifest.fetch('sourceCommit'), manifest.fetch('documentationSourceCommit'))
    else
      fail!('published candidate documentation identity differs from staged artifact') unless approved.fetch('documentation') == manifest
    end
  end

  def verify_release(manifest, provenance_path, options = {})
    fail!('only release documentation can be published') unless manifest.fetch('channel') == 'release'
    fail!('release documentation must come from a clean source checkout') if manifest.fetch('sourceDirty')
    version = manifest.fetch('version')
    fail!('candidate version is invalid') unless version.match?(/\A\d+\.\d+\.\d+\z/)
    fail!('candidate source commit is invalid') unless manifest.fetch('sourceCommit').match?(/\A[0-9a-f]{40}\z/)
    fail!('candidate base path is invalid') unless manifest.fetch('basePath') == "/UndoKit/versions/#{version}/"
    toolchain = manifest.fetch('toolchain')
    fail!('release Xcode identity is not qualified') unless toolchain.fetch('xcode').match?(/\AXcode 27\.1\nBuild version 27A9275\z/)
    fail!('release Swift identity is not qualified') unless toolchain.fetch('swift').start_with?('Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)')
    fail!('release clang identity is missing') unless toolchain.fetch('clang').start_with?('Apple clang version 21.0.0 (clang-2100.3.34.2)')
    approved_documentation!(manifest, provenance_path, options)
    release_json, release_status = Open3.capture2('gh', 'release', 'view', version, '--repo', 'Folio-Suite/UndoKit', '--json', 'tagName,isDraft,isPrerelease')
    fail!("GitHub release #{version} is unavailable") unless release_status.success?
    release = JSON.parse(release_json)
    fail!('GitHub release is still a draft') if release.fetch('isDraft')
    fail!('GitHub release is not marked as a prerelease') unless release.fetch('isPrerelease')
    tag = release.fetch('tagName')
    fail!('GitHub release tag must match documentation version') unless tag == version
    repository = 'Folio-Suite/UndoKit'
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

  def snapshot_matches?(target, manifest)
    path = File.join(target, 'manifest.json')
    File.file?(path) && JSON.parse(File.read(path)) == manifest && tree_hash(target, except: ['manifest.json']) == manifest.fetch('siteTreeSHA256')
  end

  def update_latest(options)
    fail!('missing --artifact PATH') unless options[:artifact]
    artifact = File.expand_path(options[:artifact])
    manifest = JSON.parse(File.read(File.join(artifact, 'manifest.json')))
    approved_documentation!(manifest, options[:release_provenance], options)
    validate_artifact!(artifact, manifest)
    destination = File.expand_path(options.fetch(:destination))
    version = manifest.fetch('version')
    latest_metadata = File.join(destination, 'latest.json')
    if File.file?(latest_metadata)
      latest = JSON.parse(File.read(latest_metadata))
      current_order = latest.fetch('version').split('.').map(&:to_i)
      candidate_order = version.split('.').map(&:to_i)
      if (candidate_order <=> current_order).negative?
        return if manifest.key?('documentationSourceCommit') && snapshot_matches?(File.join(destination, 'versions', version), manifest)
        fail!('latest release cannot move backward')
      end
      if candidate_order == current_order
        fail!('same-version latest correction must retain its source commit') unless latest.fetch('sourceCommit') == manifest.fetch('sourceCommit')
      end
    end
    fail!('promoted snapshot does not match complete candidate identity') unless snapshot_matches?(File.join(destination, 'versions', version), manifest)
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

  def validate_artifact!(artifact, manifest)
    fail!('artifact paths do not match schema') unless manifest['archivePath'] == 'archive' && manifest['sitePath'] == 'site' && manifest['producerPath'] == 'producer.json'
    archive = File.join(artifact, manifest.fetch('archivePath'))
    site = File.join(artifact, manifest.fetch('sitePath'))
    producer_path = File.join(artifact, manifest.fetch('producerPath'))
    fail!('producer provenance checksum does not match manifest') unless Digest::SHA256.file(producer_path).hexdigest == manifest['producerSHA256']
    producer = JSON.parse(File.read(producer_path))
    fail!('producer provenance does not match manifest identity') unless producer.fetch('sourceCommit') == manifest.fetch('documentationSourceCommit', manifest.fetch('sourceCommit')) && producer.fetch('sourceDirty') == manifest.fetch('sourceDirty') && producer.fetch('toolchain') == manifest.fetch('toolchain') && producer.fetch('command') == manifest.fetch('producerCommand')
    fail!('producer provenance does not match archive identity') unless producer.fetch('archiveTreeSHA256') == manifest.fetch('archiveTreeSHA256')
    fail!('archive checksum does not match manifest') unless tree_hash(archive) == manifest['archiveTreeSHA256']
    fail!('site checksum does not match manifest') unless tree_hash(site) == manifest['siteTreeSHA256']
    validate_site(site, manifest.fetch('basePath'))
  end

  def verify_release_artifact(options)
    fail!('missing --artifact PATH') unless options[:artifact]
    artifact = File.expand_path(options[:artifact])
    manifest = JSON.parse(File.read(File.join(artifact, 'manifest.json')))
    validate_artifact!(artifact, manifest)
    verify_release(manifest, options[:release_provenance], options)
  end

  def publish_correction_provenance(options)
    verify_release_artifact(options)
    artifact = File.expand_path(options.fetch(:artifact))
    manifest = JSON.parse(File.read(File.join(artifact, 'manifest.json')))
    fail!('only a corrected artifact has additive correction provenance') unless manifest.key?('documentationSourceCommit')
    version = manifest.fetch('version')
    name = "UndoKit-#{version}-docs-correction-#{options.fetch(:approved_correction_sha256)}.json"
    assets_json, status = Open3.capture2('gh', 'release', 'view', version, '--repo', 'Folio-Suite/UndoKit', '--json', 'assets')
    fail!('could not inspect existing release correction assets') unless status.success?
    assets = JSON.parse(assets_json).fetch('assets')
    Dir.mktmpdir('undokit-correction-asset-') do |temp|
      if assets.any? { |asset| asset.fetch('name') == name }
        _, _, downloaded = Open3.capture3('gh', 'release', 'download', version, '--repo', 'Folio-Suite/UndoKit', '--pattern', name, '--dir', temp)
        fail!('could not verify retained correction provenance asset') unless downloaded.success?
        fail!('existing immutable correction asset differs') unless File.binread(File.join(temp, name)) == File.binread(options.fetch(:correction_provenance))
      else
        path = File.join(temp, name)
        FileUtils.copy_file(options.fetch(:correction_provenance), path)
        _, stderr, uploaded = Open3.capture3('gh', 'release', 'upload', version, path, '--repo', 'Folio-Suite/UndoKit')
        fail!("correction provenance upload failed: #{stderr.strip}") unless uploaded.success?
      end
    end
    puts name
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
    approved_documentation!(manifest, options[:release_provenance], options)
    validate_artifact!(artifact, manifest)
    site = File.join(artifact, manifest.fetch('sitePath'))
    releases = File.join(destination, 'versions')
    target = File.join(releases, version)
    fail!('version path escapes destination') unless target.start_with?(releases + '/')
    exists = File.exist?(target)
    if exists && snapshot_matches?(target, manifest)
      return
    end
    corrected = manifest.key?('documentationSourceCommit')
    if corrected
      fail!('previous snapshot differs from correction predecessor') unless exists && tree_hash(target) == manifest.fetch('previousSnapshotSHA256')
    elsif exists
      fail!('existing release is immutable; stage an approved guidance correction')
    end
    FileUtils.mkdir_p(releases)
    temp = Dir.mktmpdir(".#{version}-", releases)
    begin
      copy_tree(site, temp)
      FileUtils.cp(manifest_path, File.join(temp, 'manifest.json'))
      if exists
        history = File.join(destination, 'history', version)
        FileUtils.mkdir_p(history)
        prior = File.join(history, manifest.fetch('previousSnapshotSHA256'))
        if File.exist?(prior)
          fail!('retained previous snapshot identity differs') unless tree_hash(prior) == manifest.fetch('previousSnapshotSHA256')
        else
          copy_tree(target, prior)
        end
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
      flags.on('--artifact PATH') { |value| options[:artifact] = value }
      flags.on('--release-provenance PATH', 'Published UndoKit-<version>-manifest.json candidate asset') { |value| options[:release_provenance] = value }
      flags.on('--destination PATH') { |value| options[:destination] = value }
      flags.on('--correction TEXT') { |value| options[:correction] = value }
      flags.on('--previous-snapshot PATH') { |value| options[:previous_snapshot] = value }
      flags.on('--correction-provenance PATH') { |value| options[:correction_provenance] = value }
      flags.on('--approved-correction-sha256 SHA256') { |value| options[:approved_correction_sha256] = value }
      flags.on('--source PATH') { |value| options[:source] = value }
      flags.on('--derived-data PATH') { |value| options[:derived_data] = value }
      flags.on('--producer-output PATH') { |value| options[:producer_output] = value }
    end
    parser.parse!(argv)
    fail!('--correction is only valid for stage-correction') if options[:correction] && command != 'stage-correction'
    case command
    when 'stage' then stage(options)
    when 'stage-correction' then stage_correction(options)
    when 'build' then build(options)
    when 'promote' then promote(options)
    when 'update-latest' then update_latest(options)
    when 'verify-release' then verify_release_artifact(options)
    when 'publish-correction-provenance' then publish_correction_provenance(options)
    else fail!('usage: site.rb build|stage|stage-correction|verify-release|promote|update-latest [options]')
    end
  rescue StandardError => error
    warn "documentation: #{error.message}"
    exit 1
  end
end

UndoKitDocumentation.run(ARGV) if $PROGRAM_NAME == __FILE__
