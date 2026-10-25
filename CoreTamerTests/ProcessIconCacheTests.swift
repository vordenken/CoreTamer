import AppKit
import Testing

@testable import CoreTamer

@MainActor
struct ProcessIconCacheTests {
    @Test func reusesAppIconForMainProcessAndHelpers() {
        var loadedPaths: [String] = []
        let cache = ProcessIconCache { path in
            loadedPaths.append(path)
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let main = cache.icon(for: "/Example.app/Contents/MacOS/Example")
        let helper = cache.icon(for: "/Example.app/Contents/Helpers/Helper")
        let repeated = cache.icon(for: "/Example.app/Contents/MacOS/Example")
        #expect(main === helper)
        #expect(main === repeated)
        #expect(loadedPaths == ["/Example.app"])
    }

    @Test func keepsDifferentExecutablesSeparate() {
        var loadedPaths: [String] = []
        let cache = ProcessIconCache { path in
            loadedPaths.append(path)
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let first = cache.icon(for: "/usr/bin/yes")
        let second = cache.icon(for: "/usr/bin/true")
        #expect(first !== second)
        #expect(cache.icon(for: "/usr/bin/yes") === first)
        #expect(loadedPaths == ["/usr/bin/yes", "/usr/bin/true"])
    }
}
