import CoreMedia
import Foundation

/// What `AVDisplayCriteria(refreshRate:formatDescription:)` (AVFoundation,
/// tvOS 11.2+) needs. Built here, off the player package's own facts, so the
/// app layer that owns the window never re-derives the dynamic range from
/// the stream a second time: the format description already carries every
/// colour tag that initializer reads.
public struct DisplayCriteriaRequest {
    public let refreshRate: Float
    public let formatDescription: CMVideoFormatDescription
}

/// nil when the stream's own frame rate cannot be read: asking the display
/// for nothing is the correct request, not a guess.
///
/// The rate asked for is the rate pictures leave the pipeline at, not the
/// rate the container states: a bobbed 25i track is 50 pictures a second, and
/// a display running at 25 would show half of them.
///
/// A rate no display mode runs at, the average of a phone's variable rate
/// or a slow one, is asked for as the nearest rate a mode does run at,
/// doubled first while under 23: the display is never asked for a mode it
/// cannot make, and 15 pictures a second go up evenly at 30.
public func playerDisplayCriteria(
    for stream: MediaStream, formatDescription: CMVideoFormatDescription
) -> DisplayCriteriaRequest? {
    guard var frameRate = stream.outputFrameRate else { return nil }
    while frameRate < 23 { frameRate *= 2 }
    let modes = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48000.0 / 1001, 48, 50, 60000.0 / 1001, 60]
    let nearest = modes.min { abs(log($0 / frameRate)) < abs(log($1 / frameRate)) }!
    return DisplayCriteriaRequest(
        refreshRate: Float(frameRate > 61 ? frameRate : nearest), formatDescription: formatDescription
    )
}

/// What a display is asked for when the pictures leave as HDR10 whatever the
/// file is: ten bit BT.2020 PQ at the film's size.
func hdr10DisplayFormat(width: Int32, height: Int32) -> CMVideoFormatDescription? {
    let extensions = [
        kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
        kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
        kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020,
    ] as CFDictionary
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        width: width, height: height, extensions: extensions, formatDescriptionOut: &format)
    return status == noErr ? format : nil
}
