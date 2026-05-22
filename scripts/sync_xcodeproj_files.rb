#!/usr/bin/env ruby
# frozen_string_literal: true

# Incrementally syncs Swift files into the existing RunShelf.xcodeproj.
#
# Unlike scripts/generate_xcodeproj.rb (which rebuilds the project from
# scratch and reshuffles every UUID), this script opens the existing
# project, adds any Swift file on disk that is not yet referenced, and
# leaves untouched entries alone. The diff therefore contains only the
# new file references / build files / group children — no UUID churn.
#
# Use this when you add a Swift source file. Run scripts/generate_xcodeproj.rb
# only when you need to (re)create the .xcodeproj from scratch.

require "fileutils"
require "pathname"
require "xcodeproj"

PROJECT_PATH = "RunShelf.xcodeproj"
APP_TARGET_NAME = "RunShelf"
SCHEDULER_TARGET_NAME = "RunShelfScheduler"

def app_source?(relative_path)
  return false unless File.extname(relative_path) == ".swift"
  !relative_path.start_with?("RunShelf/SchedulerProcess/")
end

def scheduler_source?(relative_path)
  return false unless File.extname(relative_path) == ".swift"
  return true if relative_path.start_with?("RunShelf/SchedulerProcess/")
  return false unless relative_path.start_with?("RunShelf/Core/")
  !relative_path.start_with?("RunShelf/Core/Stores/")
end

def collect_disk_swift_paths
  Dir.glob("RunShelf/**/*.swift").sort
end

def collect_referenced_paths(project)
  paths = {}
  project.files.each do |file_ref|
    next unless file_ref.path
    next unless file_ref.path.end_with?(".swift")
    # build a path relative to repo root
    real = file_ref.real_path.to_s
    next unless real.start_with?(Dir.pwd + "/")
    rel = real.sub(Dir.pwd + "/", "")
    paths[rel] = file_ref
  end
  paths
end

def ensure_group(project, segments)
  # segments is e.g. ["RunShelf", "App", "Views"]; find or create nested groups
  # starting from project.main_group.
  group = project.main_group
  segments.each do |segment|
    child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == segment }
    child ||= group.new_group(segment, segment)
    group = child
  end
  group
end

project = Xcodeproj::Project.open(PROJECT_PATH)

app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
scheduler_target = project.targets.find { |t| t.name == SCHEDULER_TARGET_NAME }
raise "App target not found" unless app_target
raise "Scheduler target not found" unless scheduler_target

referenced = collect_referenced_paths(project)
on_disk = collect_disk_swift_paths

added = []
on_disk.each do |relative_path|
  next if referenced.key?(relative_path)

  segments = Pathname.new(relative_path).each_filename.to_a
  file_name = segments.pop
  parent_group = ensure_group(project, segments)

  file_ref = parent_group.new_file(file_name)

  if app_source?(relative_path)
    app_target.source_build_phase.add_file_reference(file_ref)
  end
  if scheduler_source?(relative_path)
    scheduler_target.source_build_phase.add_file_reference(file_ref)
  end

  added << relative_path
end

if added.empty?
  puts "No new Swift files to add."
else
  project.save
  puts "Added #{added.size} file(s):"
  added.each { |p| puts "  + #{p}" }
end
