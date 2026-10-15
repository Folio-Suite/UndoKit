# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

# Synthetic external-tool fixture; this is never publisher-signature evidence.
require 'digest'
require 'fileutils'
require 'json'
require 'openssl'
require_relative '../xcframework/assembly'

module CandidateFixture
  def fixture(directory)
    source = File.join(directory, 'source')
    FileUtils.mkdir_p(File.join(source, 'UndoKit', 'Resources'))
    File.write(File.join(source, 'UndoKit', 'Resources', 'PrivacyInfo.xcprivacy'), 'privacy-v1')
    system('git', 'init', '-q', source, exception: true)
    system('git', '-C', source, 'add', '.', exception: true)
    system('git', '-C', source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
           'commit', '-qm', 'fixture', exception: true)
    commit = Open3.capture2('git', '-C', source, 'rev-parse', 'HEAD').first.strip
    tree = Open3.capture2('git', '-C', source, 'rev-parse', 'HEAD^{tree}').first.strip
    inventory = File.join(directory, 'inventory.json')
    File.write(inventory, JSON.generate(schemaVersion: 1, repository: 'Folio-Suite/UndoKit',
      observedAtUTC: '2026-10-15T00:00:00Z', evidence: 'synthetic fixture; not release evidence', published: []))
    approval = File.join(directory, 'approval.json')
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = OpenSSL::X509::Name.parse('/CN=Apple Distribution: Synthetic Fixture (TESTTEAM01)/OU=TESTTEAM01/O=Synthetic Fixture')
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 3600
    certificate.not_after = Time.now + 3600
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    File.binwrite(File.join(directory, 'fixture.der'), certificate.to_der)
    File.write(File.join(directory, 'fixture.pem'), certificate.to_pem)
    File.write(approval, JSON.generate(schemaVersion: 1, publisher: 'Apple Distribution: Synthetic Fixture (TESTTEAM01)',
      teamIdentifier: 'TESTTEAM01', certificateSHA256: Digest::SHA256.hexdigest(certificate.to_der),
      approvedBy: 'Synthetic fixture', approvalEvidence: 'Fixture only; not actual maintainer approval'))
    {source: source, commit: commit, version: '0.2.0', build_number: '9',
     assembly: File.join(directory, 'assembly'), docs: File.join(directory, 'docs'),
     publisher_approval: approval, published_inventory: inventory,
     output: File.join(directory, 'attempt')}
  end

  def artifacts(options)
    assembly = options.fetch(:assembly)
    bundle = File.join(assembly, 'UndoKit.xcframework')
    FileUtils.mkdir_p(bundle)
    libraries = []
    archives = {}
    UndoKit::XCFrameworkAssembly::ARCHIVE_TARGETS.each do |target|
      name = target.fetch(:name)
      library = File.join(bundle, name)
      framework = File.join(library, 'UndoKit.framework')
      symbols = File.join(library, 'dSYMs', 'UndoKit.framework.dSYM')
      resources = target[:platform] == 'macos' ? File.join(framework, 'Resources') : framework
      files = [File.join(framework, 'UndoKit'), File.join(symbols, 'Contents/Resources/DWARF/UndoKit'),
        File.join(resources, 'History.momd/VersionInfo.plist'), File.join(resources, 'History.momd/HistoryV1.mom')]
      files.each { |file| FileUtils.mkdir_p(File.dirname(file)); File.write(file, File.basename(file)) }
      File.write(File.join(resources, 'PrivacyInfo.xcprivacy'), 'privacy-v1')
      File.write(File.join(resources, 'Info.plist'), JSON.generate(CFBundleShortVersionString: '0.2.0', CFBundleVersion: '9'))
      target[:interfaces].each_value do |interface|
        file = File.join(framework, 'Modules/UndoKit.swiftmodule', interface)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, "interface #{interface}")
      end
      libraries << {LibraryIdentifier: name, LibraryPath: 'UndoKit.framework', DebugSymbolsPath: 'dSYMs',
        SupportedPlatform: target[:platform], SupportedPlatformVariant: target[:platform_variant],
        SupportedArchitectures: target[:architectures]}
      archive = File.join(assembly, 'archives', "#{name}.xcarchive")
      FileUtils.mkdir_p(archive)
      File.write(File.join(archive, 'retained-original'), "original archive #{name}")
      archives[name] = {'archivePath' => archive, 'archiveTreeSHA256' => UndoKit::XCFrameworkAssembly.tree_sha256(archive)}
    end
    File.write(File.join(bundle, 'Info.plist'), JSON.generate(AvailableLibraries: libraries))
    provenance = {schemaVersion: 1, releaseVersion: '0.2.0', frameworkBuildNumber: '9',
      sourceCommit: options[:commit], sourceTree: Open3.capture2('git', '-C', options[:source], 'rev-parse', 'HEAD^{tree}').first.strip,
      workingTreeDirtyPaths: [], configuration: 'Release', toolchain: {
        xcodebuildVersion: ['Xcode 27.0', 'Build version 27A266a'],
        swiftVersion: ['Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)']},
      procedure: {codeSigning: 'disabled', script: 'scripts/assemble-xcframework.rb'},
      archives: archives, xcframeworkPath: bundle, xcframeworkTreeSHA256: UndoKit::XCFrameworkAssembly.tree_sha256(bundle)}
    File.write(File.join(assembly, 'provenance.json'), JSON.generate(provenance))
    docs = options[:docs]
    FileUtils.mkdir_p(File.join(docs, 'archive'))
    FileUtils.mkdir_p(File.join(docs, 'site'))
    File.write(File.join(docs, 'archive', 'data'), 'original documentation archive')
    File.write(File.join(docs, 'site', 'index.html'), 'retained documentation output')
    tree_hash = lambda do |root|
      digest = Digest::SHA256.new
      Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).reject { |path| ['.', '..'].include?(File.basename(path)) }.sort.each do |path|
        relative = path.delete_prefix(root + '/')
        if File.file?(path)
          digest.update("F\0#{relative}\0#{Digest::SHA256.file(path).hexdigest}\0")
        elsif File.directory?(path)
          digest.update("D\0#{relative}\0")
        end
      end
      digest.hexdigest
    end
    producer = {schemaVersion: 1, sourceCommit: options[:commit], sourceDirty: false,
      toolchain: {xcode: "Xcode 27.0\nBuild version 27A266a", swift: provenance[:toolchain][:swiftVersion].first, clang: 'Apple clang version 21.0.0 (clang-2100.3.34.2)'},
      command: ['xcodebuild', 'docbuild'], archiveTreeSHA256: tree_hash.call(File.join(docs, 'archive'))}
    File.write(File.join(docs, 'producer.json'), JSON.generate(producer))
    manifest = {schemaVersion: 1, version: '0.2.0', channel: 'release', sourceCommit: options[:commit], sourceDirty: false,
      basePath: '/UndoKit/versions/0.2.0/', archivePath: 'archive', sitePath: 'site', producerPath: 'producer.json',
      archiveTreeSHA256: producer[:archiveTreeSHA256], siteTreeSHA256: tree_hash.call(File.join(docs, 'site')),
      producerSHA256: Digest::SHA256.file(File.join(docs, 'producer.json')).hexdigest,
      producerCommand: producer[:command], toolchain: producer[:toolchain]}
    File.write(File.join(docs, 'manifest.json'), JSON.generate(manifest))
  end

  def boundary_tools(directory)
    bin = File.join(directory, 'bin')
    FileUtils.mkdir_p(bin)
    script = <<~'TOOL'
      #!/usr/bin/env ruby
      require 'json'
      require 'digest'
      require 'fileutils'
      require 'openssl'
      root = ENV.fetch('UNDOKIT_SYNTHETIC_FIXTURE')
      case File.basename($PROGRAM_NAME)
      when 'security'
        cert = OpenSSL::X509::Certificate.new(File.read(File.join(root, 'fixture.pem')))
        if ARGV.include?('find-identity')
          puts "1) #{Digest::SHA1.hexdigest(cert.to_der).upcase} \"Apple Distribution: Synthetic Fixture (TESTTEAM01)\""
        else
          puts cert.to_pem
        end
      when 'codesign'
        path = ARGV.last
        if ARGV.include?('--sign')
          FileUtils.mkdir_p(File.join(path, '_CodeSignature'))
          File.write(File.join(path, '_CodeSignature', 'fixture'), 'synthetic signature only')
        elsif ARGV.include?('--extract-certificates')
          prefix = ARGV[ARGV.index('--extract-certificates') + 1]
          FileUtils.cp(File.join(root, 'fixture.der'), prefix + '0')
        elsif ARGV.include?('--verify')
          requirement = ARGV[ARGV.index('-R') + 1]
          abort 'codesign requires = prefix for inline requirements' unless requirement.start_with?('=anchor apple generic and ')
          abort 'synthetic invalid signature' if ENV['UNDOKIT_FIXTURE_BAD_SIGNATURE'] == '1'
        else
          puts 'Authority=Apple Distribution: Synthetic Fixture (TESTTEAM01)'
          puts 'TeamIdentifier=TESTTEAM01'
          if ENV['UNDOKIT_FIXTURE_NO_TIMESTAMP'] == '1'
            puts 'Signed Time=Oct 15, 2026 at 12:00:00 PM'
          else
            puts 'Timestamp=' + ENV.fetch('UNDOKIT_FIXTURE_TIMESTAMP_TEXT', 'Oct 15, 2026 at 12:00:00 PM')
          end
        end
      when 'plutil'
        puts File.read(ARGV.last)
      when 'xcrun'
        tool = ARGV.shift
        path = ARGV.last
        archs = path.include?('/ios-device/') ? ['arm64'] : ['arm64', 'x86_64']
        case tool
        when 'lipo' then puts archs.join(' ')
        when 'dwarfdump' then archs.each { |arch| puts "UUID: #{arch == 'arm64' ? '8A7B6C5D-4E3F-2A10-9988-776655443322' : 'AABBCCDD-1122-3344-5566-77889900AABB'} (#{arch}) #{path}" }
        when 'otool' then puts 'filetype DYLIB'
        when 'vtool'
          platform = path.include?('/macos/') ? 'MACOS' : path.include?('/ios-device/') ? 'IOS' : 'IOSSIMULATOR'
          puts "platform #{platform}\nminos #{platform == 'MACOS' ? '14.0' : '17.0'}"
        else abort 'unknown fixture tool'
        end
      end
    TOOL
    %w[security codesign plutil xcrun].each do |tool|
      path = File.join(bin, tool)
      File.write(path, script.sub('#!/usr/bin/env ruby', '#!' + RbConfig.ruby + ' --disable-gems'))
      File.chmod(0755, path)
    end
    {'SDKROOT' => '', 'PATH' => bin + ':' + ENV.fetch('PATH'), 'UNDOKIT_SYNTHETIC_FIXTURE' => directory}
  end

  def candidate_command(options, environment = {})
    arguments = options.flat_map { |key, value| ["--#{key.to_s.tr('_', '-')}", value] }
    Open3.capture2e(environment, RbConfig.ruby, '--disable-gems', self.class::COMMAND, 'prepare', *arguments)
  end
end
