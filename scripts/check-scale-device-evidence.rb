#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'json'
require 'digest'
require 'optparse'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: scripts/check-scale-device-evidence.rb --evidence PATH --build-manifest PATH --observations PATH'
  parser.on('--evidence PATH') { |v| options[:evidence] = File.expand_path(v) }
  parser.on('--build-manifest PATH') { |v| options[:build] = File.expand_path(v) }
  parser.on('--observations PATH') { |v| options[:observations] = File.expand_path(v) }
  parser.on('--artifact-report PATH', 'inspect one runtime artifact inventory without physical qualification') { |v| options[:artifact] = File.expand_path(v) }
  parser.on('--simulator-evidence PATH', 'validate full simulator fixtures without physical qualification') { |v| options[:simulator] = File.expand_path(v) }
  parser.on('-h', '--help') { puts parser; exit 0 }
end.parse!
abort 'Exact external build manifest required' unless options[:build]
abort 'Evidence and physical observations required (or --artifact-report / --simulator-evidence)' unless options[:artifact] || options[:simulator] || options.values_at(:evidence, :observations).all?
report = {result: 'incomplete', buildManifestSHA256: Digest::SHA256.file(options[:build]).hexdigest,
          observationsSHA256: options[:observations] && Digest::SHA256.file(options[:observations]).hexdigest, runs: [],
          limitation: 'Automated evidence inventory does not replace maintainer review of physical observations; no cold-cache or forced-termination claim.'}
def verify_artifact!(runtime, build)
  expected = build.fetch('artifactSHA256')
  actual = runtime.fetch('installedArtifactSHA256')
  raise 'Installed artifact identity differs from exact build manifest' unless !expected.empty? && actual == expected
end
begin
  build = JSON.parse(File.read(options[:build]))
  if options[:artifact]
    verify_artifact!(JSON.parse(File.read(options[:artifact])), build)
    report[:result] = 'artifact_identity_matched_for_inspection'
    report[:physicalQualification] = false
    puts JSON.pretty_generate(report)
    exit 0
  end
  if options[:simulator]
    raise 'Exact successful simulator-full build required' unless build.fetch('sdk') == 'iphonesimulator' && build.fetch('profile') == 'simulator-full' && build.fetch('buildSucceeded') && !build.fetch('artifactSHA256').empty?
    raise 'Missing simulator fixture seed-11' unless File.directory?(File.join(options[:simulator], 'seed-11'))
    runner = JSON.parse(File.read(File.join(options[:simulator], 'RunnerReport.json')))
    raise 'Runner did not complete the full simulator fixture matrix' unless %w[validating simulator_full_completed].include?(runner.fetch('result')) && runner.fetch('profile') == 'simulator-full' && runner.fetch('groups') == 10_000 && runner.fetch('repetitions') == 3 && runner.fetch('reopens') == 10 && runner.fetch('runs').map { |run| run.fetch('seed') } == [11, 12, 13]
    raise 'Runner build manifest or runtime identity is incomplete' unless runner.fetch('buildManifestSHA256') == Digest::SHA256.file(options[:build]).hexdigest && runner.fetch('runtime').fetch('runtime').fetch('version') && runner.fetch('runtime').fetch('runtime').fetch('buildversion')
    raise 'Runner exceeded actual app RSS budget or omitted fresh process evidence' unless runner.fetch('runs').all? { |run| run.fetch('pids').length == 11 && run.fetch('pids').uniq.length == 11 && run.fetch('samples').length == 10 && run.fetch('peakRSSBytes') <= 2 * 1024**3 }
    raise 'Simulator evidence requires clean committed source' unless build.fetch('sourceDirtyPaths').empty?
    (11..13).each do |seed|
      directory = File.join(options[:simulator], "seed-#{seed}")
      raise "Missing simulator fixture seed-#{seed}" unless File.directory?(directory)
      raise "Failure artifacts retained for seed #{seed}; inspect before acceptance" unless Dir.glob(File.join(directory, 'Failure-*.json')).empty?
      workload = JSON.parse(File.read(File.join(directory, 'WorkloadReport.json')))
      raise 'Exact installed app identity required' unless workload.fetch('installedArtifactSHA256') == build.fetch('artifactSHA256')
      embedded = JSON.parse(File.read(File.join(directory, 'BuildManifest.json')))
      %w[sourceHead sourceDirtyPaths sourceSHA256 toolchain swift configuration sdk].each do |identity|
        raise "Fixture build identity differs from exact manifest: #{identity}" unless embedded.fetch(identity) == build.fetch(identity)
      end
      raise 'Full simulator build profile missing from fixture' unless embedded.fetch('profile') == 'simulator-full'
      raise 'Full 10,000-group simulator workload required' unless workload.fetch('platform') == 'iOS Simulator' && workload.fetch('groups') == 10_000 && workload.fetch('seed') == seed
      budgets = JSON.parse(File.read(File.join(directory, 'Budgets.json')))
      expected_budgets = {'seconds' => 900, 'residentBytes' => 2 * 1024**3, 'ownedBytes' => 2 * 1024**3, 'minimumFreeBytes' => 4 * 1024**3, 'ordinaryHeartbeatSeconds' => 1}
      raise 'Simulator full-profile budgets were changed or inflated' unless budgets == expected_budgets
      raise 'Simulator workload exceeded predeclared bounds' unless workload.fetch('phases').fetch('total') <= budgets.fetch('seconds') &&
        workload.fetch('peakResidentBytes') <= budgets.fetch('residentBytes') &&
        workload.fetch('peakOwnedAllocatedBytes') <= budgets.fetch('ownedBytes') &&
        workload.fetch('maximumOrdinaryHeartbeatGapSeconds') <= budgets.fetch('ordinaryHeartbeatSeconds')
      samples = (1..10).map { |index| JSON.parse(File.read(File.join(directory, "Reopen-#{index}.json"))) }
      run_record = runner.fetch('runs').find { |entry| entry.fetch('seed') == seed }
      raise 'Runner process IDs do not match workload and fresh reopen reports' unless run_record.fetch('pids') == [workload.fetch('processID')] + samples.map { |sample| sample.fetch('processID') }
      samples.each { |sample| raise 'Reopen app identity differs from exact build' unless sample.fetch('installedArtifactSHA256') == build.fetch('artifactSHA256') }
      raise 'Distinct fresh processes required' unless samples.map { |sample| sample.fetch('processID') }.uniq.length == 10 && samples.none? { |sample| sample.fetch('processID') == workload.fetch('processID') }
      raise 'Fresh-process sample exceeds bounds or differs from expected state' unless samples.all? do |sample|
        sample.fetch('hostValue') == seed * 100_000 + 20_000 && sample.fetch('deliveries') == 10_102 && sample.fetch('members') == 11_112 &&
          sample.fetch('canUndo') && !sample.fetch('canRedo') && sample.fetch('totalSeconds') <= budgets.fetch('seconds') &&
          sample.fetch('peakResidentBytes') <= budgets.fetch('residentBytes') && sample.fetch('peakOwnedAllocatedBytes') <= budgets.fetch('ownedBytes')
      end
      times = samples.map { |sample| sample.fetch('availabilitySeconds') }.sort
      report[:runs] << {seed: seed, workload: workload, freshProcessSamples: samples,
        freshReopenAvailability: {p50: times[4], p95: times[9], p99: times[9], maximum: times.last}}
    end
    report[:result] = 'simulator_evidence_complete_for_review'
    report[:physicalQualification] = false
    puts JSON.pretty_generate(report)
    exit 0
  end
  raise 'Exact successful physical-device build required' unless build.fetch('sdk') == 'iphoneos' && build.fetch('buildSucceeded') && !build.fetch('artifactSHA256').empty?
  raise 'Physical candidate evidence requires clean committed source' unless build.fetch('sourceDirtyPaths').empty?
  raise 'Physical observations are empty' if File.read(options[:observations]).strip.empty?
  (11..13).each do |seed|
    directory = File.join(options[:evidence], "seed-#{seed}")
    raise "Failure artifacts retained for seed #{seed}; inspect before acceptance" unless Dir.glob(File.join(directory, 'Failure-*.json')).empty?
    workload = JSON.parse(File.read(File.join(directory, 'WorkloadReport.json')))
    verify_artifact!(workload, build)
    embedded = JSON.parse(File.read(File.join(directory, 'BuildManifest.json')))
    %w[sourceHead sourceDirtyPaths sourceSHA256 toolchain swift configuration sdk].each do |identity|
      raise "Fixture build identity differs from exact manifest: #{identity}" unless embedded.fetch(identity) == build.fetch(identity)
    end
    raise 'Physical 10,000-group workload required' unless workload.fetch('platform') == 'physical iOS' && workload.fetch('groups') == 10_000 && workload.fetch('seed') == seed
    budgets = JSON.parse(File.read(File.join(directory, 'Budgets.json')))
    raise 'Device workload exceeded predeclared bounds' unless workload.fetch('phases').fetch('total') <= budgets.fetch('seconds') &&
      workload.fetch('peakResidentBytes') <= budgets.fetch('residentBytes') && workload.fetch('peakOwnedAllocatedBytes') <= budgets.fetch('ownedBytes') &&
      workload.fetch('maximumOrdinaryHeartbeatGapSeconds') <= budgets.fetch('ordinaryHeartbeatSeconds')
    samples = (1..10).map { |index| JSON.parse(File.read(File.join(directory, "Reopen-#{index}.json"))) }
    samples.each { |sample| verify_artifact!(sample, build) }
    raise 'Distinct fresh processes required' unless samples.map { |sample| sample.fetch('processID') }.uniq.length == 10 &&
      samples.none? { |sample| sample.fetch('processID') == workload.fetch('processID') }
    raise 'Fresh-process sample exceeds bounds or differs from independent expected state' unless samples.all? do |sample|
      sample.fetch('hostValue') == seed * 100_000 + 20_000 && sample.fetch('deliveries') == 10_102 && sample.fetch('members') == 11_112 &&
        sample.fetch('canUndo') && !sample.fetch('canRedo') && sample.fetch('totalSeconds') <= budgets.fetch('seconds') &&
        sample.fetch('peakResidentBytes') <= budgets.fetch('residentBytes') && sample.fetch('peakOwnedAllocatedBytes') <= budgets.fetch('ownedBytes')
    end
    values = samples.map { |sample| sample.fetch('availabilitySeconds') }.sort
    report[:runs] << {seed: seed, hardware: workload.fetch('hardware'), os: workload.fetch('os'), workload: workload, freshProcessSamples: samples,
                     freshReopenAvailability: {p50: values[4], p95: values[9], p99: values[9], maximum: values.last}}
  end
  report[:result] = 'physical_evidence_complete_for_review'
rescue StandardError => error
  report[:result] = 'failed'
  report[:failure] = error.message
end
puts JSON.pretty_generate(report)
exit(report[:result] == 'failed' ? 1 : 0)
