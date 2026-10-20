#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'fileutils'
require 'optparse'
require 'tmpdir'
require_relative 'site'

module UndoKitDocumentationReleaseAsset
  module_function

  def package(options)
    required = %i[artifact release_provenance output]
    missing = required.reject { |key| options[key] }
    UndoKitDocumentation.fail!("missing options: #{missing.join(', ')}") unless missing.empty?

    artifact = File.expand_path(options.fetch(:artifact))
    output = File.expand_path(options.fetch(:output))
    UndoKitDocumentation.fail!('candidate must be a directory') unless File.directory?(artifact)
    UndoKitDocumentation.fail!('output already exists; release assets are immutable') if File.exist?(output) || File.symlink?(output)
    UndoKitDocumentation.fail!('output must be outside candidate directory') if output == artifact || output.start_with?(artifact + '/')
    entries = Dir.children(artifact).sort
    expected = %w[archive manifest.json producer.json site]
    UndoKitDocumentation.fail!('candidate must contain only archive, site, producer.json, and manifest.json') unless entries == expected

    manifest_path = File.join(artifact, 'manifest.json')
    UndoKitDocumentation.fail!('candidate manifest is missing') unless File.file?(manifest_path) && !File.symlink?(manifest_path)
    manifest = JSON.parse(File.read(manifest_path))
    UndoKitDocumentation.fail!('unsupported artifact manifest schema') unless manifest.fetch('schemaVersion') == 1
    UndoKitDocumentation.fail!('only an original release candidate can be packaged') unless manifest.fetch('channel') == 'release' && !manifest.key?('documentationSourceCommit')
    UndoKitDocumentation.fail!('release documentation must come from a clean source checkout') unless manifest.fetch('sourceDirty') == false

    UndoKitDocumentation.approved_documentation!(manifest, options.fetch(:release_provenance))
    UndoKitDocumentation.validate_artifact!(artifact, manifest)
    [File.join(artifact, 'archive'), File.join(artifact, 'site')].each do |root|
      UndoKitDocumentation.fail!('candidate archive and site must be directories') unless File.directory?(root) && !File.symlink?(root)
      paths = Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| %w[. ..].include?(File.basename(path)) }
      unsafe = paths.find { |path| File.symlink?(path) || (!File.file?(path) && !File.directory?(path)) }
      UndoKitDocumentation.fail!("candidate contains a symlink or special file: #{unsafe}") if unsafe
    end
    producer_path = File.join(artifact, 'producer.json')
    UndoKitDocumentation.fail!('producer provenance must be a regular file') unless File.file?(producer_path) && !File.symlink?(producer_path)

    FileUtils.mkdir_p(File.dirname(output))
    Dir.mktmpdir('.undokit-release-asset-', File.dirname(output)) do |temporary_directory|
      temporary_archive = File.join(temporary_directory, File.basename(output))
      _stdout, stderr, status = Open3.capture3({'COPYFILE_DISABLE' => '1'}, 'tar', '-czf', temporary_archive, '-C', artifact,
                                                'archive', 'site', 'producer.json', 'manifest.json')
      UndoKitDocumentation.fail!("tar packaging failed: #{stderr.strip}") unless status.success?
      File.rename(temporary_archive, output)
    end
    puts "Packaged verified documentation candidate as #{output}"
  end

  def run(argv)
    options = {}
    parser = OptionParser.new do |flags|
      flags.banner = 'Usage: scripts/documentation/release-asset.rb --artifact DIR --release-provenance FILE --output FILE'
      flags.on('--artifact DIR') { |value| options[:artifact] = value }
      flags.on('--release-provenance FILE') { |value| options[:release_provenance] = value }
      flags.on('--output FILE') { |value| options[:output] = value }
      flags.on('-h', '--help') { puts flags; return }
    end
    parser.parse!(argv)
    UndoKitDocumentation.fail!("unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    package(options)
  rescue StandardError => error
    warn "release-asset: #{error.message}"
    exit 1
  end
end

UndoKitDocumentationReleaseAsset.run(ARGV) if $PROGRAM_NAME == __FILE__
