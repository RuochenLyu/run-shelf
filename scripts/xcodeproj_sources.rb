# frozen_string_literal: true

module RunShelfProjectSources
  PROJECT_PATH = "RunShelf.xcodeproj"
  TARGET_NAMES = {
    app: "RunShelf",
    scheduler: "RunShelfScheduler",
    cli: "RunShelfCLI",
    test: "RunShelfTests"
  }.freeze

  module_function

  def disk_swift_paths
    (Dir.glob("RunShelf/**/*.swift") + Dir.glob("RunShelfTests/**/*.swift")).sort
  end

  def targets_for(path)
    return [] unless File.extname(path) == ".swift"

    targets = []
    targets << :app if path.start_with?("RunShelf/") &&
      !path.start_with?("RunShelf/SchedulerProcess/") &&
      !path.start_with?("RunShelf/CLI/")
    targets << :scheduler if path.start_with?("RunShelf/SchedulerProcess/") || shared_core_source?(path)
    targets << :cli if path.start_with?("RunShelf/CLI/") || shared_core_source?(path)
    targets << :test if path.start_with?("RunShelf/Core/") ||
      path.start_with?("RunShelfTests/") ||
      [
        "RunShelf/Editor/ShellScriptEditor.swift",
        "RunShelf/Editor/ShellSyntaxHighlighter.swift"
      ].include?(path)
    targets
  end

  def shared_core_source?(path)
    path.start_with?("RunShelf/Core/") && !path.start_with?("RunShelf/Core/Stores/")
  end
end
