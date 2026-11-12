import CoreVideo
import Foundation

/// The texture wrappers one pass reads and writes through, with the cache
/// that made them and the pool its picture came from, let go in that order
/// on the cache's own queue.
///
/// Core Video walks a cache's backings from whichever thread lets a wrapper
/// or the cache itself go, and a backing is handed back to its pool, which
/// has to still be there. Left to the deallocation of whatever closure held
/// them last, the wrappers went on a Metal completion thread, and the pool
/// before them where the pass's owner had already been let go.
final class PassTextures {
    private(set) var wrappers: [CVMetalTexture]
    private var cache: CVMetalTextureCache?
    private var pool: PixelBufferPool?

    init(_ wrappers: [CVMetalTexture], cache: CVMetalTextureCache, pool: PixelBufferPool?) {
        self.wrappers = wrappers
        self.cache = cache
        self.pool = pool
    }

    /// On the cache's queue, once the pass has landed. The flush gives back
    /// the pictures of the wrappers just let go, which is what lets the pool
    /// recycle them.
    func release() {
        wrappers.removeAll()
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        cache = nil
        pool = nil
    }
}
