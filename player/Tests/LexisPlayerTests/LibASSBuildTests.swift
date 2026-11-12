import CFFmpeg
import CLibass
import Foundation
import LexisTestSupport
import XCTest
@testable import LexisPlayer

final class LibASSBuildTests: XCTestCase {
    func testTheASSCodecIDMatchesTheOneAvcodecDeclares() {
        // shim.c hardcodes the value because avcodec spells it as an
        // enumerator. This is what catches an FFmpeg bump that renumbers.
        XCTAssertEqual(LexisCodecIDASS, UInt32(AV_CODEC_ID_ASS.rawValue))
    }

    func testTheVendoredLibassIsTheOneThisRepoPinned() {
        // 0x01704000 is 0.17.4. A mismatch means Vendor/ is stale, which is a
        // rebuilt-the-wrong-thing failure and not a code failure.
        XCTAssertEqual(ass_library_version(), 0x0170_4000)
    }

    /// On the shared queue like every other libass call in this process: the
    /// renderers other suites built free themselves on it asynchronously, and
    /// a `-DHB_NO_MT` build cannot have those frees overlap this render.
    func testTheCoreTextProviderAnswers() throws {
        try AssRenderer.sharedQueue.sync {
            let library = try XCTUnwrap(ass_library_init())
            defer { ass_library_done(library) }
            let renderer = try XCTUnwrap(ass_renderer_init(library))
            defer { ass_renderer_done(renderer) }
            ass_set_frame_size(renderer, 1920, 1080)
            ass_set_storage_size(renderer, 1920, 1080)
            ass_set_fonts(
                renderer, nil, "Helvetica",
                Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1
            )
            let track = try XCTUnwrap(ass_new_track(library))
            defer { ass_free_track(track) }
            assFixtureHeader.withCString { ass_process_codec_private(track, $0, Int32(strlen($0))) }
            let line = #"0,0,Default,,0,0,0,,Bonjour"#
            line.withCString { ass_process_chunk(track, $0, Int32(strlen($0)), 1000, 2000) }
            var change: Int32 = 0
            // Nothing renders without a font, so a non-empty list is the whole
            // proof that CoreText answered on this platform.
            XCTAssertNotNil(ass_render_frame(renderer, track, 1500, &change))
        }
    }
}
