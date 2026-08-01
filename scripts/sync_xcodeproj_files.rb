#!/usr/bin/env ruby
# frozen_string_literal: true

# Incrementally reconciles Swift file references and target membership without
# regenerating project UUIDs. Pass --check for a read-only CI/review gate.

require "pathname"
require "xcodeproj"
require_relative "xcodeproj_sources"

check_only = ARGV.delete("--check")
abort "Usage: bundle exec ruby scripts/sync_xcodeproj_files.rb [--check]" unless ARGV.empty?

project = Xcodeproj::Project.open(RunShelfProjectSources::PROJECT_PATH)
targets = RunShelfProjectSources::TARGET_NAMES.transform_values do |name|
  project.targets.find { |target| target.name == name } || abort("Target not found: #{name}")
end

def referenced_swift_paths(project)
  project.files.each_with_object({}) do |file_ref, paths|
    next unless file_ref.path&.end_with?(".swift")

    real_path = file_ref.real_path.to_s
    next unless real_path.start_with?(Dir.pwd + "/")

    paths[real_path.delete_prefix(Dir.pwd + "/")] = file_ref
  end
end

def ensure_group(project, segments)
  segments.reduce(project.main_group) do |group, segment|
    group.children.find do |child|
      child.is_a?(Xcodeproj::Project::Object::PBXGroup) && child.display_name == segment
    end || group.new_group(segment, segment)
  end
end

def membership_for(file_ref, targets)
  targets.each_with_object([]) do |(key, target), membership|
    membership << key if target.source_build_phase.files_references.include?(file_ref)
  end
end

on_disk = RunShelfProjectSources.disk_swift_paths
referenced = referenced_swift_paths(project)
missing = on_disk - referenced.keys
stale = referenced.keys.select do |path|
  (path.start_with?("RunShelf/") || path.start_with?("RunShelfTests/")) && !on_disk.include?(path)
end
membership_mismatches = (on_disk & referenced.keys).each_with_object([]) do |path, mismatches|
  expected = RunShelfProjectSources.targets_for(path).sort
  actual = membership_for(referenced.fetch(path), targets).sort
  mismatches << [path, actual, expected] unless actual == expected
end

if check_only
  if missing.empty? && stale.empty? && membership_mismatches.empty?
    puts "Xcode project Swift references and target membership are in sync."
    exit 0
  end

  missing.each { |path| warn "missing reference: #{path}" }
  stale.each { |path| warn "stale reference: #{path}" }
  membership_mismatches.each do |path, actual, expected|
    warn "membership mismatch: #{path} actual=#{actual.join(',')} expected=#{expected.join(',')}"
  end
  exit 1
end

stale.each do |path|
  referenced.fetch(path).remove_from_project
end

missing.each do |path|
  segments = Pathname.new(path).each_filename.to_a
  file_name = segments.pop
  referenced[path] = ensure_group(project, segments).new_file(file_name)
end

(on_disk & referenced.keys).each do |path|
  file_ref = referenced.fetch(path)
  expected = RunShelfProjectSources.targets_for(path)
  targets.each do |key, target|
    build_file = target.source_build_phase.files.find { |file| file.file_ref == file_ref }
    if expected.include?(key)
      target.source_build_phase.add_file_reference(file_ref) unless build_file
    else
      build_file&.remove_from_project
    end
  end
end

if missing.empty? && stale.empty? && membership_mismatches.empty?
  puts "Xcode project is already in sync."
else
  project.save
  puts "Reconciled Xcode project: added=#{missing.size} removed=#{stale.size} membership=#{membership_mismatches.size}"
end
