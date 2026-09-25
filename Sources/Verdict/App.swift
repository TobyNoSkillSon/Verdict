import AppKit
@main struct VerdictApp {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-table"), args.count > index + 1 {
            let delegate = TableRenderDelegate(directory: URL(fileURLWithPath: args[index + 1], isDirectory: true))
            app.delegate = delegate
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
