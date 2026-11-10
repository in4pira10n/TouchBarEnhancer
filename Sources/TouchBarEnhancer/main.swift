import AppKit
import TouchBarBridge

TBPrepareForImmediateTransitions()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
