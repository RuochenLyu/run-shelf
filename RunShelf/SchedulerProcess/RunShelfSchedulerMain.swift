import Foundation

@main
struct RunShelfSchedulerMain {
    static func main() {
        let engine = SchedulerEngine()

        engine.tick()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            engine.tick()
        }

        RunLoop.main.run()
    }
}
