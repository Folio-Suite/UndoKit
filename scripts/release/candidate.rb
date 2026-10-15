#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'openssl'
require 'optparse'
require 'time'
require 'tmpdir'
require_relative '../xcframework/assembly'

module UndoKitCandidate
  module_function

  def fail!(message)
    raise ArgumentError, message
  end

  def json(path)
    JSON.parse(File.read(path))
  end

  def write_json(path, value)
    File.write(path, JSON.pretty_generate(value) + "\n")
  end

  def capture(*command)
    output, status = Open3.capture2e(*command)
    fail!("#{command.first} failed (#{status.exitstatus}): #{output.strip}") unless status.success?
    output
  end

  def source!(options)
    source = File.expand_path(options.fetch(:source))
    fail!('commit must be a full lowercase 40-character SHA') unless options[:commit].match?(/\A[0-9a-f]{40}\z/)
    fail!('selected source commit does not match checkout HEAD') unless capture('git', '-C', source, 'rev-parse', 'HEAD').strip == options[:commit]
    fail!('source checkout must be clean') unless capture('git', '-C', source, 'status', '--porcelain', '--untracked-files=all').strip.empty?
    source
  end

  def inventory!(options)
    fail!('this preview plans version 0.2.0') unless options[:version] == '0.2.0'
    fail!('build number must be a positive integer') unless options[:build_number].match?(/\A[1-9][0-9]*\z/)
    inventory = json(options.fetch(:published_inventory))
    fail!('published inventory must use schema 1 and Folio-Suite/UndoKit') unless inventory['schemaVersion'] == 1 && inventory['repository'] == 'Folio-Suite/UndoKit'
    Time.iso8601(inventory.fetch('observedAtUTC'))
    fail!('published inventory requires an evidence reference') if inventory.fetch('evidence').to_s.strip.empty?
    published = inventory.fetch('published')
    fail!('published inventory must contain a published array') unless published.is_a?(Array)
    published.each do |release|
      fail!('invalid published version') unless release.fetch('version').match?(/\A[0-9]+\.[0-9]+\.[0-9]+\z/)
      fail!('invalid published source identity') unless release.fetch('sourceCommit').match?(/\A[0-9a-f]{40}\z/)
      if release['installationRoute'] == 'source-only'
        fail!('source-only inventory entry requires matching tag and evidence') unless release.fetch('tag') == release.fetch('version') && !release.fetch('evidence').to_s.strip.empty?
        build = release.fetch('frameworkBuildNumber')
        fail!('source-only framework build must be explicitly unknown or a verified positive integer') unless build.nil? || build.to_s.match?(/\A[1-9][0-9]*\z/)
        fail!('source-only inventory must explicitly record no binary archive checksum') unless release.fetch('archiveSHA256').nil?
      else
        fail!('invalid published build') unless release.fetch('frameworkBuildNumber').to_s.match?(/\A[1-9][0-9]*\z/)
        fail!('invalid published archive checksum') unless release.fetch('archiveSHA256').match?(/\A[0-9a-f]{64}\z/)
      end
      fail!('published version identities cannot be reused') if release['version'] == options[:version]
    end
    maximum = published.map { |release| release.fetch('frameworkBuildNumber').to_i }.max || 0
    fail!("build number must exceed published build #{maximum}") unless options[:build_number].to_i > maximum
    _out, status = Open3.capture2e('git', '-C', options[:source], 'show-ref', '--verify', '--quiet', "refs/tags/#{options[:version]}")
    fail!('selected version tag already exists; published identities cannot be reused') if status.success?
    inventory
  end

  def approval!(path)
    approval = json(path)
    fail!('publisher approval must use schema 1') unless approval['schemaVersion'] == 1
    fail!('approved publisher must be Apple Distribution') unless approval.fetch('publisher').match?(/\AApple Distribution: .+\z/)
    fail!('approved team identifier must contain ten uppercase letters or numbers') unless approval.fetch('teamIdentifier').match?(/\A[A-Z0-9]{10}\z/)
    fail!('approved certificate SHA-256 must contain 64 lowercase hexadecimal characters') unless approval.fetch('certificateSHA256').match?(/\A[0-9a-f]{64}\z/)
    %w[approvedBy approvalEvidence].each { |field| fail!("publisher approval requires #{field}") if approval.fetch(field).to_s.strip.empty? }
    approval
  end

  def safe_tree!(root)
    root = File.realpath(root)
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).each do |path|
      next unless File.symlink?(path)
      resolved = File.realpath(path)
      fail!("artifact symlink escapes retained root: #{path}") unless resolved == root || resolved.start_with?(root + '/')
    end
    UndoKit::XCFrameworkAssembly.tree_sha256(root)
  end

  def child!(root, path)
    root = File.realpath(root)
    resolved = File.realpath(File.expand_path(path, root))
    fail!("artifact path escapes input root: #{path}") unless resolved.start_with?(root + '/')
    resolved
  end

  def assembly!(options)
    root = File.expand_path(options.fetch(:assembly))
    safe_tree!(root)
    producer = json(File.join(root, 'provenance.json'))
    fail!('unsupported assembly provenance schema') unless producer['schemaVersion'] == 1
    fail!('assembly source differs from selected commit') unless producer.fetch('sourceCommit') == options[:commit]
    fail!('assembly source tree differs from selected commit') unless producer.fetch('sourceTree') == capture('git', '-C', options[:source], 'rev-parse', 'HEAD^{tree}').strip
    fail!('assembly source was dirty') unless producer.fetch('workingTreeDirtyPaths') == []
    fail!('assembly release version or build differs from selected identity') unless producer.fetch('releaseVersion') == options[:version] && producer.fetch('frameworkBuildNumber').to_s == options[:build_number]
    fail!('assembly requires unsigned Release configuration') unless producer.fetch('configuration') == 'Release' && producer.fetch('procedure').fetch('codeSigning') == 'disabled'
    toolchain!(producer.fetch('toolchain').fetch('xcodebuildVersion').join("\n"), producer.fetch('toolchain').fetch('swiftVersion').join("\n"))
    archives = producer.fetch('archives')
    expected = UndoKit::XCFrameworkAssembly::ARCHIVE_TARGETS.map { |target| target.fetch(:name) }.sort
    fail!('assembly must retain all three platform archives') unless archives.keys.sort == expected
    archives.each do |name, archive|
      path = child!(root, archive.fetch('archivePath'))
      fail!("#{name} original archive bytes differ from producer provenance") unless safe_tree!(path) == archive.fetch('archiveTreeSHA256')
    end
    bundle = child!(root, producer.fetch('xcframeworkPath'))
    fail!('assembled XCFramework bytes differ from producer provenance') unless safe_tree!(bundle) == producer.fetch('xcframeworkTreeSHA256')
    [producer, bundle]
  end

  def toolchain!(xcode, swift)
    fail!('producer must use Xcode 27.0 (27A266a)') unless xcode.strip == "Xcode 27.0\nBuild version 27A266a"
    fail!('producer must use pinned Apple Swift 6.4') unless swift.include?('Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)')
  end

  # #22 schema 1 tree encoding. Kept independent of publication operations.
  def documentation_tree(root)
    safe_tree!(root)
    digest = Digest::SHA256.new
    Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| ['.', '..'].include?(File.basename(path)) }.sort.each do |path|
      relative = path.delete_prefix(root + '/')
      if File.symlink?(path)
        digest.update("L\0#{relative}\0#{File.readlink(path)}\0")
      elsif File.file?(path)
        digest.update("F\0#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0")
      elsif File.directory?(path)
        digest.update("D\0#{relative}\0")
      else
        fail!("unsupported documentation entry: #{relative}")
      end
    end
    digest.hexdigest
  end

  def docs!(root, options)
    root = File.expand_path(root)
    safe_tree!(root)
    manifest = json(File.join(root, 'manifest.json'))
    fail!('unsupported documentation schema') unless manifest['schemaVersion'] == 1
    unless manifest.fetch('version') == options[:version] && manifest.fetch('sourceCommit') == options[:commit] &&
           manifest.fetch('sourceDirty') == false && manifest.fetch('channel') == 'release'
      fail!('documentation must match candidate version and clean source commit')
    end
    fail!('documentation base path differs from release path') unless manifest.fetch('basePath') == "/UndoKit/versions/#{options[:version]}/"
    {'archivePath' => 'archive', 'sitePath' => 'site', 'producerPath' => 'producer.json'}.each do |field, expected|
      fail!("documentation #{field} must equal #{expected}") unless manifest.fetch(field) == expected
    end
    %w[archive site].each do |kind|
      path = child!(root, manifest.fetch("#{kind}Path"))
      fail!("documentation #{kind} bytes differ from manifest") unless documentation_tree(path) == manifest.fetch("#{kind}TreeSHA256")
    end
    producer_path = child!(root, manifest.fetch('producerPath'))
    fail!('documentation producer bytes differ from manifest') unless Digest::SHA256.file(producer_path).hexdigest == manifest.fetch('producerSHA256')
    producer = json(producer_path)
    unless producer.fetch('schemaVersion') == 1 && producer.fetch('sourceCommit') == options[:commit] && producer.fetch('sourceDirty') == false &&
           producer.fetch('archiveTreeSHA256') == manifest.fetch('archiveTreeSHA256') &&
           producer.fetch('toolchain') == manifest.fetch('toolchain') && producer.fetch('command') == manifest.fetch('producerCommand') &&
           producer.fetch('command').is_a?(Array) && !producer.fetch('command').empty?
      fail!('documentation producer provenance differs from release manifest')
    end
    toolchain!(manifest.fetch('toolchain').fetch('xcode'), manifest.fetch('toolchain').fetch('swift'))
    clang = manifest.fetch('toolchain').fetch('clang')
    fail!('documentation producer must record full standalone Apple clang output') unless clang.is_a?(String) && clang.match?(/Apple clang version .+\(clang-[^)]+\)/)
    manifest
  end

  def certificate_matches!(certificate, approval, check_validity: true)
    subject = certificate.subject.to_a.to_h { |field, value, _type| [field, value] }
    fail!('certificate subject does not match approved Apple Distribution publisher/team') unless
      subject['CN'] == approval.fetch('publisher') && subject['OU'] == approval.fetch('teamIdentifier')
    fail!('certificate fingerprint differs from approved certificate') unless
      Digest::SHA256.hexdigest(certificate.to_der) == approval.fetch('certificateSHA256')
    if check_validity && !(certificate.not_before <= Time.now && certificate.not_after > Time.now)
      fail!('approved certificate is expired or not yet valid')
    end
    Digest::SHA1.hexdigest(certificate.to_der).upcase
  end

  def signing_identity!(approval)
    certificates = capture('security', 'find-certificate', '-a', '-p').scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
    match = certificates.map { |pem| OpenSSL::X509::Certificate.new(pem) }.find do |certificate|
      Digest::SHA256.hexdigest(certificate.to_der) == approval.fetch('certificateSHA256')
    end
    fail!('approved Apple Distribution certificate is unavailable; no signing attempted') unless match
    sha1 = certificate_matches!(match, approval)
    identities = capture('security', 'find-identity', '-v', '-p', 'codesigning')
    fail!('approved certificate has no usable signing identity/private key') unless identities.lines.any? { |line| line.match?(/\b#{sha1}\b/) && line.include?(%Q("#{approval.fetch('publisher')}")) }
    sha1
  end

  def signature!(bundle, approval, certificate_directory)
    FileUtils.mkdir_p(certificate_directory)
    prefix = File.join(certificate_directory, 'signer-')
    capture('codesign', '-d', '--extract-certificates', prefix, bundle)
    certificate = OpenSSL::X509::Certificate.new(File.binread(prefix + '0'))
    sha1 = certificate_matches!(certificate, approval, check_validity: false)
    requirement = "anchor apple generic and certificate leaf = H\"#{sha1}\" and certificate leaf[subject.OU] = \"#{approval.fetch('teamIdentifier')}\""
    verification = capture('codesign', '--verify', '--strict', '--verbose=4', '-R', '=' + requirement, bundle)
    display = capture('codesign', '-d', '--verbose=4', bundle)
    fail!('signature is ad-hoc or unsigned') if display.match?(/Signature=adhoc|flags=.*adhoc/i)
    fail!('signed publisher differs from approved identity') unless display.lines.map(&:strip).include?("Authority=#{approval.fetch('publisher')}")
    fail!('signed team differs from approved publisher') unless display.lines.map(&:strip).include?("TeamIdentifier=#{approval.fetch('teamIdentifier')}")
    timestamp = display.lines.map(&:strip).find { |line| line.start_with?('Timestamp=') }
    fail!('verified signature has no secure timestamp') unless timestamp && !timestamp.match?(/=(?:none|0|unavailable)?\s*\z/i)
    {'certificateSHA256' => approval.fetch('certificateSHA256'), 'certificateSHA1' => sha1,
     'publisher' => approval.fetch('publisher'), 'teamIdentifier' => approval.fetch('teamIdentifier'),
     'secureTimestampEvidence' => timestamp.delete_prefix('Timestamp='), 'display' => display,
     'verification' => verification, 'verificationRequirement' => requirement}
  end

  def bundle_variants!(bundle, source_privacy, options)
    variants = UndoKit::XCFrameworkAssembly.verify_xcframework!(bundle, source_privacy)
    variants.each_value do |variant|
      framework = child!(bundle, variant.fetch('frameworkPath'))
      info = json_output('plutil', '-convert', 'json', '-o', '-', File.join(UndoKit::XCFrameworkAssembly.framework_resource_root(framework), 'Info.plist'))
      unless info.fetch('CFBundleShortVersionString') == options[:version] && info.fetch('CFBundleVersion').to_s == options[:build_number]
        fail!('actual framework version/build differs from candidate identity')
      end
    end
    variants
  end

  def json_output(*command)
    JSON.parse(capture(*command))
  end

  def copy_tree(from, to)
    FileUtils.cp_r(from, to, preserve: true)
  end

  def verify(root)
    fail!('failed preparation cannot be verified as a candidate') if File.exist?(File.join(root, 'preparation-failure.json'))
    manifest_path = File.join(root, 'manifest.json')
    manifest = json(manifest_path)
    fail!('unsupported candidate manifest schema') unless manifest.fetch('schemaVersion') == 1
    expected_manifest = File.read(File.join(root, 'manifest.sha256')).split.first
    fail!('candidate manifest checksum differs') unless Digest::SHA256.file(manifest_path).hexdigest == expected_manifest
    fail!('retained inputs differ from candidate manifest') unless safe_tree!(File.join(root, 'inputs')) == manifest.fetch('inputsTreeSHA256')
    bundle = child!(root, manifest.fetch('xcframeworkPath'))
    fail!('signed XCFramework differs from candidate manifest') unless safe_tree!(bundle) == manifest.fetch('signedXCFrameworkTreeSHA256')
    archive = child!(root, manifest.fetch('archivePath'))
    fail!('download ZIP differs from candidate checksum') unless Digest::SHA256.file(archive).hexdigest == manifest.fetch('archiveSHA256')
    fail!('ZIP checksum sidecar differs from candidate') unless File.read(File.join(root, 'SHA256SUMS')) == "#{manifest.fetch('archiveSHA256')}  #{manifest.fetch('archivePath')}\n"
    identity_data = [manifest.fetch('releaseVersion'), manifest.fetch('frameworkBuildNumber'), manifest.fetch('sourceCommit'),
                     manifest.fetch('archiveSHA256'), manifest.fetch('documentation').fetch('siteTreeSHA256')].join("\0")
    fail!('candidate identity differs from recorded source/artifact/documentation') unless Digest::SHA256.hexdigest(identity_data) == manifest.fetch('candidateID')
    options = {version: manifest.fetch('releaseVersion'), build_number: manifest.fetch('frameworkBuildNumber'), commit: manifest.fetch('sourceCommit')}
    docs = docs!(File.join(root, 'inputs', 'documentation'), options)
    fail!('documentation identity differs from manifest') unless docs == manifest.fetch('documentation')
    approval = approval!(File.join(root, 'inputs', 'publisher-approval.json'))
    Dir.mktmpdir('undokit-candidate-verify-') do |temporary|
      signature = signature!(bundle, approval, File.join(temporary, 'certificates'))
      # Timestamp text is locale-dependent display evidence. signature! verifies
      # actual secure timestamp presence; the signed tree already binds its bytes.
      %w[certificateSHA256 publisher teamIdentifier].each do |field|
        fail!("verified signature #{field} differs from candidate") unless signature.fetch(field) == manifest.fetch('signing').fetch(field)
      end
      unpacked = File.join(temporary, 'unpacked')
      capture('ditto', '-x', '-k', archive, unpacked)
      fail!('release ZIP must contain exactly UndoKit.xcframework') unless Dir.children(unpacked) == ['UndoKit.xcframework']
      fail!('ZIP contents differ from signed XCFramework') unless safe_tree!(File.join(unpacked, 'UndoKit.xcframework')) == manifest.fetch('signedXCFrameworkTreeSHA256')
    end
    puts "Verified candidate #{manifest.fetch('candidateID')} (qualification evidence remains separate)"
    manifest
  end

  def prepare(options, output)
    source = source!(options)
    inventory = inventory!(options)
    approval = approval!(options.fetch(:publisher_approval))
    roots = [source, options[:assembly], options[:docs]].map { |path| File.realpath(path) }
    output_real = File.realpath(output)
    fail!('candidate output must be outside source and input directories') if roots.any? { |root| output_real == root || output_real.start_with?(root + '/') }
    originals = roots.drop(1).to_h { |path| [path, safe_tree!(path)] }
    assembly, unsigned = assembly!(options)
    docs = docs!(options.fetch(:docs), options)
    identity = signing_identity!(approval)
    inputs = File.join(output, 'inputs')
    FileUtils.mkdir_p(inputs)
    copy_tree(options[:assembly], File.join(inputs, 'assembly'))
    copy_tree(options[:docs], File.join(inputs, 'documentation'))
    FileUtils.cp(options[:publisher_approval], File.join(inputs, 'publisher-approval.json'))
    FileUtils.cp(options[:published_inventory], File.join(inputs, 'published-inventory.json'))
    bundle = File.join(output, 'UndoKit.xcframework')
    copy_tree(unsigned, bundle)
    privacy = File.join(source, 'UndoKit', 'Resources', 'PrivacyInfo.xcprivacy')
    variants = bundle_variants!(bundle, privacy, options)
    signing_command = ['codesign', '--sign', identity, '--timestamp', bundle]
    signing_output = capture(*signing_command)
    certificates = File.join(inputs, 'signing-certificates')
    signature = signature!(bundle, approval, certificates)
    fail!('signing changed finalized framework, interface, model or symbol contents') unless bundle_variants!(bundle, privacy, options) == variants
    File.write(File.join(inputs, 'signing.log'), "$ #{signing_command.join(' ')}\n#{signing_output}\n#{signature.fetch('display')}\n#{signature.fetch('verification')}")
    archive_name = "UndoKit-#{options[:version]}-build#{options[:build_number]}.xcframework.zip"
    archive_path = File.join(output, archive_name)
    capture('ditto', '-c', '-k', '--keepParent', bundle, archive_path)
    archive_sha = Digest::SHA256.file(archive_path).hexdigest
    File.write(File.join(output, 'SHA256SUMS'), "#{archive_sha}  #{archive_name}\n")
    source!(options)
    originals.each { |path, digest| fail!('original producer inputs changed during preparation') unless safe_tree!(path) == digest }
    fail!('publisher approval changed during preparation') unless json(File.join(inputs, 'publisher-approval.json')) == approval
    fail!('published inventory changed during preparation') unless json(File.join(inputs, 'published-inventory.json')) == inventory
    identity_data = [options[:version], options[:build_number], options[:commit], archive_sha, docs.fetch('siteTreeSHA256')].join("\0")
    manifest = {
      'schemaVersion' => 1, 'preparedAtUTC' => Time.now.utc.iso8601,
      'candidateID' => Digest::SHA256.hexdigest(identity_data), 'releaseVersion' => options[:version],
      'frameworkBuildNumber' => options[:build_number], 'sourceCommit' => options[:commit],
      'plannedSourceTag' => options[:version], 'sourceTagCreated' => false,
      'toolchain' => assembly.fetch('toolchain'), 'configuration' => assembly.fetch('configuration'),
      'procedure' => {'command' => 'scripts/release/candidate.rb prepare', 'arguments' => options,
                      'signingCommand' => signing_command, 'zipCommand' => ['ditto', '-c', '-k', '--keepParent', bundle, archive_path]},
      'assemblyProvenance' => assembly, 'variants' => variants, 'signing' => signature,
      'documentation' => docs, 'publishedInventory' => inventory,
      'inputsTreeSHA256' => safe_tree!(inputs), 'xcframeworkPath' => 'UndoKit.xcframework',
      'signedXCFrameworkTreeSHA256' => safe_tree!(bundle), 'archivePath' => archive_name,
      'archiveSHA256' => archive_sha, 'qualificationStatus' => 'not-yet-qualified',
      'qualificationEvidence' => 'Attach separate evidence/approval records binding candidateID, manifest SHA-256 and archive SHA-256. Do not mutate this manifest.'
    }
    write_json(File.join(output, 'manifest.json'), manifest)
    File.write(File.join(output, 'manifest.sha256'), "#{Digest::SHA256.file(File.join(output, 'manifest.json')).hexdigest}  manifest.json\n")
    verify(output)
    puts "Prepared candidate retained at #{output}; no source tag, release or documentation was published."
  end

  def safe_output!(output, options)
    # Resolve existing symlink ancestors before creating even a failure directory.
    ancestor = output
    suffix = []
    until File.exist?(ancestor) || File.symlink?(ancestor)
      suffix.unshift(File.basename(ancestor))
      ancestor = File.dirname(ancestor)
    end
    canonical_output = File.join(File.realpath(ancestor), *suffix)
    %i[source assembly docs].each do |key|
      next unless options[key]
      input = File.expand_path(options.fetch(key))
      next unless File.exist?(input) || File.symlink?(input)
      root = File.realpath(input)
      if canonical_output == root || canonical_output.start_with?(root + '/')
        fail!('candidate output must be outside source and input directories')
      end
    end
  end

  def run(argv)
    command = argv.shift
    argv.unshift(command) if %w[-h --help].include?(command)
    options = {}
    parser = OptionParser.new do |flags|
      flags.banner = 'Usage: scripts/release/candidate.rb prepare|verify [options]'
      %w[output source commit version build-number assembly docs publisher-approval published-inventory candidate].each do |name|
        flags.on("--#{name} VALUE") { |value| options[name.tr('-', '_').to_sym] = value }
      end
      flags.on('-h', '--help') { puts flags; return }
    end
    parser.parse!(argv)
    fail!("unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    if command == 'prepare'
      fail!('missing --output') unless options[:output]
      output = File.expand_path(options[:output])
      fail!('output already exists; use a fresh candidate directory') if File.exist?(output) || File.symlink?(output)
      safe_output!(output, options)
      FileUtils.mkdir_p(output)
      begin
        required = %i[source commit version build_number assembly docs publisher_approval published_inventory]
        missing = required.reject { |key| options[key] }
        fail!("missing options: #{missing.join(', ')}") unless missing.empty?
        prepare(options, output)
      rescue StandardError => error
        %w[manifest.json manifest.sha256].each do |name|
          path = File.join(output, name)
          File.rename(path, File.join(output, "unverified-#{name}")) if File.exist?(path)
        end
        write_json(File.join(output, 'preparation-failure.json'), {
          'failedAtUTC' => Time.now.utc.iso8601, 'error' => "#{error.class}: #{error.message}",
          'arguments' => options, 'retainedDirectory' => output
        })
        raise
      end
    elsif command == 'verify'
      fail!('missing --candidate') unless options[:candidate]
      verify(File.expand_path(options[:candidate]))
    else
      fail!(parser.to_s)
    end
  rescue StandardError => error
    warn "candidate: #{error.message}"
    exit 1
  end
end

UndoKitCandidate.run(ARGV) if $PROGRAM_NAME == __FILE__
