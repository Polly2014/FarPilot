#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
workflow="$root/.github/workflows/signpath-application.yml"
ci="$root/.github/workflows/ci.yml"
stable="$root/.github/workflows/release.yml"

[[ -f "$workflow" ]] || { printf 'SignPath application workflow is missing\n' >&2; exit 1; }

ruby - "$workflow" "$ci" "$stable" <<'RUBY'
require "yaml"

CARGO_DENY_ACTION = "taiki-e/install-action@4a76afe23f9e08d2d9550fb56e556444e8611d21" # v2.90.4

workflow_path, ci_path, stable_path = ARGV

def load_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
end

def triggers(document)
  document.fetch("on", document.fetch(true, nil))
end

def assert(condition, message)
  raise message unless condition
end

def steps_text(job)
  job.fetch("steps", []).map { |step| [step["name"], step["run"], step["uses"], step["with"], step["env"]].inspect }.join("\n")
end

def assert_dependency_policy_step(job)
  steps = job.fetch("steps", [])
  install_index = steps.index do |step|
    step["uses"] == CARGO_DENY_ACTION &&
      step.dig("with", "tool") == "cargo-deny@0.20.2" &&
      step.dig("with", "fallback") == "none"
  end
  run_index = steps.index do |step|
    step["name"] == "Verify dependency policy" &&
      step["run"].to_s.strip == "bash tests/security/dependency_policy.sh"
  end
  assert(!install_index.nil?, "quality gate must install pinned cargo-deny")
  assert(!run_index.nil?, "quality gate must execute dependency policy script")
  assert(install_index < run_index, "cargo-deny must be installed before dependency policy execution")
end

def validate_application(document)
  trigger = triggers(document)
  assert(trigger.is_a?(Hash), "trigger must be a mapping")
  assert(trigger.keys == ["workflow_dispatch"], "application workflow must be manual-only")
  dispatch = trigger["workflow_dispatch"]
  assert(dispatch.nil? || dispatch == {} || dispatch == {"inputs" => {}}, "application workflow accepts no mutable inputs")

  assert(document.dig("permissions", "contents") == "read", "global contents permission must be read")
  env = document.fetch("env")
  assert(env["APPLICATION_VERSION"] == "0.1.0", "application version must be fixed")
  assert(env["APPLICATION_TAG"] == "v0.1.0-unsigned.1", "application tag must be fixed")
  assert(env["APPLICATION_ASSET"] == "farpilot-windows-x86_64-unsigned.exe", "unsigned filename must be fixed")

  jobs = document.fetch("jobs")
  assert(jobs.keys.sort == %w[quality publish windows].sort, "application jobs must be quality/windows/publish only")
  jobs.each do |name, job|
    next if name == "publish"
    assert((job["permissions"] || {})["contents"] != "write", "only publish may write contents")
  end

  quality = jobs.fetch("quality")
  assert(quality["runs-on"] == "ubuntu-24.04", "quality runner must be Ubuntu")
  assert_dependency_policy_step(quality)
  quality_text = steps_text(quality)
  [
    "cargo fmt --all -- --check",
    "cargo clippy --workspace --all-targets --all-features -- -D warnings",
    "cargo test --workspace --all-targets",
    "cargo test --doc --workspace",
    "tests/install/install_sh.sh",
    "tests/install/gateway_installer.sh",
    "tests/security/sshd_restrictions.sh",
    "tests/security/sshd_integration.sh",
    "tests/release/workflow_assets.sh",
    "tests/release/signpath_application_workflow.sh",
    "shellcheck",
  ].each { |needle| assert(quality_text.include?(needle), "quality gate missing #{needle}") }

  windows = jobs.fetch("windows")
  assert(windows["runs-on"] == "windows-2025", "Windows runner must be windows-2025")
  assert(Array(windows["needs"]) == ["quality"] || windows["needs"] == "quality", "Windows job must need quality")
  windows_text = steps_text(windows)
  [
    "cargo test --workspace --all-targets",
    "PSScriptAnalyzer",
    "deploy/windows/test-install.ps1",
    "cargo build --release -p farpilot-cli",
    "farpilot-windows-x86_64-unsigned.exe",
    "farpilot 0.1.0",
    "actions/upload-artifact",
  ].each { |needle| assert(windows_text.include?(needle), "Windows job missing #{needle}") }

  publish = jobs.fetch("publish")
  assert(Array(publish["needs"]).sort == %w[quality windows], "publish prerequisites incomplete")
  assert(publish.dig("permissions", "contents") == "write", "publish needs contents write")
  environment = publish["environment"]
  environment_name = environment.is_a?(Hash) ? environment["name"] : environment
  assert(environment_name == "signpath-application", "publish must use protected signpath-application environment")
  condition = publish.fetch("if")
  assert(condition.include?("github.event_name == 'workflow_dispatch'"), "publish must be manual-dispatch only")
  assert(condition.include?("github.ref_name == 'main'"), "publish must be main-only")
  assert(condition.include?("github.repository == 'Polly2014/FarPilot'"), "publish must bind repository identity")

  publish_text = steps_text(publish)
  [
    "git ls-remote --exit-code --tags",
    'tag_status=$?',
    "unexpected git ls-remote status",
    "assert_release_absent",
    "unexpected GitHub release lookup status",
    "/git/refs",
    "refs/tags/",
    "ref=",
    "sha=",
    "GITHUB_SHA",
    "/git/ref/tags/",
    "object.sha",
    "gh release create",
    "--verify-tag",
    "--prerelease",
    "farpilot-windows-x86_64-unsigned.exe",
    "SHA256SUMS",
    "build-metadata.json",
    "UNSIGNED SIGNPATH APPLICATION ARTIFACT",
    "Do not install on production systems.",
    "purpose",
    "signpath-application",
    "unsigned",
  ].each { |needle| assert(publish_text.include?(needle), "publish job missing #{needle}") }
  guard_occurrences = publish.fetch("steps").sum { |step| step["run"].to_s.scan(/\bassert_release_absent\b/).length }
  assert(guard_occurrences == 4, "release absence helper must be defined and called in both preflight and atomic publish steps")
  race_step = publish.fetch("steps").find { |step| step["run"]&.include?("/git/refs") }
  assert(!race_step.nil?, "atomic tag creation step is missing")
  race_lines = race_step.fetch("run").lines.map(&:rstrip)
  definition_index = race_lines.index("assert_release_absent() {")
  close_index = definition_index && race_lines.each_index.find { |index| index > definition_index && race_lines[index] == "}" }
  call_index = close_index && race_lines.each_index.find { |index| index > close_index && race_lines[index].strip == "assert_release_absent" }
  ref_index = call_index && race_lines.each_index.find { |index| index > call_index && race_lines[index].include?("if ! gh api --method POST") && race_lines[index].include?("/git/refs") }
  assert(definition_index && close_index && call_index && ref_index, "atomic publish step must define, call, then create the tag")
  assert(race_lines[(close_index + 1)...call_index].all? { |line| line.strip.empty? }, "release absence call must immediately follow its local helper definition")
  assert(race_lines[(call_index + 1)...ref_index].all? { |line| line.strip.empty? }, "release absence call must occur immediately before atomic tag creation")
  assert(!publish_text.include?("--target"), "release creation must not override the atomically created tag")
  assert(!publish_text.include?("gh release view"), "generic release-view checks are fail-open")
  assert(!publish_text.include?("if git ls-remote"), "tag preflight must distinguish every exit status")
  assert(!publish_text.include?("manifest.json"), "application prerelease must not publish stable manifest")
  assert(!publish_text.include?("install.sh"), "application prerelease must not publish installers")
  assert(!publish_text.include?("--latest"), "application prerelease must not become latest")

  all_uses = jobs.values.flat_map { |job| job.fetch("steps", []).map { |step| step["uses"] }.compact }
  all_uses.each { |action| assert(action.match?(/@[A-Za-z0-9._-]+$/), "action is not pinned: #{action}") }
end

application = load_yaml(workflow_path)
validate_application(application)

ci_text = File.read(ci_path)
assert(ci_text.include?("tests/release/signpath_application_workflow.sh"), "normal CI must test application workflow")
assert(!ci_text.include?("gh release create"), "normal CI must never publish")

stable_text = File.read(stable_path)
assert(!stable_text.include?("v0.1.0-unsigned.1"), "stable workflow must not reference application prerelease")
assert(!stable_text.include?("farpilot-windows-x86_64-unsigned.exe"), "stable workflow must not publish unsigned application asset")

mutations = {
  "push trigger" => ->(doc) { trigger_map = triggers(doc); trigger_map["push"] = {"branches" => ["main"]} },
  "top-level write" => ->(doc) { doc["permissions"]["contents"] = "write" },
  "missing environment" => ->(doc) { doc["jobs"]["publish"].delete("environment") },
  "unguarded main" => ->(doc) { doc["jobs"]["publish"]["if"] = "github.event_name == 'workflow_dispatch'" },
  "normal release" => ->(doc) { doc["jobs"]["publish"]["steps"].each { |step| step["run"]&.gsub!("--prerelease", "") } },
  "wrong asset" => ->(doc) { doc["env"]["APPLICATION_ASSET"] = "farpilot-windows-x86_64.exe" },
  "missing warning" => ->(doc) { doc["jobs"]["publish"]["steps"].each { |step| step["run"]&.gsub!("Do not install on production systems.", "") } },
  "extra installer" => ->(doc) { doc["jobs"]["publish"]["steps"] << {"run" => "cp install.sh release/install.sh"} },
  "missing quality" => ->(doc) { doc["jobs"]["windows"]["needs"] = nil },
  "missing dependency policy run" => ->(doc) { doc["jobs"]["quality"]["steps"].reject! { |step| step["name"] == "Verify dependency policy" } },
  "mutable cargo-deny action" => ->(doc) {
    step = doc["jobs"]["quality"]["steps"].find { |candidate| candidate["uses"]&.start_with?("taiki-e/install-action@") }
    step["uses"] = "taiki-e/install-action@v2"
  },
  "missing verify tag" => ->(doc) { doc["jobs"]["publish"]["steps"].each { |step| step["run"]&.gsub!("--verify-tag", "") } },
  "target override" => ->(doc) { doc["jobs"]["publish"]["steps"].each { |step| step["run"]&.gsub!("--prerelease", "--prerelease --target $GITHUB_SHA") } },
  "missing ref creation" => ->(doc) { doc["jobs"]["publish"]["steps"].reject! { |step| step.to_s.include?("/git/refs") } },
  "generic release lookup" => ->(doc) { doc["jobs"]["publish"]["steps"].each { |step| step["run"]&.gsub!("assert_release_absent", "gh release view") } },
  "fail-open tag check" => ->(doc) { doc["jobs"]["publish"]["steps"].each { |step| step["run"]&.gsub!("unexpected git ls-remote status", "ignored git ls-remote status") } },
  "missing immediate race guard" => ->(doc) {
    step = doc["jobs"]["publish"]["steps"].find { |candidate| candidate["run"]&.include?("/git/refs") }
    step["run"].sub!(/(\n\s*)assert_release_absent(\n\s*\n\s*if ! gh api --method POST)/, '\\1\\2')
  },
}
mutations.each do |name, mutation|
  copy = Marshal.load(Marshal.dump(application))
  mutation.call(copy)
  begin
    validate_application(copy)
  rescue RuntimeError
    next
  end
  raise "workflow validator accepted unsafe mutation: #{name}"
end

puts "SignPath application workflow structure verified"
RUBY
