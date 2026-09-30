#!/usr/bin/env bats
# Pins the shape of .github/workflows/release.yml, which no test can run: it
# needs the owner's secrets, a public repository and an approval. Each test
# parses the workflow with Ruby's YAML (ruby ships with macOS) and checks one
# property of it: who may read a secret, which actions are pinned, the order of
# the steps, when the keychain goes. Tasks 14 and 16 add pages.yml and ci.yml.
#
# Without ruby every test is skipped. actionlint runs too when it is installed.
# RFM_WORKFLOWS_DIR points the checks at another folder of workflows, which is
# how a check is shown to fail: copy release.yml, break it, run the file.

setup_file() {
    if ! command -v ruby > /dev/null 2>&1; then
        skip "ruby is required to parse the workflows"
    fi
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORKFLOWS="${RFM_WORKFLOWS_DIR:-$ROOT/.github/workflows}"
    RELEASE_PRELUDE="$BATS_FILE_TMPDIR/prelude.rb"
    cat > "$RELEASE_PRELUDE" << 'RUBY'
# Loaded before every check: parses $WORKFLOW and offers small helpers.
# `check(ok, message)` records a failure; `finish` prints them and exits 1.
require "yaml"

Encoding.default_external = Encoding::UTF_8 # bats runs with LANG=C, and the workflow has non-ASCII comments
FILE = ENV.fetch("WORKFLOW")
NAME = File.basename(FILE)
ROOT = ENV.fetch("ROOT")
$errors = []

def check(ok, message)
  $errors << message unless ok
end

def finish
  exit 0 if $errors.empty?
  puts $errors.map { |e| "#{NAME}: #{e}" }
  exit 1
end

unless File.file?(FILE)
  puts "#{NAME} is missing"
  exit 1
end

TEXT = File.read(FILE, encoding: "UTF-8")
WF = YAML.load_file(FILE)
ON = WF["on"] || WF[true] || {} # YAML 1.1 reads the bare key `on` as true
JOBS = WF["jobs"] || {}

def job(id)
  JOBS[id] || {}
end

def steps(id)
  job(id)["steps"] || []
end

def step(id, name)
  steps(id).find { |s| s["name"] == name } || {}
end

def runs(id)
  steps(id).map { |s| s["run"].to_s }
end

def all_runs
  JOBS.keys.flat_map { |id| runs(id) }
end

# Every name of `wanted` is a step of the job, in that order; others may sit between.
def in_order?(id, wanted)
  names = steps(id).map { |s| s["name"] }
  indexes = wanted.map { |n| names.index(n) }
  !indexes.include?(nil) && indexes == indexes.sort
end
RUBY
    export ROOT WORKFLOWS RELEASE_PRELUDE
}

# release_check <file>: runs the Ruby on stdin against that workflow, after the prelude.
release_check() {
    local script="$BATS_TEST_TMPDIR/check.rb"
    cat "$RELEASE_PRELUDE" - > "$script"
    export WORKFLOW="$WORKFLOWS/$1"
    run ruby "$script"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

@test "release.yml runs on the strict tag pattern and on a manual dry run, and nothing else" {
    release_check release.yml << 'RUBY'
check(ON.keys.sort == %w[push workflow_dispatch], "triggers are #{ON.keys.sort.inspect}, want push and workflow_dispatch only")
check(ON["push"] == { "tags" => ["v[0-9]+.[0-9]+.[0-9]+"] }, "push must be exactly the strict tag pattern, not #{ON["push"].inspect}")
inputs = ON.dig("workflow_dispatch", "inputs") || {}
check(inputs.keys == ["version"], "the dry run takes exactly one input, `version`, not #{inputs.keys.inspect}")
check((inputs["version"] || {}).values_at("required", "type") == [true, "string"], "`version` must be a required string")
finish
RUBY
}

@test "release.yml starts with no permissions, one release queue and bash with pipefail" {
    release_check release.yml << 'RUBY'
keys = WF.keys.map { |k| k == true ? "on" : k }.sort
check(keys == %w[concurrency defaults jobs name on permissions], "top-level keys are #{keys.inspect}")
check(WF["name"] == "Release", "name is #{WF["name"].inspect}")
check(WF["permissions"] == {}, "top-level permissions must be {}, not #{WF["permissions"].inspect}")
check(WF["defaults"] == { "run" => { "shell" => "bash" } }, "defaults.run.shell must be bash (bash adds -o pipefail)")
check(WF["concurrency"] == { "group" => "release", "cancel-in-progress" => false }, "concurrency must be group release without cancelling: #{WF["concurrency"].inspect}")
finish
RUBY
}

@test "release.yml has the four jobs with their names, runners, permissions and timeouts" {
    release_check release.yml << 'RUBY'
check(JOBS.keys == %w[build publish pages fixture], "jobs are #{JOBS.keys.inspect}")
want = {
  "build" => { "name" => "Build, sign and package", "runs-on" => "xcode-27", "needs" => nil,
               "permissions" => { "contents" => "read" } },
  "publish" => { "name" => "Publish the GitHub release", "runs-on" => "ubuntu-latest", "needs" => "build",
                 "permissions" => { "contents" => "write" } },
  "pages" => { "name" => "Deploy the site", "runs-on" => "ubuntu-latest", "needs" => %w[build publish],
               "permissions" => { "contents" => "read", "pages" => "write", "id-token" => "write" } },
  "fixture" => { "name" => "Open the token-fixture pull request", "runs-on" => "ubuntu-latest", "needs" => %w[build publish],
                 "permissions" => { "contents" => "write", "pull-requests" => "write" } },
}
want.each do |id, expected|
  expected.each { |key, value| check(job(id)[key] == value, "#{id}: #{key} is #{job(id)[key].inspect}, want #{value.inspect}") }
  minutes = job(id)["timeout-minutes"]
  check(minutes.is_a?(Integer) && minutes > 0 && minutes <= 120, "#{id}: timeout-minutes is #{minutes.inspect}")
end
check(job("build")["timeout-minutes"] == 90, "build: timeout-minutes must be 90")
check(job("build")["concurrency"].nil? && job("publish")["concurrency"].nil?, "only pages may have a job-level concurrency group")
check(job("pages")["concurrency"] == { "group" => "pages", "cancel-in-progress" => false }, "pages: concurrency must be group pages: #{job("pages")["concurrency"].inspect}")
finish
RUBY
}

@test "only build names the release environment, and pages deploys through github-pages" {
    release_check release.yml << 'RUBY'
JOBS.each do |id, j|
  environment = j["environment"]
  case id
  when "build" then check(environment == "release", "build: environment is #{environment.inspect}, want release")
  when "pages"
    check(environment == { "name" => "github-pages", "url" => "${{ steps.deployment.outputs.page_url }}" },
          "pages: environment is #{environment.inspect}")
  else check(environment.nil?, "#{id}: must not name an environment, but has #{environment.inspect}")
  end
end
check(TEXT.scan(/^\s*environment:\s*release\s*$/).size == 1, "`environment: release` must appear exactly once")
finish
RUBY
}

@test "secrets are read only by build, only these four, each by the one step that needs it" {
    release_check release.yml << 'RUBY'
WANTED = {
  "Import the signing identity" => %w[RFM_SIGNING_P12_BASE64 RFM_SIGNING_P12_PASSWORD],
  "Token fixture (release hook)" => %w[RFM_FIXTURE_TOKEN_KEY],
  "Generate the appcast" => %w[SPARKLE_ED_PRIVATE_KEY],
}
outside = WF.reject { |key, _| key == "jobs" }.to_s
check(outside !~ /\b(secrets|vars)\b/, "no secret or variable at the top level")
JOBS.each do |id, j|
  text = j.to_s
  check(text.scan(/\bsecrets\b/).size == text.scan(/\bsecrets\.[A-Za-z_][A-Za-z0-9_]*/).size,
        "#{id}: read secrets as secrets.NAME only")
  next if id == "build"
  check(text !~ /\bsecrets\b/, "#{id}: must not read secrets (found #{text.scan(/\bsecrets\.\w+/).uniq.join(", ")})")
  check(text !~ /\bvars\./, "#{id}: must not read variables")
end
job("build").fetch("steps").each do |s|
  used = s.to_s.scan(/\bsecrets\.(\w+)/).flatten.sort
  want = (WANTED[s["name"]] || []).sort
  check(used == want, "build: step #{s["name"].inspect} reads secrets #{used.inspect}, want #{want.inspect}")
  check(s.reject { |key, _| key == "env" }.to_s !~ /\bsecrets\b/, "build: step #{s["name"].inspect} must pass secrets through env only")
end
check(job("build").reject { |key, _| key == "steps" }.to_s !~ /\bsecrets\b/, "build: no job-level secret")
vars = job("build").fetch("steps").select { |s| s.to_s =~ /\bvars\./ }
check(vars.map { |s| s["name"] } == ["Token fixture (release hook)"], "only the hook step may read a variable: #{vars.map { |s| s["name"] }.inspect}")
check(TEXT.scan(/\bvars\.(\w+)/).flatten.uniq == ["RFM_FIXTURE_TOKEN_URL"], "the only variable is RFM_FIXTURE_TOKEN_URL")
finish
RUBY
}

@test "no run block interpolates an expression, and none turns on shell tracing" {
    release_check release.yml << 'RUBY'
JOBS.each_key do |id|
  steps(id).each do |s|
    run = s["run"].to_s
    check(!run.include?("${{"), "#{id}: '#{s["name"]}' interpolates ${{ }} into a run block; pass it through env")
    check(run !~ /\bset\s+-[a-zA-Z]*x/ && run !~ /\bbash\s+-[a-zA-Z]*x/, "#{id}: '#{s["name"]}' turns on shell tracing")
    check(s["shell"].nil?, "#{id}: '#{s["name"]}' overrides the shell")
  end
end
finish
RUBY
}

@test "every action is pinned by full commit SHA with a version comment" {
    release_check release.yml << 'RUBY'
lines = TEXT.lines.select { |l| l =~ /\buses:/ }
check(lines.size >= 8, "expected the workflow's actions, found #{lines.size}")
lines.each do |l|
  ok = l =~ /\A\s*(-\s+)?uses:\s+[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[0-9a-f]{40}\s+#\s+v\d+\.\d+\.\d+\s*\z/
  check(ok, "not pinned as owner/repo@<40 hex> # vN.N.N: #{l.strip}")
end
used = JOBS.values.flat_map { |j| (j["steps"] || []).map { |s| s["uses"] } }.compact
check(used.size == lines.size, "#{used.size} steps use an action, but #{lines.size} lines say uses:")
finish
RUBY
}

@test "every action is at a major that runs on Node 24" {
    release_check release.yml << 'RUBY'
# The first major of each action that the plan pins; Node 20 majors no longer run (2026-09-23).
NODE24 = {
  "actions/checkout" => 7, "actions/setup-go" => 7, "actions/upload-artifact" => 7,
  "actions/download-artifact" => 8, "actions/upload-pages-artifact" => 5, "actions/deploy-pages" => 5,
}
seen = []
TEXT.lines.each do |l|
  m = l.match(/uses:\s+([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)@\S+\s+#\s+v(\d+)/) or next
  seen << m[1]
  floor = NODE24[m[1]]
  check(floor, "#{m[1]} is not in the NODE24 table of workflows.bats; add the first major that runs on Node 24")
  check(floor.nil? || m[2].to_i >= floor, "#{m[1]} v#{m[2]} needs Node 20; use v#{floor} or later")
end
check((NODE24.keys - seen).empty?, "release.yml no longer uses #{(NODE24.keys - seen).inspect}; remove them from NODE24")
finish
RUBY
}

@test "build runs its eighteen steps in the planned order" {
    release_check release.yml << 'RUBY'
check(in_order?("build", [
  "Check out", "Preflight", "Set up Go", "Install tools", "Show the toolchain", "Import the signing identity",
  "Token fixture (release hook)", "Build the patched engine", "Generate the Xcode project", "Universal Release build",
  "Remove the signing keychain", "Check the app", "Make the disk image", "Make the update and source archives",
  "Generate the appcast", "Write the release summary", "Upload the release files", "Upload the token fixture",
]), "build's steps are #{steps("build").map { |s| s["name"] }.inspect}")
check(steps("build").size == 18, "build has #{steps("build").size} steps, want exactly the 18 planned ones")
check(job("build")["if"].nil?, "build must not be conditional: a tag push and a dry run both build")
finish
RUBY
}

@test "publish, pages and fixture run their steps in the planned order" {
    release_check release.yml << 'RUBY'
{
  "publish" => ["Check out", "Download the release files", "Verify the release files", "Replace a leftover draft",
                "Create the draft release", "Publish as latest", "Check the live feed"],
  "pages" => ["Check out", "Download the release files", "Stage the site", "Upload the Pages artifact", "Deploy"],
  "fixture" => ["Check out the default branch", "Download the token fixture", "Commit and open the pull request"],
}.each do |id, wanted|
  check(steps(id).map { |s| s["name"] } == wanted, "#{id}: steps are #{steps(id).map { |s| s["name"] }.inspect}, want #{wanted.inspect}")
end
finish
RUBY
}

@test "the signing keychain is removed right after the build, always, and before the app check" {
    release_check release.yml << 'RUBY'
names = steps("build").map { |s| s["name"] }
removal = names.index("Remove the signing keychain")
build = names.index("Universal Release build")
check(removal && build && removal == build + 1, "the removal must be the step right after 'Universal Release build', the last one that signs")
check(removal && names.index("Check the app") > removal, "the removal must come before 'Check the app'")
check(step("build", "Remove the signing keychain")["if"].to_s.strip == "always()", "the removal must run with `if: always()`")
path = '"$RUNNER_TEMP/rfm-signing.keychain-db"'
check(step("build", "Import the signing identity")["run"].to_s.include?("import-signing-identity.sh create #{path}"), "the import must create #{path}")
check(step("build", "Remove the signing keychain")["run"].to_s.include?("import-signing-identity.sh delete #{path}"), "the removal must delete #{path}")
check(step("build", "Import the signing identity")["run"].to_s.include?('>> "$GITHUB_ENV"'), "the import's KEYCHAIN line must reach $GITHUB_ENV")
finish
RUBY
}

@test "the release hook is called once, for token-fixture only, and never as required" {
    release_check release.yml << 'RUBY'
calls = all_runs.flat_map { |r| r.scan(/release-hook\.sh\s+(\S+)/).flatten }
check(calls == ["token-fixture"], "release-hook.sh must be called once, for token-fixture, not #{calls.inspect}")
check(all_runs.none? { |r| r =~ /release-hook\.sh[^\n]*--required/ }, "release-hook.sh must not get --required before Plan 5 adds the hook (Ruling 12)")
run = step("build", "Token fixture (release hook)")["run"].to_s
check(run.include?('token-fixture "$VERSION" "$RUNNER_TEMP/published-tags.txt" "$paths"'), "the hook gets the version, the published tags and the paths file")
check(step("build", "Token fixture (release hook)")["id"] == "fixture", "the hook step's id must be fixture")
check(run.include?('COPYFILE_DISABLE=1 tar --no-xattrs -cf "$RUNNER_TEMP/token-fixture.tar" -T "$paths"'), "the fixture tar must carry no AppleDouble ._ entries (COPYFILE_DISABLE=1 tar --no-xattrs)")
finish
RUBY
}

@test "publish and fixture run only for a pushed tag, and pages only after publish" {
    release_check release.yml << 'RUBY'
%w[publish fixture].each do |id|
  check(job(id)["if"].to_s.include?("github.event_name == 'push'"), "#{id}: `if` must require github.event_name == 'push'")
end
check(job("fixture")["if"].to_s.include?("needs.build.outputs.fixture == 'true'"), "fixture: must wait for the hook to have written files")
check(Array(job("pages")["needs"]).include?("publish"), "pages: must need publish, so a dry run never deploys")
check(Array(job("fixture")["needs"]).include?("publish"), "fixture: must need publish")
finish
RUBY
}

@test "the release build takes its version and identity from the preflight and the imported keychain" {
    release_check release.yml << 'RUBY'
build = step("build", "Universal Release build")
run = build["run"].to_s.gsub(/\s+/, " ")
[
  "-project RoomForMac.xcodeproj", "-scheme RoomForMac", "-configuration Release", '-destination "generic/platform=macOS"',
  "-derivedDataPath build/DerivedData", 'MARKETING_VERSION="$VERSION"', 'CURRENT_PROJECT_VERSION="$BUILD_NUMBER"',
  'CODE_SIGN_IDENTITY="RoomForMac Self-Signed"', 'OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN"',
].each { |part| check(run.include?(part), "the build must pass #{part}") }
check(run.strip.end_with?(" build"), "the build action must be `build`")
check(build["env"] == { "RFM_NO_ENGINE_BUILD" => "1" }, "the build runs with RFM_NO_ENGINE_BUILD=1 and nothing else")
check(step("build", "Build the patched engine")["run"].to_s.strip == "scripts/ensure-engine.sh", "the engine comes from ensure-engine.sh")
check(step("build", "Generate the Xcode project")["run"].to_s.strip == "xcodegen generate", "the project comes from xcodegen generate")
setup_go = step("build", "Set up Go")["with"] || {}
check(setup_go["go-version-file"] == "vendor/mole/go.mod" && setup_go["cache"] == false, "Go comes from vendor/mole/go.mod, without a cache")
finish
RUBY
}

@test "the app check runs the release gate and app_bundle.bats for a universal, hardened build" {
    release_check release.yml << 'RUBY'
check_app = step("build", "Check the app")
run = check_app["run"].to_s
check(run.include?('scripts/check-release-app.sh "$APP" --version "$VERSION"'), "the gate must run on $APP with --version $VERSION")
check(run.include?('APP="$APP" EXPECT_UNIVERSAL=1 EXPECT_HARDENED=1 bats scripts/tests/app_bundle.bats'), "app_bundle.bats must run universal and hardened")
check(check_app["env"] == { "RFM_ALLOW_PROMPTS" => "1" }, "the check sets RFM_ALLOW_PROMPTS=1, as ci.yml's Bundle checks do")
finish
RUBY
}

@test "the dry run runs the preflight in dry-run mode and build cannot create anything on GitHub" {
    release_check release.yml << 'RUBY'
pre = step("build", "Preflight")
run = pre["run"].to_s
check(pre["id"] == "preflight", "the preflight step's id must be preflight")
check(run.include?('release-preflight.sh --dry-run "$INPUT_VERSION"'), "a manual run must pass --dry-run and the input version")
check(run.include?('release-preflight.sh "$GITHUB_REF_NAME"'), "a tag push must pass the tag")
check(run.include?("gh release list --exclude-drafts --limit 1000"), "the published tags must come from every non-draft release")
check(run.include?("gh repo view --json visibility"), "the visibility must come from gh repo view")
env = pre["env"] || {}
check(env["INPUT_VERSION"] == "${{ inputs.version }}", "INPUT_VERSION must be inputs.version")
check(env["DEFAULT_BRANCH"] == "${{ github.event.repository.default_branch }}", "DEFAULT_BRANCH must be the repository's default branch")
check(env["GH_TOKEN"] == "${{ github.token }}", "the preflight reads GitHub with github.token")
check(runs("build").none? { |r| r =~ /gh release (create|edit|delete|upload)/ || r =~ /git push/ }, "build must not write to GitHub")
finish
RUBY
}

@test "publish makes a draft with all six files, then marks it latest, then checks the live feed" {
    release_check release.yml << 'RUBY'
create = step("publish", "Create the draft release")["run"].to_s.gsub(/\s+/, " ")
check(create.include?('gh release create "$TAG" --verify-tag --draft'), "the release must be created as a draft on a tag that exists")
check(!create.include?("--latest"), "the draft is not marked latest; only the publish step does that")
check(create.include?('--title "RoomForMac $VERSION"'), "the title is RoomForMac $VERSION")
check(create.include?('--notes-file "release-notes/$VERSION.md"'), "the notes come from release-notes/$VERSION.md")
assets = create.scan(%r{"?release-files/[^ ]+}).map { |a| a.delete('"') }.sort
want = ["release-files/RoomForMac.dmg", 'release-files/RoomForMac-$VERSION.tar.xz', 'release-files/RoomForMac-$VERSION-source.tar.gz',
        "release-files/appcast.xml", "release-files/latest.json", "release-files/SHA256SUMS"].sort
check(assets == want, "the release must carry exactly the six files, not #{assets.inspect}")
check(step("publish", "Publish as latest")["run"].to_s.strip == 'gh release edit "$TAG" --draft=false --latest', "publishing is `gh release edit \"$TAG\" --draft=false --latest`")
check(step("publish", "Replace a leftover draft")["run"].to_s.strip == 'scripts/release-publish.sh replace-draft "$TAG"', "the leftover draft goes through release-publish.sh replace-draft")
check(step("publish", "Verify the release files")["run"].to_s.strip == 'scripts/release-publish.sh check-files release-files "$VERSION"', "the downloaded files are verified before anything is created")
check(step("publish", "Check the live feed")["run"].to_s.strip == 'scripts/release-publish.sh check-feed "$BUILD_NUMBER"', "the live feed check must use $BUILD_NUMBER")
check(job("publish")["env"] == {
  "GH_REPO" => "${{ github.repository }}", "TAG" => "${{ needs.build.outputs.tag }}",
  "VERSION" => "${{ needs.build.outputs.version }}", "BUILD_NUMBER" => "${{ needs.build.outputs.build_number }}",
}, "publish's environment is #{job("publish")["env"].inspect}")
with_token = job("publish")["steps"].select { |s| (s["env"] || {})["GH_TOKEN"] }.map { |s| s["name"] }
check(with_token == ["Verify the release files", "Replace a leftover draft", "Create the draft release", "Publish as latest", "Check the live feed"], "GH_TOKEN only on the steps that call gh or release-publish.sh, not #{with_token.inspect}")
check(step("publish", "Create the draft release")["env"] == { "GH_TOKEN" => "${{ github.token }}" }, "GH_TOKEN comes from github.token")
frun = step("fixture", "Commit and open the pull request")["run"].to_s
check(frun.include?("\\.github(/|$)") && frun.include?("(^|/)\\.git(/|$)"), "the fixture path filter must reject .github/ and .git/ paths")
check(frun.include?("tar -tvf token-fixture/token-fixture.tar | grep -v '^[-d]'"), "the fixture tar must hold only regular files and directories")
finish
RUBY
}

@test "the release files and the token fixture are uploaded as the planned artifacts" {
    release_check release.yml << 'RUBY'
files = step("build", "Upload the release files")
check(files["uses"].to_s.start_with?("actions/upload-artifact@"), "the release files go through upload-artifact")
with = files["with"] || {}
check(with["name"] == "release-files", "the artifact is named release-files")
check(with["path"] == "build/release/", "the artifact is build/release/, which check-files limits to the six files")
check(with["if-no-files-found"] == "error", "an empty upload must fail")
check(with["retention-days"] == "${{ github.event_name == 'workflow_dispatch' && 7 || 30 }}", "retention is 7 days for a dry run and 30 otherwise")
fixture = step("build", "Upload the token fixture")
check(fixture["if"].to_s.strip == "steps.fixture.outputs.written == 'true'", "the fixture uploads only when the hook wrote files")
check((fixture["with"] || {})["name"] == "token-fixture", "the fixture artifact is named token-fixture")
check((fixture["with"] || {})["path"] == "${{ runner.temp }}/token-fixture.tar", "the fixture artifact is the tar the hook step made")
check(job("pages").fetch("steps").map { |s| (s["with"] || {})["name"] }.include?("release-files"), "pages downloads release-files")
check(step("build", "Write the release summary")["run"].to_s.include?('release-publish.sh check-files build/release "$VERSION"'), "the six files are checked before they are uploaded")
finish
RUBY
}

@test "a job reads needs and step outputs only where they exist" {
    release_check release.yml << 'RUBY'
JOBS.each do |id, j|
  needs = Array(j["needs"])
  j.to_s.scan(/\bneeds\.([A-Za-z0-9_-]+)\./).flatten.uniq.each do |dep|
    check(needs.include?(dep), "#{id}: reads needs.#{dep}, but lists #{needs.inspect} (the needs context holds direct dependencies only)")
  end
end
outputs = job("build")["outputs"] || {}
check(outputs.keys.sort == %w[build_number fixture strict tag version], "build's outputs are #{outputs.keys.sort.inspect}")
PREFLIGHT = %w[tag version build_number archive_name source_name strict_release dry_run app]
TEXT.scan(/steps\.preflight\.outputs\.(\w+)/).flatten.uniq.each do |name|
  check(PREFLIGHT.include?(name), "steps.preflight.outputs.#{name} is not a key release-preflight.sh prints (#{PREFLIGHT.join(" ")})")
end
JOBS.each do |id, j|
  j.to_s.scan(/needs\.build\.outputs\.(\w+)/).flatten.uniq.each do |name|
    check(outputs.key?(name), "#{id}: needs.build.outputs.#{name} is not a declared output of build")
  end
end
finish
RUBY
}

@test "every script and bats file the workflow calls exists and is executable, except the site's" {
    release_check release.yml << 'RUBY'
# `pages` calls scripts/stage-site.sh, which Task 14 creates and checks.
%w[build publish fixture].each do |id|
  runs(id).each do |run|
    run.scan(%r{scripts/[A-Za-z0-9_./-]+\.sh}).uniq.each do |path|
      full = File.join(ROOT, path)
      check(File.file?(full) && File.executable?(full), "#{id}: #{path} is missing or not executable")
    end
    run.scan(%r{scripts/tests/[A-Za-z0-9_./-]+\.bats}).uniq.each do |path|
      check(File.file?(File.join(ROOT, path)), "#{id}: #{path} is missing")
    end
  end
end
check(all_runs.join("\n").scan(%r{scripts/[A-Za-z0-9_./-]+\.sh}).uniq.size >= 10, "the workflow no longer calls the release scripts")
finish
RUBY
}

@test "checkouts drop their credentials, except in the job that pushes the fixture branch" {
    release_check release.yml << 'RUBY'
JOBS.each do |id, j|
  (j["steps"] || []).each do |s|
    next unless s["uses"].to_s.start_with?("actions/checkout@")
    persist = (s["with"] || {})["persist-credentials"]
    if id == "fixture"
      check(persist.nil?, "fixture: '#{s["name"]}' pushes a branch, so it keeps the default credentials")
    else
      check(persist == false, "#{id}: '#{s["name"]}' must set persist-credentials: false")
    end
  end
end
check_out = step("build", "Check out")["with"] || {}
check(check_out["submodules"] == "recursive" && check_out["fetch-depth"] == 0, "build: the checkout needs submodules: recursive and fetch-depth: 0")
check((step("fixture", "Check out the default branch")["with"] || {})["ref"] == "${{ github.event.repository.default_branch }}", "fixture: must check out the default branch")
finish
RUBY
}

@test "the dry run's throwaway tag is made only in a dry run and only when the tag is missing" {
    release_check release.yml << 'RUBY'
run = step("build", "Make the update and source archives")["run"].to_s
check(run =~ /\[ "\$DRY_RUN" = 1 \] && ! git rev-parse --quiet --verify "refs\/tags\/\$TAG"[^\n]*; then\n\s+git tag "\$TAG"\n\s*fi/, "git tag \"$TAG\" must sit behind the dry-run and missing-tag conditions")
check(run.scan(/git tag/).size == 1 && !run.include?("git push"), "the local tag is never pushed")
finish
RUBY
}

@test "the appcast step fails closed, and a dry run falls back to the template notes" {
    release_check release.yml << 'RUBY'
appcast = step("build", "Generate the appcast")
run = appcast["run"].to_s
check(run =~ /if \[ -s "\$RUNNER_TEMP\/published-tags\.txt" \]; then\n\s+gh release download --pattern appcast\.xml --dir "\$RUNNER_TEMP\/previous"\n\s+args\+=\(--previous "\$RUNNER_TEMP\/previous\/appcast\.xml"\)\n\s*fi/,
      "the previous appcast must be downloaded whenever a release is published, and passed with --previous")
check(run =~ /if \[ "\$DRY_RUN" = 1 \] && \[ ! -s "\$notes" \]; then\n\s+notes=release-notes\/TEMPLATE\.md\n\s*fi/,
      "only a dry run without release-notes/$VERSION.md may fall back to release-notes/TEMPLATE.md")
check(run.include?('notes="release-notes/$VERSION.md"'), "the notes are release-notes/$VERSION.md")
check(!run.include?("|| true") && !run.include?("2>/dev/null"), "the download must not swallow its errors")
check(run.include?('scripts/make-appcast.sh "${args[@]}"'), "the appcast comes from make-appcast.sh")
check((appcast["env"] || {}).keys.sort == %w[GH_REPO GH_TOKEN SPARKLE_ED_PRIVATE_KEY], "the appcast step's env is #{(appcast["env"] || {}).keys.sort.inspect}")
finish
RUBY
}

@test "no workflow uses pull_request_target" {
    local file count=0
    for file in "$WORKFLOWS"/*.yml; do
        [ -f "$file" ] || continue
        count=$((count + 1))
        if grep -n 'pull_request_target' "$file"; then
            echo "$file uses pull_request_target" >&2
            return 1
        fi
    done
    [ "$count" -ge 1 ]
}

@test "actionlint passes on release.yml" {
    command -v actionlint > /dev/null 2>&1 || skip "actionlint is not installed (brew install actionlint)"
    cd "$ROOT"
    run actionlint "$WORKFLOWS/release.yml"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}
