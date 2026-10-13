#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'minitest/autorun'
require 'open3'
require 'json'
require 'tmpdir'
require 'digest'

class ScaleRunnerTest < Minitest::Test
  def test_command_preserves_independent_state_across_fresh_processes
    Dir.mktmpdir('undokit-scale-test-') do |directory|
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-undokit-scale.rb'),
        '--groups', '100', '--seed', '11', '--repetitions', '1', '--reopens', '2', '--output', directory)
      assert status.success?, output
      report = JSON.parse(File.read(File.join(directory, 'report.json')))
      assert_equal 'smoke_completed', report.fetch('result')
      fixture = report.fetch('runs').first
      artifact = File.join(directory, 'installed-app')
      Dir.mkdir(artifact)
      File.binwrite(File.join(artifact, 'ScaleDevice'), 'known executable bytes')
      File.binwrite(File.join(artifact, 'HistoryV1.mom'), 'known model bytes')
      artifact_report = File.join(directory, 'artifact.json')
      inventory_output, inventoried = Open3.capture2e(report.fetch('binary'), 'artifact', artifact, artifact_report)
      assert inventoried.success?, inventory_output
      hashes = JSON.parse(File.read(artifact_report))
      assert_equal Digest::SHA256.hexdigest('known executable bytes'), hashes.fetch('ScaleDevice')
      assert_equal Digest::SHA256.hexdigest('known model bytes'), hashes.fetch('HistoryV1.mom')
      build_manifest = File.join(directory, 'artifact-build.json')
      runtime_report = File.join(directory, 'artifact-runtime.json')
      File.write(build_manifest, JSON.generate(artifactSHA256: hashes))
      File.write(runtime_report, JSON.generate(installedArtifactSHA256: hashes))
      checker = File.join(__dir__, 'check-scale-device-evidence.rb')
      matching_output, matching = Open3.capture2e('ruby', checker,
        '--build-manifest', build_manifest, '--artifact-report', runtime_report)
      assert matching.success?, matching_output
      assert_equal false, JSON.parse(matching_output).fetch('physicalQualification')
      File.binwrite(File.join(artifact, 'HistoryV1.mom'), 'changed installed model')
      changed_output, changed = Open3.capture2e(report.fetch('binary'), 'artifact', artifact, artifact_report)
      assert changed.success?, changed_output
      File.write(runtime_report, JSON.generate(installedArtifactSHA256: JSON.parse(File.read(artifact_report))))
      mismatch_output, mismatch = Open3.capture2e('ruby', checker,
        '--build-manifest', build_manifest, '--artifact-report', runtime_report)
      refute mismatch.success?, mismatch_output
      assert_includes mismatch_output, 'Installed artifact identity differs'
      assert_equal 1_100_002, fixture.fetch('workload').fetch('farBack').fetch('value')
      assert_equal 1_100_100, fixture.fetch('workload').fetch('divergent').fetch('value')
      assert_equal [1_100_200, 1_100_200], fixture.fetch('reopens').map { |sample| sample.fetch('hostValue') }
      assert_equal 2, fixture.fetch('reopens').map { |sample| sample.fetch('processID') }.uniq.count
      File.binwrite(File.join(directory, 'repetition-1', 'SharedResource.bin'), 'changed host resource')
      refused_report = File.join(directory, 'refused-readback.json')
      refusal, refused = Open3.capture2e(report.fetch('binary'), 'reopen',
        File.join(directory, 'repetition-1'), refused_report)
      assert_equal 1, refused.exitstatus, refusal
      assert_includes refusal, 'Host resource bytes changed'
      refute File.exist?(refused_report), 'Corrupt readback must not produce a passing report'
    end
  end

  def test_uncertain_receipt_write_stays_unresolved_and_recovers_once_in_a_fresh_process
    Dir.mktmpdir('undokit-scale-receipt-') do |directory|
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-undokit-scale.rb'),
        '--groups', '100', '--repetitions', '1', '--reopens', '1', '--output', directory)
      assert status.success?, output
      binary = JSON.parse(File.read(File.join(directory, 'report.json'))).fetch('binary')
      fixture = File.join(directory, 'uncertain-receipt')
      initial_path = File.join(directory, 'write-failure.json')
      initial_output, initial = Open3.capture2e(binary, 'receipt-write-failure', fixture, initial_path)
      assert initial.success?, initial_output
      first = JSON.parse(File.read(initial_path))
      assert_equal 'unresolved', first.fetch('initialResult')
      assert_equal 'unresolved', first.fetch('retryResult')
      assert_equal 'unresolved', first.fetch('reconciliationResult')
      assert first.fetch('suspended')
      readback_path = File.join(directory, 'write-readback.json')
      readback_output, readback = Open3.capture2e(binary, 'receipt-write-readback', fixture, readback_path)
      assert readback.success?, readback_output
      reopened = JSON.parse(File.read(readback_path))
      assert_equal 17, reopened.fetch('hostValue')
      assert_equal 1, reopened.fetch('deliveries')
      assert_equal 1, reopened.fetch('members')
      refute_equal first.fetch('processID'), reopened.fetch('processID')
    end
  end

  def test_lowered_memory_guard_refuses_without_large_allocation
    Dir.mktmpdir('undokit-scale-guard-') do |directory|
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-undokit-scale.rb'),
        '--groups', '100', '--repetitions', '1', '--reopens', '1', '--max-rss-bytes', '1', '--output', directory)
      refute status.success?, output
      report = JSON.parse(File.read(File.join(directory, 'report.json')))
      assert_equal 'failed', report.fetch('result')
      assert_includes report.fetch('failure'), 'RSS budget exceeded'
      assert_empty report.fetch('runs')
    end
  end
end
