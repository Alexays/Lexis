import Foundation
import XCTest
@testable import LexisPlayer

/// The kernels compiled at run time, compiled here by the Apple TV's own Metal
/// compiler: the Mac's, which every other test runs them through, lets through
/// source the Apple TV refuses, and a refused library leaves every mapped path
/// to fall back without a word.
final class ShaderCompileTests: XCTestCase {
    func testTheKernelsCompileForTheAppleTV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, source) in [("tonemap", ToneMapper.shader), ("enhance", PictureEnhancer.shader)] {
            let file = directory.appendingPathComponent("\(name).metal")
            try source.write(to: file, atomically: true, encoding: .utf8)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compile.arguments = ["-sdk", "appletvos", "metal", "-c", file.path, "-o",
                                 directory.appendingPathComponent("\(name).air").path]
            let errors = Pipe()
            compile.standardError = errors
            try compile.run()
            compile.waitUntilExit()
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("missing Metal Toolchain") {
                throw XCTSkip("xcodebuild -downloadComponent MetalToolchain installs the compiler this needs")
            }
            XCTAssertEqual(compile.terminationStatus, 0, "\(name): \(message)")
        }
    }
}
