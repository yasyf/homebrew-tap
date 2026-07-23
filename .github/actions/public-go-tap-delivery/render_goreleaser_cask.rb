#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "yaml"

def fail!(message)
  warn(message)
  exit(1)
end

def string!(value, label)
  fail!("#{label} must be a non-empty string") unless value.is_a?(String) && !value.empty?
  fail!("#{label} must be one line") if value.match?(/[\r\n]/)
  value
end

def safe_name!(value, label)
  value = string!(value, label)
  fail!("#{label} is not a safe Homebrew name") unless value.match?(/\A[a-z0-9][a-z0-9+._-]*\z/)
  value
end

def ruby_string(value)
  value.dump
end

def target_asset!(assets, os_name, arch)
  pattern = /(?:\A|_)#{Regexp.escape(os_name)}_#{Regexp.escape(arch)}(?:\.|_)/
  matches = assets.keys.select { |name| name.end_with?(".tar.gz") && name.match?(pattern) }.sort
  fail!("expected one #{os_name}/#{arch} tar.gz asset, found #{matches.inspect}") unless matches.length == 1
  matches.first
end

config_path, metadata_path, output_path = ARGV
fail!("usage: render_goreleaser_cask.rb CONFIG METADATA OUTPUT") unless output_path

begin
  config = YAML.safe_load(File.read(config_path), permitted_classes: [], permitted_symbols: [], aliases: false)
  metadata = JSON.parse(File.read(metadata_path))
rescue Psych::Exception, JSON::ParserError => e
  fail!("could not parse tagged source contract: #{e.message}")
end

fail!("GoReleaser config must be an object") unless config.is_a?(Hash)
fail!("GoReleaser config version must be 2") unless config["version"] == 2
project_name = safe_name!(config["project_name"], "project_name")
casks = config["homebrew_casks"]
fail!("GoReleaser config must contain exactly one homebrew_casks entry") unless casks.is_a?(Array) && casks.length == 1
cask = casks.first
fail!("homebrew_casks entry must be an object") unless cask.is_a?(Hash)

allowed_keys = %w[name ids binaries repository homepage description dependencies custom_block hooks]
unknown_keys = cask.keys - allowed_keys
fail!("unsupported homebrew_casks keys: #{unknown_keys.sort.inspect}") unless unknown_keys.empty?

delivery_name = safe_name!(metadata["delivery_name"], "delivery_name")
cask_name = safe_name!(cask.fetch("name", project_name), "homebrew_casks.name")
fail!("delivery-name #{delivery_name.inspect} does not equal tagged cask name #{cask_name.inspect}") unless delivery_name == cask_name

repository = cask["repository"]
fail!("homebrew_casks.repository must be an object") unless repository.is_a?(Hash)
unless repository["owner"] == "yasyf" && repository["name"] == "homebrew-tap"
  fail!("tagged cask repository must be yasyf/homebrew-tap")
end

ids = cask["ids"]
archives = config["archives"]
fail!("GoReleaser config archives must be a non-empty array") unless archives.is_a?(Array) && !archives.empty?
if ids
  fail!("homebrew_casks.ids must be a non-empty string array") unless ids.is_a?(Array) && !ids.empty? && ids.all? { |id| id.is_a?(String) && !id.empty? }
  archive_ids = archives.filter_map { |entry| entry["id"] if entry.is_a?(Hash) }
  missing_ids = ids - archive_ids
  fail!("homebrew_casks.ids do not exist in archives: #{missing_ids.inspect}") unless missing_ids.empty?
end
selected_archives = if ids
                      archives.select { |entry| entry.is_a?(Hash) && ids.include?(entry["id"]) }
                    else
                      archives
                    end
unless selected_archives.length == 1 && selected_archives.first.is_a?(Hash)
  fail!("tagged cask must select exactly one archive definition")
end
selected_archive = selected_archives.first
formats = selected_archive["formats"]
unless formats.is_a?(Array) && formats == ["tar.gz"]
  fail!("tagged cask archive must have the exact artifact kind formats: [tar.gz]")
end
name_template = string!(selected_archive["name_template"], "selected archive name_template")

binaries = cask.fetch("binaries", [project_name])
unless binaries.is_a?(Array) && !binaries.empty? && binaries.all? { |item| item.is_a?(String) && item.match?(/\A[A-Za-z0-9._+\/-]+\z/) }
  fail!("homebrew_casks.binaries must be a non-empty safe string array")
end
homepage = string!(cask["homepage"], "homebrew_casks.homepage")
description = string!(cask["description"], "homebrew_casks.description")
fail!("homebrew_casks.homepage must be HTTPS") unless homepage.start_with?("https://")

dependencies = cask.fetch("dependencies", [])
fail!("homebrew_casks.dependencies must be an array") unless dependencies.is_a?(Array)
dependencies.each do |dependency|
  unless dependency.is_a?(Hash) && dependency.length == 1 && %w[formula cask].include?(dependency.keys.first)
    fail!("each cask dependency must contain exactly one formula or cask key")
  end
  safe_name!(dependency.values.first, "cask dependency")
end

custom_block = cask["custom_block"]
fail!("homebrew_casks.custom_block must be a string") if custom_block && !custom_block.is_a?(String)
hooks = cask.fetch("hooks", {})
fail!("homebrew_casks.hooks must be an object") unless hooks.is_a?(Hash)
unknown_hook_phases = hooks.keys - %w[pre post]
fail!("unsupported cask hook phases: #{unknown_hook_phases.inspect}") unless unknown_hook_phases.empty?
hooks.each do |phase, operations|
  fail!("cask hook phase #{phase.inspect} must be an object") unless operations.is_a?(Hash)
  unknown_operations = operations.keys - %w[install uninstall]
  fail!("unsupported cask hook operations: #{unknown_operations.inspect}") unless unknown_operations.empty?
  operations.each do |operation, body|
    fail!("cask hook #{phase}.#{operation} must be a non-empty string") unless body.is_a?(String) && !body.empty?
  end
end

assets = metadata["assets"]
fail!("verified assets must be an object") unless assets.is_a?(Hash) && !assets.empty?
targets = {
  ["macos", "intel"] => target_asset!(assets, "darwin", "amd64"),
  ["macos", "arm"] => target_asset!(assets, "darwin", "arm64"),
  ["linux", "intel"] => target_asset!(assets, "linux", "amd64"),
  ["linux", "arm"] => target_asset!(assets, "linux", "arm64")
}
source_repository = string!(metadata["repository"], "source repository")
tag = string!(metadata["tag"], "tag")
version = string!(metadata["version"], "version")
target_values = {
  ["macos", "intel"] => ["darwin", "amd64"],
  ["macos", "arm"] => ["darwin", "arm64"],
  ["linux", "intel"] => ["linux", "amd64"],
  ["linux", "arm"] => ["linux", "arm64"]
}
target_values.each do |target, (os_name, arch)|
  expected_name = name_template
                  .gsub("{{ .ProjectName }}", project_name)
                  .gsub("{{ .Version }}", version)
                  .gsub("{{ .Os }}", os_name)
                  .gsub("{{ .Arch }}", arch)
  fail!("selected archive name_template uses unsupported fields") if expected_name.include?("{{")
  expected_name = "#{expected_name}.tar.gz"
  actual_name = targets.fetch(target)
  unless actual_name == expected_name
    fail!("verified #{os_name}/#{arch} asset #{actual_name.inspect} does not match tagged archive name #{expected_name.inspect}")
  end
end

lines = []
lines << "# This file was rendered from an exact public release. DO NOT EDIT."
lines << "# Source: #{source_repository}@#{metadata['source_sha']} (#{metadata['source_path']})"
lines << "cask #{ruby_string(cask_name)} do"
if custom_block
  custom_block.each_line(chomp: true) { |line| lines << "  #{line}" }
  lines << ""
end
lines << "  version #{ruby_string(version)}"
lines << ""
[["macos", "darwin"], ["linux", "linux"]].each do |dsl_os, _asset_os|
  lines << "  on_#{dsl_os} do"
  %w[intel arm].each do |dsl_arch|
    asset = targets.fetch([dsl_os, dsl_arch])
    lines << "    on_#{dsl_arch} do"
    lines << "      sha256 #{ruby_string(assets.fetch(asset))}"
    url = "https://github.com/#{source_repository}/releases/download/#{tag}/#{asset}"
    lines << "      url #{ruby_string(url)}"
    lines << "    end"
  end
  lines << "  end"
  lines << ""
end
lines << "  name #{ruby_string(cask_name)}"
lines << "  desc #{ruby_string(description)}"
lines << "  homepage #{ruby_string(homepage)}"
lines << ""
lines << "  livecheck do"
lines << "    skip \"Auto-generated on release.\""
lines << "  end"
unless dependencies.empty?
  dependencies.each do |dependency|
    kind, name = dependency.first
    lines << "  depends_on #{kind}: #{ruby_string(name)}"
  end
end
lines << "" unless dependencies.empty?
binaries.each { |binary| lines << "  binary #{ruby_string(binary)}" }

hook_names = {
  ["pre", "install"] => "preflight",
  ["post", "install"] => "postflight",
  ["pre", "uninstall"] => "uninstall_preflight",
  ["post", "uninstall"] => "uninstall_postflight"
}
hooks.each do |phase, operations|
  operations.each do |operation, body|
    lines << ""
    lines << "  #{hook_names.fetch([phase, operation])} do"
    body.each_line(chomp: true) { |line| lines << "    #{line}" }
    lines << "  end"
  end
end
lines << ""
lines << "  # No zap stanza required"
lines << "end"
lines << ""

FileUtils.mkdir_p(File.dirname(output_path)) unless Dir.exist?(File.dirname(output_path))
File.write(output_path, lines.join("\n"))
