#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
release="$root/.github/workflows/release.yml"
ci="$root/.github/workflows/ci.yml"

[[ -f "$release" ]] || { echo "release workflow is missing" >&2; exit 1; }

ruby - "$release" "$ci" <<'RUBY'
require "yaml"

release_path, ci_path = ARGV

def load_workflow(path)
  YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
end

def trigger_map(document)
  document.fetch("on", document.fetch(true, nil))
end

def assert(condition, message)
  raise message unless condition
end

def steps_text(job)
  job.fetch("steps", []).map { |step| [step["name"], step["run"], step["uses"], step["with"]].inspect }.join("\n")
end

def assert_dependency_policy_step(job, label)
  steps = job.fetch("steps", [])
  install_index = steps.index do |step|
    step["uses"] == "taiki-e/install-action@v2" &&
      step.dig("with", "tool") == "cargo-deny@0.20.2" &&
      step.dig("with", "fallback") == "none"
  end
  run_index = steps.index do |step|
    step["name"] == "Verify dependency policy" &&
      step["run"].to_s.strip == "bash tests/security/dependency_policy.sh"
  end
  assert(!install_index.nil?, "#{label} must install pinned cargo-deny")
  assert(!run_index.nil?, "#{label} must execute the dependency policy script")
  assert(install_index < run_index, "#{label} must install cargo-deny before dependency policy execution")
end

def validate_release(document)
  triggers = trigger_map(document)
  assert(triggers.is_a?(Hash), "release triggers must be a mapping")
  push = triggers["push"]
  assert(push.is_a?(Hash), "release push trigger is missing")
  assert(push.keys == ["tags"], "release push may contain only tags")
  assert(push["tags"] == ["v*"], "release tags must be exactly v*")
  dispatch = triggers["workflow_dispatch"]
  assert(dispatch.is_a?(Hash), "workflow_dispatch trigger is missing")
  inputs = dispatch.fetch("inputs")
  assert(inputs.dig("dry_run", "type") == "boolean", "dry_run must be boolean")
  assert(inputs.dig("dry_run", "default") == true, "dry_run must default true")
  assert(inputs.dig("version", "required") == true, "manual dry-run version must be required")

  assert(document.dig("permissions", "contents") == "read", "top-level contents permission must be read")
  jobs = document.fetch("jobs")
  expected_jobs = %w[quality ssh-security installers build assemble publish]
  assert(jobs.keys.sort == expected_jobs.sort, "release jobs must be exactly #{expected_jobs.join(', ')}")
  assert_dependency_policy_step(jobs.fetch("quality"), "release quality gate")
  jobs.each do |name, job|
    next if name == "publish"
    permissions = job["permissions"] || {}
    assert(permissions["contents"] != "write", "only publish may have contents write")
  end
  assert(jobs.dig("publish", "permissions", "contents") == "write", "publish must have contents write")

  matrix = jobs.dig("build", "strategy", "matrix", "include")
  expected_matrix = [
    ["ubuntu-24.04", "x86_64-unknown-linux-musl", "farpilot-linux-x86_64"],
    ["ubuntu-24.04-arm", "aarch64-unknown-linux-musl", "farpilot-linux-aarch64"],
    ["macos-15-intel", "x86_64-apple-darwin", "farpilot-macos-x86_64"],
    ["macos-15", "aarch64-apple-darwin", "farpilot-macos-aarch64"],
    ["windows-2025", "x86_64-pc-windows-msvc", "farpilot-windows-x86_64.exe"],
  ]
  actual_matrix = matrix.map { |entry| [entry["runner"], entry["target"], entry["asset"]] }
  assert(actual_matrix == expected_matrix, "five-platform build matrix does not match release contract")
  installer_os = jobs.dig("installers", "strategy", "matrix", "os")
  assert(installer_os == ["ubuntu-24.04", "macos-15", "windows-2025"], "installer matrix must use current hosted runners")
  retired_macos = ["macos-13", "macos-14"]
  configured_runners = actual_matrix.map(&:first) + installer_os
  assert((configured_runners & retired_macos).empty?, "release workflow uses retired macOS runner labels")
  assert(jobs.dig("build", "runs-on") == "${{ matrix.runner }}", "build runner must come from matrix")
  assert(jobs.dig("build", "strategy", "fail-fast") == false, "build matrix must not fail fast")
  build_text = steps_text(jobs.fetch("build"))
  assert(build_text.include?("targets\"=>\"${{ matrix.target }}"), "Rust toolchain must install the matrix target")
  assert(build_text.include?("cargo build --release -p farpilot-cli --target"), "release binary build is missing")
  assert(build_text.include?("retention-days\"=>1") || build_text.include?("retention-days") && build_text.include?("1"), "build artifact retention must be one day")

  assemble = jobs.fetch("assemble")
  assert(Array(assemble["needs"]).sort == %w[build installers quality ssh-security].sort, "assemble prerequisites incomplete")
  assemble_text = steps_text(assemble)
  %w[scripts/release_manifest.py scripts/validate_release_assets.py install.sh install.ps1 install-gateway.sh manifest.json].each do |needle|
    assert(assemble_text.include?(needle), "assemble is missing #{needle}")
  end
  %w[farpilot-linux-x86_64 farpilot-linux-aarch64 farpilot-macos-x86_64 farpilot-macos-aarch64 farpilot-windows-x86_64.exe].each do |asset|
    assert(assemble_text.include?(asset), "assemble exact-set check is missing #{asset}")
  end

  publish = jobs.fetch("publish")
  assert(Array(publish["needs"]) == ["assemble"] || publish["needs"] == "assemble", "publish must depend on assemble")
  condition = publish.fetch("if")
  assert(condition.include?("github.event_name == 'push'") && condition.include?("github.ref_type == 'tag'"), "publish must be tag-push only")
  publish_text = steps_text(publish)
  assert(publish_text.include?("gh release create"), "publish must create release with gh")
  assert(publish_text.include?("--verify-tag"), "publish must verify tag")
  assert(publish_text.include?("--notes-from-tag"), "publish must use tag notes")
  assert(publish_text.include?("gh release view"), "publish must refuse existing release")

  all_uses = jobs.values.flat_map { |job| job.fetch("steps", []).map { |step| step["uses"] }.compact }
  all_uses.each do |action|
    assert(action.match?(/@[A-Za-z0-9._-]+$/), "action is not pinned: #{action}")
  end
end

def validate_ci(document)
  assert(document.dig("permissions", "contents") == "read", "CI contents permission must remain read")
  jobs = document.fetch("jobs")
  assert_dependency_policy_step(jobs.fetch("quality"), "normal CI quality gate")
  text = jobs.values.map { |job| steps_text(job) }.join("\n")
  [
    "unittest discover -s tests/release",
    "tests/release/workflow_assets.sh",
    "tests/install/install_sh.sh",
    "tests/install/gateway_installer.sh",
    "shellcheck",
    "PSScriptAnalyzer",
  ].each { |needle| assert(text.include?(needle), "CI is missing #{needle}") }
  assert(!text.include?("gh release create"), "normal CI must never publish")
end

release = load_workflow(release_path)
ci = load_workflow(ci_path)
validate_release(release)
validate_ci(ci)

mutations = {
  "missing build" => ->(doc) { doc["jobs"].delete("build") },
  "broadened branch push" => ->(doc) { trigger_map(doc)["push"] = {"branches" => ["main"], "tags" => ["v*"]} },
  "top-level write" => ->(doc) { doc["permissions"]["contents"] = "write" },
  "unguarded publish" => ->(doc) { doc["jobs"]["publish"]["if"] = "always()" },
  "missing installer" => ->(doc) { doc["jobs"]["assemble"]["steps"].reject! { |step| step.to_s.include?("install-gateway.sh") } },
  "missing dependency policy run" => ->(doc) { doc["jobs"]["quality"]["steps"].reject! { |step| step["name"] == "Verify dependency policy" } },
  "manual publishing" => ->(doc) { doc["jobs"]["publish"]["if"] = "github.event_name == 'workflow_dispatch' && inputs.dry_run == false" },
}
mutations.each do |name, mutation|
  copy = Marshal.load(Marshal.dump(release))
  mutation.call(copy)
  begin
    validate_release(copy)
  rescue RuntimeError
    next
  end
  raise "workflow validator accepted unsafe mutation: #{name}"
end

ci_without_dependency_run = Marshal.load(Marshal.dump(ci))
ci_without_dependency_run["jobs"]["quality"]["steps"].reject! do |step|
  step["name"] == "Verify dependency policy"
end
begin
  validate_ci(ci_without_dependency_run)
rescue RuntimeError
  puts "release workflow structure verified"
  exit 0
end
raise "workflow validator accepted normal CI without dependency policy execution"
RUBY
