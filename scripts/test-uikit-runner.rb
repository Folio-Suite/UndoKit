#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rbconfig'
require 'timeout'

class UIKitRunnerCLITest < Minitest::Test
  def with_tools(mode = 'complete')
    Dir.mktmpdir('uikit-runner-') do |directory|
      bin = File.join(directory, 'bin'); FileUtils.mkdir_p(bin)
      tool = <<~'TOOL'
        require 'json'; require 'fileutils'; require 'rbconfig'
        home = ENV.fetch('UIKIT_TOOL_HOME'); name = File.basename($0); name = 'xcrun' if name == 'simctl-tool'
        File.open(File.join(home, 'calls'), 'a') { |file| file.puts([name, *ARGV].join(' ')) }
        case name
        when 'xcodebuild'
          if ARGV == ['-version']; puts 'Xcode 27.1'; exit; end
          abort 'Global bundle identity override would affect embedded frameworks' if ARGV.any? { |argument| argument.start_with?('PRODUCT_BUNDLE_IDENTIFIER=') }
          setting = ARGV.find { |argument| argument.start_with?('UNDOKIT_UIKIT_BUNDLE_IDENTIFIER=') }
          File.write(File.join(home, 'built-bundle-id'), setting ? setting.split('=', 2).last : 'app.foliosuite.UndoKit.DurableNotesUIKit')
          cache = ARGV[ARGV.index('-derivedDataPath') + 1]
          app = File.join(cache, 'Build/Products/Debug-iphonesimulator/DurableNotesUIKit.app')
          FileUtils.mkdir_p(File.join(app, 'Frameworks/UndoKit.framework'))
          File.write(File.join(app, 'DurableNotesUIKit'), 'fictional-host')
          File.write(File.join(app, 'Frameworks/UndoKit.framework/UndoKit'), 'fictional-runtime')
        when 'swift'; puts 'Apple Swift version 6.4'
        when 'otool', 'codesign', 'install_name_tool'; exit
        when 'xcrun'
          case ARGV[1]
          when 'list'; puts JSON.generate(devices: { iOS: [{udid: 'SIM-1', isAvailable: true, state: 'Booted'}] })
          when 'spawn'
            puts "1001 0 application.#{File.read(File.join(home, 'built-bundle-id'))}" if File.exist?(File.join(home, 'actor-started'))
          when 'bootstatus', 'install'; exit
          when 'get_app_container'; puts File.join(home, 'data')
          when 'launch'
            if ARGV.include?('com.apple.Preferences')
              File.write(File.join(home, 'settings-launched'), '1'); exit
            end
            unless File.exist?(File.join(home, 'actor-started'))
              File.write(File.join(home, 'actor-started'), '1')
              fixture_index = ARGV.index('--undokit-uikit-fixture')
              fixture = fixture_index ? ARGV[fixture_index + 1] : ENV.fetch('SIMCTL_CHILD_UNDOKIT_UIKIT_FIXTURE')
              File.write(File.join(home, 'launch-arguments.json'), JSON.generate(ARGV))
              pid = Process.spawn(RbConfig.ruby, File.join(home, 'actor.rb'), fixture, ARGV.fetch(3), out: File::NULL, err: File::NULL)
              Process.detach(pid)
            else
              count_path = File.join(home, 'foreground-count')
              count = File.exist?(count_path) ? Integer(File.read(count_path)) : 0
              File.write(count_path, (count + 1).to_s)
            end
            puts "#{ARGV.fetch(3)}: 1001"
          else; abort "Unexpected simctl command #{ARGV}"
          end
        else; abort name
        end
      TOOL
      %w[xcodebuild swift otool codesign install_name_tool xcrun].each do |name|
        path = File.join(bin, name); File.write(path, "#!#{RbConfig.ruby}\n#{tool}"); File.chmod(0o755, path)
      end
      File.rename(File.join(bin, 'xcrun'), File.join(bin, 'simctl-tool'))
      File.write(File.join(bin, 'xcrun'), "#!/bin/sh\nif [ \"$1\" != simctl ]; then exec /usr/bin/xcrun \"$@\"; fi\nexec \"#{RbConfig.ruby}\" \"#{bin}/simctl-tool\" \"$@\"\n")
      File.chmod(0o755, File.join(bin, 'xcrun'))
      File.write(File.join(directory, 'actor.rb'), <<~'ACTOR')
        require 'json'; require 'fileutils'; require 'securerandom'
        home = ENV.fetch('UIKIT_TOOL_HOME'); fixture = ARGV.fetch(0)
        root = File.join(home, 'data/Library/Application Support/DurableNotesUIKit', fixture)
        FileUtils.mkdir_p(root)
        write = lambda { |path, value| File.write(path + '.tmp', JSON.generate(value)); File.rename(path + '.tmp', path) }
        write.call(File.join(root, 'Bootstrap.json'), {version: 1, fixture: fixture, check: true, bundleIdentifier: ARGV.fetch(1), processID: 1001})
        id = '00000000-0000-4000-8000-000000000001'; path = File.join(root, 'Transitions', id); FileUtils.mkdir_p(path)
        if ENV['UIKIT_ACTOR_MODE'] == 'orphan'
          write.call(File.join(path, 'Complete.json'), {request: {fixture: fixture, id: id}, command: 'complete'})
          sleep 2
          File.write(File.join(root, 'Failure.txt'), 'Actor timed out waiting for orphan refusal')
          exit
        end
        begin
          ids = ['FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF', '00000000-0000-4000-8000-000000000002',
                 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA', '11111111-1111-4111-8111-111111111111']
          ['start', 'create', 'activate', 'background'].each_with_index do |action, index|
            id = ids[index]; path = File.join(root, 'Transitions', id); FileUtils.mkdir_p(path)
            request = {version: 1, fixture: fixture, id: id, sequence: index + 1, action: action,
              sceneID: action == 'create' ? '' : 'FIRST', priorSceneIDs: index == 0 ? [] : ['FIRST'],
              priorBackgroundClosures: 0, priorBackgroundEvents: 0}
            write.call(File.join(path, 'Request.json'), request)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
            wait = lambda do |&condition|
              until condition.call
                raise "Actor timed out during #{action}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
                sleep 0.02
              end
            end
            wait.call { File.exist?(File.join(path, 'Dispatch.json')) }
            dispatch = JSON.parse(File.read(File.join(path, 'Dispatch.json')))
            expected = request.transform_keys(&:to_s)
            raise 'Uncorrelated dispatch' unless dispatch == {'request'=>expected, 'command'=>'dispatch'}
            status = {request: request, phase: 'ready', observation: 1, applicationState: 'active',
              sceneID: action == 'create' ? 'PEER' : 'FIRST', foregroundActive: true, presentationReady: true,
              currentOwner: true, sessionPhase: 'ready', bindingPhase: 'ready', backgroundClosures: 0, backgroundEvents: 0}
            if action == 'create'
              write.call(File.join(path, 'Status.json'), status.merge(phase: 'dispatched', applicationState: 'inactive', foregroundActive: false))
              wait.call { File.exist?(File.join(home, 'foreground-count')) }
              raise 'Completed before fresh foreground observation' if File.exist?(File.join(path, 'Complete.json'))
            elsif action == 'background'
              write.call(File.join(path, 'Status.json'), status.merge(phase: 'dispatched'))
              wait.call { File.exist?(File.join(home, 'settings-launched')) }
              write.call(File.join(root, 'Events-FIRST.json'), ['UIKit scene entered background', 'Outcome drained and store closed: background'])
              write.call(File.join(path, 'Status.json'), status.merge(phase: 'dispatched', applicationState: 'background', foregroundActive: false))
              wait.call { File.exist?(File.join(path, 'Foreground.json')) && Integer(File.read(File.join(home, 'foreground-count'))) == 2 }
              foreground = JSON.parse(File.read(File.join(path, 'Foreground.json')))
              raise 'Uncorrelated foreground authorization' unless foreground == {'request'=>expected, 'command'=>'foreground'}
              raise 'Completed before Settings return readiness' if File.exist?(File.join(path, 'Complete.json'))
              status[:backgroundClosures] = 1; status[:backgroundEvents] = 1
            end
            wait.call do
              status[:observation] += 1
              write.call(File.join(path, 'Status.json'), status)
              File.exist?(File.join(path, 'Complete.json'))
            end
            complete = JSON.parse(File.read(File.join(path, 'Complete.json')))
            raise 'Uncorrelated completion' unless complete == {'request'=>expected, 'command'=>'complete', 'sceneID'=>status[:sceneID]}
            write.call(File.join(path, 'Status.json'), status.merge(phase: 'completed'))
          end
          write.call(File.join(root, 'Report.json'), {transitionIDs: ids, observations: ['Fictional CLI actor only']})
        rescue => error
          File.write(File.join(root, 'Failure.txt'), error.message)
        end
      ACTOR
      env = {'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'UNDOKIT_DERIVED_DATA' => File.join(directory, 'build'),
             'UIKIT_TOOL_HOME' => directory, 'UIKIT_ACTOR_MODE' => mode}
      output = nil; status = nil
      Open3.popen2e(env, RbConfig.ruby, File.join(__dir__, 'run-durable-notes-uikit.rb'), '--device', 'SIM-1', pgroup: true) do |input, stream, process|
        input.close
        begin
          Timeout.timeout(12) { output = stream.read; status = process.value }
        ensure
          begin
            Process.kill('KILL', -process.pid)
          rescue Errno::ESRCH
            # The runner and bounded fixture actor already exited.
          end
        end
      end
      yield directory, output, status
    end
  end

  def test_external_runner_dispatches_and_completes_a_correlated_request
    with_tools do |directory, output, status|
      assert status.success?, output
      arguments = JSON.parse(File.read(File.join(directory, 'launch-arguments.json')))
      assert_includes arguments, '--undokit-uikit-check'
      assert_includes arguments, '--undokit-uikit-fixture'
      bundle_id = arguments.fetch(3)
      assert_match(/\Aapp\.foliosuite\.UndoKit\.DurableNotesUIKit\.check\.[0-9a-f]{16}\z/, bundle_id)
      assert_equal bundle_id, File.read(File.join(directory, 'built-bundle-id'))
      setup = JSON.parse(File.read(Dir.glob(File.join(directory, 'build/Evidence/UIKitNotes/*/Setup.json')).fetch(0)))
      assert_equal bundle_id, setup.fetch('bundle_id')
      assert_equal 'app.foliosuite.UndoKit.DurableNotesUIKit', setup.fetch('base_bundle_id')
      bootstrap = JSON.parse(File.read(Dir.glob(File.join(directory, 'build/Evidence/UIKitNotes/*/Fixture/Bootstrap.json')).fetch(0)))
      assert_equal bundle_id, bootstrap.fetch('bundleIdentifier')
      report = Dir.glob(File.join(directory, 'build/Evidence/UIKitNotes/*/Fixture/Report.json')).first
      refute_nil report, output
      assert_equal ['FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF', '00000000-0000-4000-8000-000000000002',
                    'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA', '11111111-1111-4111-8111-111111111111'],
                   JSON.parse(File.read(report)).fetch('transitionIDs')
      assert_equal '2', File.read(File.join(directory, 'foreground-count'))
      assert File.exist?(File.join(directory, 'settings-launched'))
    end
  end
  def test_external_runner_refuses_an_orphan_completion_without_dispatch
    with_tools('orphan') do |directory, output, status|
      refute status.success?, output
      assert_includes output, 'Orphan transition authorization without request'
      assert Dir.glob(File.join(directory, 'build/Evidence/UIKitNotes/*/Fixture/Transitions/*/Complete.json')).any?, 'Failure evidence must be retained'
      refute_includes File.read(File.join(directory, 'calls')), 'terminate'
    end
  end

end
