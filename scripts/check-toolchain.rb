#!/usr/bin/env ruby
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

require 'open3'

{
  %w[xcodebuild -version] => /\AXcode 27\.1\nBuild version 27A9275\s*\z/,
  %w[xcrun swift --version] => /Apple Swift version 6\.4 \(swiftlang-6\.4\.0\.34\.1 clang-2100\.3\.34\.1\)/
}.each do |command, expected|
  output, status = Open3.capture2e(*command)
  puts output
  abort "Expected Xcode 27.1 (27A9275) and Apple Swift 6.4: #{command.join(' ')}" unless status.success? && expected.match?(output)
end
