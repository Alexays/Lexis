import CFFmpeg
import XCTest
@testable import LexisPlayer

final class FFmpegBuildTests: XCTestCase {
    func testLinksThePinnedRelease() {
        XCTAssertEqual(FFmpegBuild.version, "7.1.5")
        XCTAssertEqual(FFmpegBuild.avformatMajor, 61)
    }

    func testDav1dIsTheAV1Decoder() throws {
        let byName = avcodec_find_decoder_by_name("libdav1d")
        XCTAssertNotNil(byName, "libdav1d must be vendored and registered")
        let preferred = try XCTUnwrap(avcodec_find_decoder(AV_CODEC_ID_AV1))
        XCTAssertEqual(String(cString: preferred.pointee.name), "libdav1d")
    }
}
