import AppKit
import Foundation

// Disable stdout/stderr buffering for testing logs
setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Runs the application event loop
app.run()
