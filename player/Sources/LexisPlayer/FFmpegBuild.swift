import CFFmpeg

public enum FFmpegBuild {
    /// The linked FFmpeg release, e.g. "7.1.5".
    public static var version: String {
        String(cString: av_version_info())
    }

    public static var avformatMajor: UInt32 {
        avformat_version() >> 16
    }
}
