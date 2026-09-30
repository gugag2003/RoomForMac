# Toolchain for building and testing RoomForMac and its engine.
brew "go"
brew "bats-core"
brew "shellcheck"
brew "shfmt"
brew "actionlint" # lints .github/workflows/*.yml, and runs shellcheck on their run: blocks
brew "coreutils" # gtimeout, used by Mole's run_with_timeout
brew "parallel"  # lets Mole's scripts/test.sh run bats files in parallel
brew "xcodegen"  # generates RoomForMac.xcodeproj from project.yml
