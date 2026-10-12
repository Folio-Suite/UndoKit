#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'open3'

{
  %w[xcodebuild -version] => /\AXcode 27\.0\nBuild version 27A266a\s*\z/,
  %w[xcrun swift --version] => /Apple Swift version 6\.4(?:\s|\()/
}.each do |command, expected|
  output, status = Open3.capture2e(*command)
  puts output
  abort "Expected Xcode 27.0 (27A266a) and Apple Swift 6.4: #{command.join(' ')}" unless status.success? && expected.match?(output)
end
