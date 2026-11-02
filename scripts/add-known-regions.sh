#!/usr/bin/env bash
#
# xcodegen only lists a language under knownRegions when it finds an .lproj
# folder, and string catalogs have none. Run after every `xcodegen generate`
# (project.yml's postGenCommand) so Xcode shows German and Azerbaijani too.
#
set -euo pipefail

sed -i '' -E 's/^([[:space:]]*)en,$/\1en,\
\1de,\
\1az,/' FocusGuard.xcodeproj/project.pbxproj
