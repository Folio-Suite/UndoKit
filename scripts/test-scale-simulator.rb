#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'json'
require 'digest'

class ScaleSimulatorCLITest < Minitest::Test
  def test_runner_requires_an_explicit_simulator_device_before_touching_xcode
    output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-scale-simulator.rb'), '--output', '/tmp/no-device')
    refute status.success?, output
    assert_includes output, '--device UDID is required'
  end


  def test_full_runner_drives_three_fixtures_and_checker_with_controlled_tools
    Dir.mktmpdir('scale-simulator-tools-') do |dir|
      bin = File.join(dir, 'bin'); Dir.mkdir(bin)
      data = File.join(dir, 'app-data'); Dir.mkdir(data)
      write_tool = lambda do |name, body|
        path = File.join(bin, name)
        File.write(path, "#!/bin/sh\n#{body}\n")
        File.chmod(0o755, path)
      end
      write_tool.call('swift', 'echo Apple Swift version 6.4')
      write_tool.call('git', 'if [ \"$1\" = \"rev-parse\" ]; then echo test-head; else exit 0; fi')
      write_tool.call('ruby', <<~SH)
        if [ \"$1\" = \"#{File.join(__dir__, 'check-scale-device-evidence.rb')}\" ]; then echo '{\"result\":\"simulator_evidence_complete_for_review\"}'; echo checker >> '#{dir}/calls'; exit 0; fi
        exec /usr/bin/ruby \"$@\"
      SH
      write_tool.call('xcodebuild', <<~'SH')
        if [ "$1" = "-version" ]; then echo 'Xcode 27.1'; echo 'Build version 27A9275'; exit 0; fi
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-derivedDataPath" ]; then root="$2"; shift 2; else shift; fi
        done
        mkdir -p "$root/Build/Products/Release-iphonesimulator/ScaleDevice.app"
      SH
      write_tool.call('du', 'echo "1 1 $2"')
      write_tool.call('kill', 'exit 0')
      write_tool.call('ps', 'echo 100')
      write_tool.call('df', 'echo "Filesystem 1K-blocks Used Available Capacity Mounted on"; echo "/dev/test 99999999 1 99999998 1% /"')
      write_tool.call('xcrun', <<~SH)
        if [ "$1" = "simctl" ] && [ "$2" = "list" ] && [ "$3" = "devices" ] && [ "$4" = "booted" ]; then echo '{"devices":{"iOS":{"udid":"SIM-1","state":"Booted"}}}'; exit 0; fi
        if [ "$1" = "simctl" ] && [ "$2" = "list" ] && [ "$3" = "runtimes" ]; then echo '{"runtimes":[{"identifier":"iOS","version":"27.0","buildVersion":"24A1"}]}'; exit 0; fi
        if [ "$1" = "simctl" ] && [ "$2" = "list" ]; then echo '{"devices":{"iOS":[{"udid":"SIM-1","state":"Booted"}]}}'; exit 0; fi
        if [ "$1" = "simctl" ] && [ "$2" = "get_app_container" ]; then echo '#{data}'; exit 0; fi
        if [ "$1" = "simctl" ] && [ "$2" = "spawn" ]; then echo ''; exit 0; fi
        if [ "$1" = "simctl" ] && [ "$2" = "launch" ]; then
          operation=''; seed=''; sample='0'
          while [ "$#" -gt 0 ]; do
            case "$1" in --scale-operation) operation="$2"; shift 2;; --scale-seed) seed="$2"; shift 2;; --scale-sample) sample="$2"; shift 2;; *) shift;; esac
          done
          echo $operation:$seed:$sample >> '#{dir}/calls'
          fixture='#{data}/Library/Application Support/UndoKitScaleEvidence/seed-'$seed
          mkdir -p "$fixture"
          if [ "$operation" = "create" ]; then echo '{}' > "$fixture/WorkloadReport.json"; else echo '{}' > "$fixture/Reopen-$sample.json"; fi
          count=$(cat '#{dir}/pid-count' 2>/dev/null || echo 1000); count=$((count + 1)); echo $count > '#{dir}/pid-count'; if [ \"$operation\" = \"create\" ]; then echo '{\"processID\":'\"$count\"'}' > \"$fixture/WorkloadReport.json\"; else echo '{\"processID\":'\"$count\"'}' > \"$fixture/Reopen-$sample.json\"; fi; echo 'org.foliosuite.undokit.scale: '$count; exit 0
        fi
        if [ "$1" = "simctl" ] && [ "$2" = "terminate" ]; then exit 0; fi
        if [ "$1" = "simctl" ] && [ "$2" = "install" ]; then touch '#{dir}/installed'; exit 0; fi
        exit 2
      SH
      output_dir = File.join(dir, 'evidence')
      output, status = Open3.capture2e({'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'UNDOKIT_DERIVED_DATA' => File.join(dir, 'DerivedData')},
        'ruby', File.join(__dir__, 'check-scale-simulator.rb'), '--device', 'SIM-1', '--output', output_dir)
      assert status.success?, output + File.read(File.join(output_dir, 'RunnerReport.json'))
      report = JSON.parse(File.read(File.join(output_dir, 'RunnerReport.json')))
      assert_equal 'simulator_full_completed', report.fetch('result')
      assert_equal 'simulator_evidence_complete_for_review', report.fetch('checkerResult')
      assert_equal 'completed', report.fetch('runs').first.fetch('phase')
      assert_equal 11, report.fetch('runs').first.fetch('pids').length
      calls = File.readlines(File.join(dir, 'calls')).map(&:strip)
      assert_equal 3, calls.count { |line| line.start_with?('create:') }
      assert_equal 30, calls.count { |line| line.start_with?('reopen:') }
      assert_includes calls, 'checker'
      FileUtils.rm_f(File.join(dir, 'installed'))
      FileUtils.mkdir_p(File.join(data, 'Library', 'Application Support', 'UndoKitScaleEvidence', 'seed-11'))
      refused_output, refused = Open3.capture2e({'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'UNDOKIT_DERIVED_DATA' => File.join(dir, 'DerivedData')},
        'ruby', File.join(__dir__, 'check-scale-simulator.rb'), '--device', 'SIM-1', '--groups', '100', '--repetitions', '1', '--reopens', '1', '--output', File.join(dir, 'refused'))
      refute refused.success?, refused_output
      assert_includes File.read(File.join(dir, 'refused', 'RunnerReport.json')), 'Refusing pre-existing simulator fixture evidence'
      refute File.exist?(File.join(dir, 'installed')), 'Existing simulator evidence must be checked before installation'
    end
  end

  def test_evidence_checker_accepts_complete_simulator_evidence_for_review
    Dir.mktmpdir('scale-simulator-complete-') do |dir|
      build, evidence = complete_fixture(dir)
      runner_path = File.join(evidence.fetch(:path), 'RunnerReport.json')
      runner = JSON.parse(File.read(runner_path)); runner['result'] = 'simulator_full_completed'
      File.write(runner_path, JSON.generate(runner))
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-scale-device-evidence.rb'),
        '--simulator-evidence', evidence.fetch(:path), '--build-manifest', build.fetch(:path))
      assert status.success?, output
      result = JSON.parse(output)
      assert_equal 'simulator_evidence_complete_for_review', result.fetch('result')
      assert_equal false, result.fetch('physicalQualification')
    end
  end

  def test_evidence_checker_rejects_incomplete_or_mismatched_full_evidence
    mutations = {
      'wrong installed identity' => ->(fixture, _seed) { fixture['WorkloadReport.json']['installedArtifactSHA256'] = {'ScaleDevice' => 'wrong'} },
      'duplicate process ID' => ->(fixture, _seed) { fixture['Reopen-2.json']['processID'] = fixture['Reopen-1.json']['processID'] },
      'missing sample' => ->(fixture, _seed) { File.delete(fixture['Reopen-10.json'].fetch(:path)) },
      'wrong expected state' => ->(fixture, _seed) { fixture['Reopen-1.json']['hostValue'] = -1 },
      'inflated budgets' => ->(fixture, _seed) { fixture['WorkloadReport.json']['peakResidentBytes'] = 3 * 1024**3 },
      'mixed physical and simulator profile' => ->(fixture, _seed) { fixture['WorkloadReport.json']['platform'] = 'physical iOS' },
      'inflated declared budgets' => ->(fixture, _seed) { fixture['Budgets.json']['residentBytes'] = 3 * 1024**3 }
    }
    mutations.each do |label, mutation|
      Dir.mktmpdir("scale-simulator-#{label.gsub(' ', '-')}-") do |dir|
        build, evidence = complete_fixture(dir)
        fixture = {path: evidence.fetch('seed-11')[:path]}
        %w[WorkloadReport.json Budgets.json Reopen-1.json Reopen-2.json Reopen-10.json].each do |name|
          fixture[name] = JSON.parse(File.read(File.join(fixture[:path], name))) if File.file?(File.join(fixture[:path], name))
          fixture[name] = {path: File.join(fixture[:path], name)} if name == 'Reopen-10.json'
        end
        mutation.call(fixture, 11)
        fixture.each { |name, value| File.write(File.join(fixture[:path], name), JSON.generate(value)) unless name == :path || value.is_a?(Hash) && value[:path] }
        output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-scale-device-evidence.rb'),
          '--simulator-evidence', evidence.fetch(:path), '--build-manifest', build.fetch(:path))
        refute status.success?, "#{label}: #{output}"
        assert_equal 'failed', JSON.parse(output).fetch('result'), label
      end
    end
  end

  def complete_fixture(root)
    build_path = File.join(root, 'build.json')
    artifact = {'ScaleDevice' => 'abc'}
    identity = {sourceHead: 'head', sourceDirtyPaths: [], sourceSHA256: {'source.swift' => 'hash'},
      toolchain: 'Xcode 27.1\nBuild version 27A9275', swift: 'Apple Swift version 6.4', configuration: 'Release', sdk: 'iphonesimulator'}
    build = identity.merge(buildSucceeded: true, profile: 'simulator-full', artifactSHA256: artifact)
    File.write(build_path, JSON.generate(build))
    evidence_path = File.join(root, 'evidence'); Dir.mkdir(evidence_path)
    runner_runs = (11..13).map { |seed| {seed: seed, pids: [100 + seed] + (1..10).map { |index| 1000 + seed * 20 + index }, samples: (1..10).map { |index| 1000 + seed * 20 + index }, peakRSSBytes: 100} }
    File.write(File.join(evidence_path, 'RunnerReport.json'), JSON.generate(result: 'validating', profile: 'simulator-full', groups: 10_000,
      repetitions: 3, reopens: 10, buildManifestSHA256: Digest::SHA256.file(build_path).hexdigest,
      runtime: {runtime: {version: '27.0', buildVersion: '24A1'}}, runs: runner_runs))
    (11..13).each do |seed|
      path = File.join(evidence_path, "seed-#{seed}"); Dir.mkdir(path)
      embedded = identity.merge(profile: 'simulator-full')
      workload = {installedArtifactSHA256: artifact, platform: 'iOS Simulator', groups: 10_000, seed: seed,
        phases: {total: 10.0}, peakResidentBytes: 100, peakOwnedAllocatedBytes: 100,
        maximumOrdinaryHeartbeatGapSeconds: 0.5, processID: 100 + seed}
      budgets = {seconds: 900, residentBytes: 2 * 1024**3, ownedBytes: 2 * 1024**3, minimumFreeBytes: 4 * 1024**3, ordinaryHeartbeatSeconds: 1}
      File.write(File.join(path, 'BuildManifest.json'), JSON.generate(embedded))
      File.write(File.join(path, 'WorkloadReport.json'), JSON.generate(workload))
      File.write(File.join(path, 'Budgets.json'), JSON.generate(budgets))
      (1..10).each do |index|
        sample = {installedArtifactSHA256: artifact, processID: 1000 + seed * 20 + index,
          hostValue: seed * 100_000 + 20_000, deliveries: 10_102, members: 11_112,
          canUndo: true, canRedo: false, totalSeconds: 1.0, availabilitySeconds: 0.5,
          peakResidentBytes: 100, peakOwnedAllocatedBytes: 100}
        File.write(File.join(path, "Reopen-#{index}.json"), JSON.generate(sample))
      end
    end
    [{path: build_path}, (11..13).to_h { |seed| ["seed-#{seed}", {path: File.join(evidence_path, "seed-#{seed}")}] }.merge(path: evidence_path)]
  end

  def test_evidence_checker_rejects_missing_full_fixture_evidence
    Dir.mktmpdir('scale-simulator-check-') do |dir|
      build = File.join(dir, 'build.json')
      File.write(build, JSON.generate(sdk: 'iphonesimulator', buildSucceeded: true, artifactSHA256: {'ScaleDevice' => 'abc'},
        sourceDirtyPaths: [], configuration: 'Release', profile: 'simulator-full'))
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-scale-device-evidence.rb'),
        '--simulator-evidence', File.join(dir, 'absent'), '--build-manifest', build)
      refute status.success?, output
      assert_includes output, 'Missing simulator fixture seed-11'
    end
  end
end
