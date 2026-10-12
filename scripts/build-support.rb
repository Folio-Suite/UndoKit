# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'fileutils'

# Keep build output independent of the checkout so worktrees share one home.
module UndoKitBuild
  def self.root
    override = ENV['UNDOKIT_DERIVED_DATA']
    path = override.nil? || override.empty? ?
      File.join(Dir.home, 'Library', 'Developer', 'Xcode', 'DerivedData', 'UndoKit') : override
    File.expand_path(path)
  end

  def self.directory(*components)
    path = File.join(root, *components)
    FileUtils.mkdir_p(path)
    path
  end
end
