#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'minitest/autorun'
require 'open3'
require 'json'
require 'tmpdir'

class ScaleRunnerTest < Minitest::Test
  def test_command_preserves_independent_state_across_fresh_processes
    Dir.mktmpdir('undokit-scale-test-') do |directory|
      output, status = Open3.capture2e('ruby', File.join(__dir__, 'check-undokit-scale.rb'),
        '--groups', '100', '--seed', '11', '--repetitions', '1', '--reopens', '2', '--output', directory)
      assert status.success?, output
      report = JSON.parse(File.read(File.join(directory, 'report.json')))
      assert_equal 'smoke_completed', report.fetch('result')
      fixture = report.fetch('runs').first
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
