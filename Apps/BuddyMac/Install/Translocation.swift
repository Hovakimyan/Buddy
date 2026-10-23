import Foundation

/// Finds where a translocated app really lives. macOS runs a quarantined app that was not moved by Finder from a
/// randomized read-only path (`.../AppTranslocation/<uuid>/d/Buddy.app`); the two Security functions behind this
/// are not in the public headers, so they are looked up at run time and a missing symbol just means "not translocated".
enum Translocation {
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    /// The original location of `url` when macOS runs it translocated, nil otherwise.
    static func originalLocation(of url: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let isTranslocated = unsafeBitCast(isSymbol, to: IsTranslocated.self)
        let originalPath = unsafeBitCast(originalSymbol, to: OriginalPath.self)
        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let original = originalPath(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return original as URL
    }
}
