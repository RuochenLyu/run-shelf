#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "xcodeproj"

project_path = "RunShelf.xcodeproj"
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
development_team = ENV["RUN_SHELF_DEVELOPMENT_TEAM"].to_s.strip

app_target = project.new_target(:application, "RunShelf", :osx, "15.0")
app_target.product_reference.path = "Run Shelf.app"

scheduler_target = project.new_target(:command_line_tool, "RunShelfScheduler", :osx, "15.0")
scheduler_target.product_reference.path = "RunShelfScheduler"

cli_target = project.new_target(:command_line_tool, "RunShelfCLI", :osx, "15.0")
cli_target.product_reference.path = "runshelf"

test_target = project.new_target(:unit_test_bundle, "RunShelfTests", :osx, "15.0")
test_target.product_reference.path = "RunShelfTests.xctest"

main_group = project.main_group
main_group.clear
source_group = main_group.new_group("RunShelf", "RunShelf")
test_group = main_group.new_group("RunShelfTests", "RunShelfTests")

def app_source?(path)
  File.extname(path) == ".swift" &&
    path.start_with?("RunShelf/") &&
    !path.start_with?("RunShelf/SchedulerProcess/") &&
    !path.start_with?("RunShelf/CLI/")
end

def scheduler_source?(path)
  return false unless File.extname(path) == ".swift"
  return true if path.start_with?("RunShelf/SchedulerProcess/")
  return false unless path.start_with?("RunShelf/Core/")
  return false if path.start_with?("RunShelf/Core/Stores/")
  true
end

def cli_source?(path)
  return false unless File.extname(path) == ".swift"
  return true if path.start_with?("RunShelf/CLI/")
  return false unless path.start_with?("RunShelf/Core/")
  return false if path.start_with?("RunShelf/Core/Stores/")
  true
end

def test_source?(path)
  File.extname(path) == ".swift" &&
    (path.start_with?("RunShelf/Core/") || path.start_with?("RunShelfTests/"))
end

launch_agent_file_refs = []

def add_files(group, filesystem_path, app_target, scheduler_target, cli_target, test_target, launch_agent_file_refs)
  Dir.children(filesystem_path).sort.each do |entry|
    next if entry.start_with?(".")

    path = File.join(filesystem_path, entry)
    if File.directory?(path)
      if File.extname(path) == ".xcassets"
        file_ref = group.new_file(entry)
        app_target.resources_build_phase.add_file_reference(file_ref)
        next
      end

      add_files(group.new_group(entry, entry), path, app_target, scheduler_target, cli_target, test_target, launch_agent_file_refs)
      next
    end

    file_ref = group.new_file(entry)
    case File.extname(path)
    when ".swift"
      app_target.source_build_phase.add_file_reference(file_ref) if app_source?(path)
      scheduler_target.source_build_phase.add_file_reference(file_ref) if scheduler_source?(path)
      cli_target.source_build_phase.add_file_reference(file_ref) if cli_source?(path)
      test_target.source_build_phase.add_file_reference(file_ref) if test_source?(path)
    when ".xcstrings"
      app_target.resources_build_phase.add_file_reference(file_ref)
    when ".plist"
      launch_agent_file_refs << file_ref if path.start_with?("RunShelf/Support/")
    end
  end
end

add_files(source_group, "RunShelf", app_target, scheduler_target, cli_target, test_target, launch_agent_file_refs)
add_files(test_group, "RunShelfTests", app_target, scheduler_target, cli_target, test_target, launch_agent_file_refs)
app_target.add_dependency(scheduler_target)
app_target.add_dependency(cli_target)

helpers_phase = app_target.new_copy_files_build_phase("Embed Helpers")
helpers_phase.symbol_dst_subfolder_spec = :wrapper
helpers_phase.dst_path = "Contents/Library/Helpers"
helpers_phase.add_file_reference(scheduler_target.product_reference)
helpers_phase.add_file_reference(cli_target.product_reference)

launch_agents_phase = app_target.new_copy_files_build_phase("Embed LaunchAgents")
launch_agents_phase.symbol_dst_subfolder_spec = :wrapper
launch_agents_phase.dst_path = "Contents/Library/LaunchAgents"
launch_agent_file_refs.each do |file_ref|
  launch_agents_phase.add_file_reference(file_ref)
end

project.build_configurations.each do |config|
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
  config.build_settings["SDKROOT"] = "macosx"
  config.build_settings["SUPPORTED_PLATFORMS"] = "macosx"
end

app_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_NAME"] = "Run Shelf"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.aix4u.runshelf"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "Run Shelf"
  config.build_settings["INFOPLIST_KEY_LSApplicationCategoryType"] = "public.app-category.developer-tools"
  config.build_settings["INFOPLIST_KEY_NSPrincipalClass"] = "NSApplication"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["DEVELOPMENT_TEAM"] = development_team unless development_team.empty?
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  config.build_settings["ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"] = "NO"
  config.build_settings["SKIP_INSTALL"] = "NO"
end

scheduler_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_NAME"] = "RunShelfScheduler"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.aix4u.runshelf.scheduler"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["CREATE_INFOPLIST_SECTION_IN_BINARY"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["DEVELOPMENT_TEAM"] = development_team unless development_team.empty?
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  config.build_settings["ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"] = "NO"
  config.build_settings["SKIP_INSTALL"] = "YES"
end

cli_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_NAME"] = "runshelf"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.aix4u.runshelf.cli"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["CREATE_INFOPLIST_SECTION_IN_BINARY"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["DEVELOPMENT_TEAM"] = development_team unless development_team.empty?
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  config.build_settings["ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS"] = "NO"
  config.build_settings["SKIP_INSTALL"] = "YES"
end

test_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.aix4u.runshelf.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["SWIFT_VERSION"] = "5.0"
  config.build_settings["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @loader_path/Frameworks @executable_path/../Frameworks"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["DEVELOPMENT_TEAM"] = development_team unless development_team.empty?
end

project.save

project.recreate_user_schemes
Xcodeproj::XCScheme.share_scheme(project_path, "RunShelf")
Xcodeproj::XCScheme.share_scheme(project_path, "RunShelfScheduler")
Xcodeproj::XCScheme.share_scheme(project_path, "RunShelfCLI")
Xcodeproj::XCScheme.share_scheme(project_path, "RunShelfTests")

run_scheme_path = File.join(project_path, "xcshareddata", "xcschemes", "RunShelf.xcscheme")
run_scheme = Xcodeproj::XCScheme.new(run_scheme_path)
run_scheme.add_test_target(test_target)
run_scheme.save_as(project_path, "RunShelf", true)

FileUtils.rm_rf(File.join(project_path, "xcuserdata"))
