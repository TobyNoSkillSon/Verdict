// Build-time probe. Not shipped: verify the running helper owns no windows.
import CoreGraphics
import Foundation

@main enum CheckHelperUI {
    static func main() {
        guard CommandLine.arguments.count == 2,
              let pid = Int32(CommandLine.arguments[1]),
              let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { fputs("Cannot enumerate windows\n", stderr); exit(2) }
        let own = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        guard own.isEmpty else { fputs("verdict-helper created \(own.count) window(s)\n", stderr); exit(1) }
    }
}
