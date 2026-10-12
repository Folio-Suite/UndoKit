#!/bin/sh
# SPDX-FileCopyrightText: 2026 the Folio Project
# SPDX-License-Identifier: MIT

set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec ruby "$script_dir/test-package.rb" "$@"
