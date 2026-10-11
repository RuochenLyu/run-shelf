import Foundation

@main
struct RunShelfSchedulerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == SchedulerRunHost.command {
            runHost(arguments: arguments)
        }

        let engine = makeEngine()

        engine.tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            engine.tick()
        }
        timer.tolerance = 5

        RunLoop.main.run()
    }

    private static func runHost(arguments: [String]) -> Never {
        do {
            let parsed = try SchedulerRunHost.parseArguments(arguments)
            exit(SchedulerRunHost.runHost(arguments: parsed))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(64)
        }
    }

    private static func makeEngine() -> SchedulerEngine {
        guard let executableURL = Bundle.main.executableURL else {
            // 定位不到自身可执行文件时退回进程内运行：功能不变，只是失去崩溃后接续能力。
            return SchedulerEngine()
        }
        let logURL = RunShelfPaths.schedulerLogURL()
        return SchedulerEngine(
            scheduledRun: { task, scheduledAt, runID in
                try SchedulerRunHost.launchAndWait(
                    task: task,
                    scheduledAt: scheduledAt,
                    runID: runID,
                    executableURL: executableURL,
                    stderrLogURL: logURL
                )
            },
            scheduledRunReportsFailures: true
        )
    }
}
