import Cocoa
import AVFoundation
import Speech

@main
class AppDelegate: NSObject, NSApplicationDelegate, SFSpeechRecognizerDelegate {
    
    // UI elements
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    
    // Speech recognition properties
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    // Event tap for function key
    private var eventTap: CFMachPort?
    
    // Recording state
    private var isRecording = false
    private var lastTranscription = ""
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request necessary permissions
        requestPermissions()
        
        // Setup menu bar icon
        setupStatusItem()
        
        // Setup global event monitoring for function key
        setupKeyboardEventTap()
    }
    
    private func requestPermissions() {
        // Request speech recognition authorization
        SFSpeechRecognizer.requestAuthorization { status in
            switch status {
            case .authorized:
                print("Speech recognition authorized")
            default:
                print("Speech recognition not authorized")
                DispatchQueue.main.async {
                    self.showPermissionAlert(message: "Speech recognition permission is required")
                }
            }
        }
        
        // Request microphone permission
        // Note: For macOS we don't use AVAudioSession for permission
        // The system will prompt for microphone access when we try to use it
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Speech to Text")
        }
        
        // Setup menu
        menu.addItem(NSMenuItem(title: "About Speech to Text", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    private func setupKeyboardEventTap() {
        // Create a mask for the events we're interested in
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        
        // Create the event tap
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                
                // Function key (fn) is typically keycode 63
                if keyCode == 0 {
                    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                    
                    if delegate.isRecording {
                        delegate.stopRecording()
                    } else {
                        delegate.startRecording()
                    }
                    
                    // Consume the event
                    return nil
                }
                
                
                // Pass through all other events
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("Failed to create event tap")
            return
        }
        
        self.eventTap = eventTap
        
        // Create a run loop source and add it to the current run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        
        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
    
    func startRecording() {
        // Check if we're already recording
        if isRecording {
            return
        }
        
        // Update status
        isRecording = true
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        }
        
        // Show notification
        let notification = NSUserNotification()
        notification.title = "Recording Started"
        notification.informativeText = "Speak now, press fn key again to stop"
        NSUserNotificationCenter.default.deliver(notification)
        
        // Create a new speech recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        // For macOS, we don't use AVAudioSession as it's an iOS API
        
        // Configure the microphone input
        let inputNode = audioEngine.inputNode
        recognitionRequest?.shouldReportPartialResults = true
        
        // Start recognition
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest!) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                self.lastTranscription = result.bestTranscription.formattedString
                print("Heard: \(self.lastTranscription)")
            }
            
            if error != nil {
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.isRecording = false
                
                if let button = self.statusItem.button {
                    button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Speech to Text")
                }
            }
        }
        
        // Configure the microphone
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        // Start the audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("Could not start audio engine: \(error.localizedDescription)")
            stopRecording()
        }
    }
    
    func stopRecording() {
        // Check if we're recording
        if !isRecording {
            return
        }
        
        // Update status
        isRecording = false
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Speech to Text")
        }
        
        // Stop the audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // End the recognition request
        recognitionRequest?.endAudio()
        
        // Extract the text and copy to clipboard
        if !lastTranscription.isEmpty {
            // Copy to clipboard
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(lastTranscription, forType: .string)
            
            // Show notification
            let notification = NSUserNotification()
            notification.title = "Transcription Complete"
            notification.informativeText = "Text copied to clipboard"
            NSUserNotificationCenter.default.deliver(notification)
            
            // Paste to active application
            pasteToActiveApplication(text: lastTranscription)
            
            // Reset last transcription
            lastTranscription = ""
        }
        
        // Clean up
        recognitionRequest = nil
        recognitionTask = nil
    }
    
    private func pasteToActiveApplication(text: String) {
        // Create a keyboard event source
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        
        // Simulate Cmd+V keyboard shortcut
        guard let pasteCommandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) else { return }
        guard let pasteCommandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        
        // Set command flag
        pasteCommandDown.flags = .maskCommand
        pasteCommandUp.flags = .maskCommand
        
        // Post events
        pasteCommandDown.post(tap: .cghidEventTap)
        pasteCommandUp.post(tap: .cghidEventTap)
    }
    
    private func showPermissionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        }
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Speech to Text"
        alert.informativeText = "Press the function (fn) key to start recording. Press it again to stop and paste the transcribed text."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
