# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require_relative 'build-support'

root = File.expand_path('..', __dir__)
scratch = UndoKitBuild.directory('Package')
File.open(File.join(UndoKitBuild.root, 'package.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
  lock.flock(File::LOCK_EX)
  system('swift', 'test', '--package-path', root, '--scratch-path', scratch, *ARGV)
  exit($?.exitstatus || 1)
end
