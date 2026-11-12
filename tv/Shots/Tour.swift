import XCTest

/// A scripted walk through the app for a design review: reads its steps from
/// `script.txt` in the host directory `TEST_RUNNER_TOUR_DIR` names, one
/// command per line, and writes a screenshot there per `shot`. Every press is
/// logged to `focus.log` with what holds the focus after it, so a press that
/// moves nothing or lands somewhere unexpected reads straight off the log.
final class Tour: XCTestCase {
    func testTour() throws {
        guard let dir = ProcessInfo.processInfo.environment["TOUR_DIR"] else { throw XCTSkip("pass TEST_RUNNER_TOUR_DIR") }
        let script = try String(contentsOfFile: dir + "/script.txt", encoding: .utf8)
        let app = XCUIApplication()
        app.launch()
        let remote = XCUIRemote.shared
        var log = ""
        for line in script.split(separator: "\n") {
            let words = line.split(separator: " ").map(String.init)
            guard let command = words.first, !command.hasPrefix("#") else { continue }
            let argument = words.dropFirst().joined(separator: " ")
            switch command {
            case "up": remote.press(.up)
            case "down": remote.press(.down)
            case "left": remote.press(.left)
            case "right": remote.press(.right)
            case "select": remote.press(.select)
            case "hold": remote.press(.select, forDuration: 1.5)
            case "menu": remote.press(.menu)
            case "play": remote.press(.playPause)
            case "wait": Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "shot":
                let png = app.screenshot().pngRepresentation
                try png.write(to: URL(fileURLWithPath: dir + "/" + argument + ".png"))
            case "mark": log += "== \(argument)\n"
            default: break
            }
            guard command != "wait", command != "shot", command != "mark" else { continue }
            Thread.sleep(forTimeInterval: 0.9)
            let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
            let what: String
            if focused.exists {
                let f = focused.frame
                let name = focused.label.isEmpty ? focused.identifier : focused.label
                what = "\(focused.elementType.rawValue) \"\(name.prefix(60))\" @\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
            } else {
                what = "NOTHING FOCUSED"
            }
            log += "\(command)\t\(what)\n"
        }
        try log.write(toFile: dir + "/focus.log", atomically: true, encoding: .utf8)
    }
}
