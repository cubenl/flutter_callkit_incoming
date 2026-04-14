import Flutter
import UIKit
import CallKit
import AVFoundation
import UserNotifications

@available(iOS 10.0, *)
public class SwiftFlutterCallkitIncomingPlugin: NSObject, FlutterPlugin, CXProviderDelegate {
    
    static let ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP = "com.hiennv.flutter_callkit_incoming.DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP"
    
    static let ACTION_CALL_INCOMING = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_INCOMING"
    static let ACTION_CALL_START = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_START"
    static let ACTION_CALL_ACCEPT = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT"
    static let ACTION_CALL_DECLINE = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE"
    static let ACTION_CALL_ENDED = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED"
    static let ACTION_CALL_TIMEOUT = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TIMEOUT"
    static let ACTION_CALL_CALLBACK = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CALLBACK"
    static let ACTION_CALL_CUSTOM = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CUSTOM"
    static let ACTION_CALL_CONNECTED = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_CONNECTED"
    
    static let ACTION_CALL_TOGGLE_HOLD = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_HOLD"
    static let ACTION_CALL_TOGGLE_MUTE = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_MUTE"
    static let ACTION_CALL_TOGGLE_DMTF = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_DMTF"
    static let ACTION_CALL_TOGGLE_GROUP = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_GROUP"
    static let ACTION_CALL_TOGGLE_AUDIO_SESSION = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_AUDIO_SESSION"
    static let ACTION_CALL_TOGGLE_SPEAKER = "com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_SPEAKER"

    @objc public private(set) static var sharedInstance: SwiftFlutterCallkitIncomingPlugin!

    /// Optional log forwarder. When set by the host app, plugin log lines
    /// are delivered here (with source file:line) so they can be routed into
    /// a unified app log (e.g. the Flutter session log). The plugin still
    /// calls `print()` so the Xcode console keeps working unchanged.
    ///
    /// Signature: (message, sourceFile:line) — sourceFile:line points back
    /// to the original `pluginLog(...)` call site inside the plugin.
    @objc public static var logCallback: ((String, String) -> Void)?

    /// Internal helper — use instead of `print()` when adding new logs.
    /// Forwards to logCallback (with #file:#line) if set, and always
    /// prints to stdout for Xcode console.
    fileprivate static func pluginLog(_ message: String,
                                      file: String = #file,
                                      line: Int = #line) {
        let filename = (file as NSString).lastPathComponent
        let source = "\(filename):\(line)"
        logCallback?(message, source)
        print(message)
    }
    
    private var streamHandlers: WeakArray<EventCallbackHandler> = WeakArray([])
    
    private var callManager: CallManager
    
    private var sharedProvider: CXProvider? = nil
    
    private var outgoingCall : Call?
    private var answerCall : Call?
    
    private var data: Data?
    private var isFromPushKit: Bool = false
    private var silenceEvents: Bool = false
    private let devicePushTokenVoIP = "DevicePushTokenVoIP"
    private var lastKnownSpeakerState: Bool? = nil
    /// When we last called overrideOutputAudioPort(.speaker). Used by
    /// handleAudioRouteChange to only auto-reapply within a short window
    /// after our own speaker set — after the window, route changes are
    /// assumed intentional (CallKit toggle, user action).
    private var lastSpeakerOnTime: Date? = nil

    /// Timestamp of the most recent AVAudioSessionRouteChangeNotification.
    /// Used by `restartAudioSession` to wait for iOS to settle after a
    /// post-toggle route reconfiguration storm before returning. Without
    /// this wait, WebRTC's ADM startRecording can race with iOS still
    /// reconfiguring routes, leaving playout (remote audio) wedged.
    private var lastRouteChangeTime: Date? = nil

    
    private func sendEvent(_ event: String, _ body: [String : Any?]?) {
        if silenceEvents {
            print(event, " silenced")
            return
        } else {
            streamHandlers.reap().forEach { handler in
                handler?.send(event, body ?? [:])
            }
        }
        
    }
    
    func startAudioRouteObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        // Seed the initial state only on the first call. During call-switch,
        // didDeactivate returns early (calls on hold) so stopAudioRouteObserver
        // is NOT called — lastKnownSpeakerState is preserved.
        if lastKnownSpeakerState == nil {
            lastKnownSpeakerState = AVAudioSession.sharedInstance().currentRoute.outputs
                .contains { $0.portType == .builtInSpeaker }
        }

        // If speaker was on before this audio session cycle (call-switch, unhold),
        // refresh the protection window so spurious speaker-off events from the
        // session reconfiguration are silently re-applied instead of sent to Flutter.
        if lastSpeakerOnTime != nil {
            lastSpeakerOnTime = Date()
        }
    }

    func stopAudioRouteObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        lastKnownSpeakerState = nil
        lastSpeakerOnTime = nil
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        let session = AVAudioSession.sharedInstance()
        let isSpeaker = session.currentRoute.outputs
            .contains { $0.portType == .builtInSpeaker }
        let reasonRaw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        // Track every route change so restartAudioSession can wait for
        // iOS to stop firing them before continuing the ADM restart.
        lastRouteChangeTime = Date()
        Self.pluginLog("[CallKit] handleAudioRouteChange: isSpeaker=\(isSpeaker), reason=\(reasonRaw), outputs=\(outputs)")

        // If speaker was cleared within 2s of us setting it, silently re-apply.
        // This catches WebRTC's internal setCategory calls (ADM restart,
        // interruption notification response) that clear the transient override.
        // After 2s the audio session is stable — any route change is intentional
        // (CallKit toggle, user action) and should not be fought.
        if !isSpeaker, let lastSet = lastSpeakerOnTime,
           Date().timeIntervalSince(lastSet) < 2.0 {
            Self.pluginLog("[CallKit] handleAudioRouteChange: re-applying speaker (within 2s window)")
            try? session.overrideOutputAudioPort(.speaker)
            return
        }

        // Only fire when the state actually changed to prevent ping-pong.
        guard isSpeaker != lastKnownSpeakerState else { return }
        lastKnownSpeakerState = isSpeaker

        // Track speaker-on from any source (app, CallKit, system) so the
        // protection window in startAudioRouteObserver works for call-switch.
        if isSpeaker {
            lastSpeakerOnTime = Date()
        } else {
            lastSpeakerOnTime = nil
        }

        self.sendEvent(
            SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_SPEAKER,
            ["isSpeaker": isSpeaker]
        )
    }

    /// Polls `lastRouteChangeTime` until iOS has gone `quietPeriodMs`
    /// without firing AVAudioSessionRouteChangeNotification, or the cap
    /// `maxWaitMs` (since `startedAt`) is reached. Used after
    /// restartAudioSession's mode toggle to let iOS finish its post-toggle
    /// route-reconfiguration storm before the Dart-side ADM restart runs.
    ///
    /// The poll interval is 50ms — fast enough to add minimal latency,
    /// slow enough to not burn CPU.
    private func waitForRouteQuiescence(
        startedAt: Date,
        quietPeriodMs: Int,
        maxWaitMs: Int,
        completion: @escaping () -> Void
    ) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        if elapsedMs >= maxWaitMs {
            Self.pluginLog("[CallKit] restartAudioSession: max wait (\(maxWaitMs)ms) reached, proceeding with possibly-still-firing storm")
            completion()
            return
        }
        let timeSinceLastChangeMs: Int
        if let last = lastRouteChangeTime {
            timeSinceLastChangeMs = Int(Date().timeIntervalSince(last) * 1000)
        } else {
            // No route changes seen yet — count the elapsed time as quiet.
            timeSinceLastChangeMs = elapsedMs
        }
        if timeSinceLastChangeMs >= quietPeriodMs {
            Self.pluginLog("[CallKit] restartAudioSession: route settled after \(elapsedMs)ms (quiet for \(timeSinceLastChangeMs)ms)")
            completion()
            return
        }
        // Still seeing route changes — poll again.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.waitForRouteQuiescence(
                startedAt: startedAt,
                quietPeriodMs: quietPeriodMs,
                maxWaitMs: maxWaitMs,
                completion: completion
            )
        }
    }

    /// Re-applies speaker after didActivate during call-switch.
    /// Uses a short delay to let the audio session settle after activation.
    /// The route change observer handles subsequent WebRTC reconfigures.
    private func reapplySpeakerIfNeeded() {
        guard lastKnownSpeakerState == true || lastSpeakerOnTime != nil else { return }
        // Re-apply at 0.5s and 1.0s after didActivate. The first catches fast
        // WebRTC reconfigures, the second ensures CallKit's native UI picks up
        // the speaker state (CallKit may cache the intermediate earpiece state
        // from the didDeactivate/didActivate cycle and needs a fresh route
        // change to refresh its speaker button).
        for delay in [0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.lastSpeakerOnTime != nil else { return }
                self?.lastSpeakerOnTime = Date()
                try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            }
        }
    }

    @objc public func sendEventCustom(_ event: String, body: NSDictionary?) {
        streamHandlers.reap().forEach { handler in
            handler?.send(event, body ?? [:])
        }
    }
    
    public static func sharePluginWithRegister(with registrar: FlutterPluginRegistrar) {
        if(sharedInstance == nil){
            sharedInstance = SwiftFlutterCallkitIncomingPlugin(messenger: registrar.messenger())
        }
        sharedInstance.shareHandlers(with: registrar)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        sharePluginWithRegister(with: registrar)
    }
    
    private static func createMethodChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        return FlutterMethodChannel(name: "flutter_callkit_incoming", binaryMessenger: messenger)
    }
    
    private static func createEventChannel(messenger: FlutterBinaryMessenger) -> FlutterEventChannel {
        return FlutterEventChannel(name: "flutter_callkit_incoming_events", binaryMessenger: messenger)
    }
    
    public init(messenger: FlutterBinaryMessenger) {
        callManager = CallManager()
    }
    
    private func shareHandlers(with registrar: FlutterPluginRegistrar) {
        registrar.addMethodCallDelegate(self, channel: Self.createMethodChannel(messenger: registrar.messenger()))
        let eventsHandler = EventCallbackHandler()
        self.streamHandlers.append(eventsHandler)
        Self.createEventChannel(messenger: registrar.messenger()).setStreamHandler(eventsHandler)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "showCallkitIncoming":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.data = Data(args: getArgs)
                showCallkitIncoming(self.data!, fromPushKit: false)
            }
            result(true)
            break
        case "showMissCallNotification":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.data = Data(args: getArgs)
                self.showMissedCallNotification(data!)
            }
            result(true)
            break
        case "startCall":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.data = Data(args: getArgs)
                self.startCall(self.data!, fromPushKit: false)
            }
            result(true)
            break
        case "endCall":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if(self.isFromPushKit){
                self.endCall(self.data!)
            }else{
                if let getArgs = args as? [String: Any] {
                    self.data = Data(args: getArgs)
                    self.endCall(self.data!)
                }
            }
            result(true)
            break
        case "muteCall":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String,
                  let isMuted = args["isMuted"] as? Bool else {
                result(true)
                return
            }
            
            self.muteCall(callId, isMuted: isMuted)
            result(true)
            break
        case "isMuted":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String else{
                result(false)
                return
            }
            guard let callUUID = UUID(uuidString: callId),
                  let call = self.callManager.callWithUUID(uuid: callUUID) else {
                result(false)
                return
            }
            result(call.isMuted)
            break
        case "holdCall":
            guard let args = call.arguments as? [String: Any] ,
                  let callId = args["id"] as? String,
                  let onHold = args["isOnHold"] as? Bool else {
                result(true)
                return
            }
            self.holdCall(callId, onHold: onHold)
            result(true)
            break
        case "callConnected":
            guard call.arguments != nil else {
                result(true)
                return
            }
            if let data = self.data {
                self.connectedCall(data)
            }
            result(true)
            break
        case "activeCalls":
            result(self.callManager.activeCalls())
            break;
        case "endAllCalls":
            self.callManager.endCallAlls()
            result(true)
            break
        case "getDevicePushTokenVoIP":
            result(self.getDevicePushTokenVoIP())
            break;
        case "silenceEvents":
            guard let silence = call.arguments as? Bool else {
                result(true)
                return
            }

            self.silenceEvents = silence
            result(true)
            break;
        case "setSpeaker":
            guard let enabled = call.arguments as? Bool else {
                result(false)
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                if enabled { lastSpeakerOnTime = Date() } else { lastSpeakerOnTime = nil }
                try session.overrideOutputAudioPort(enabled ? .speaker : .none)
                result(true)
            } catch {
                Self.pluginLog("[CallKit] setSpeaker failed: \(error)")
                result(false)
            }
            break;
        case "reapplySpeaker":
            // Sets the speaker state and starts the 2s protection window.
            // The route change observer auto-corrects within the window.
            guard let enabled = call.arguments as? Bool else {
                result(false)
                return
            }
            do {
                let session = AVAudioSession.sharedInstance()
                if enabled { lastSpeakerOnTime = Date() } else { lastSpeakerOnTime = nil }
                try session.overrideOutputAudioPort(enabled ? .speaker : .none)
                result(true)
            } catch {
                Self.pluginLog("[CallKit] reapplySpeaker failed: \(error)")
                result(false)
            }
            break;
        case "restartAudioSession":
            // Force WebRTC's VoiceProcessingIO audio unit to be fully
            // destroyed and rebuilt via AVAudioSession.Mode change, then
            // wait for iOS to finish reconfiguring routes before returning.
            //
            // Why setMode? Different modes map to different native audio units:
            //   .voiceChat / .videoChat → VoiceProcessingIO (with AEC)
            //   .default / .measurement → RemoteIO (no AEC)
            // Switching mode forces iOS to tear down + rebuild the audio
            // unit. This is a deeper rebuild than route-change tricks like
            // overrideOutputAudioPort or setPreferredInput.
            //
            // Why wait for quiescence? After the mode toggle iOS fires a
            // burst of routeConfigurationChange notifications (often 6+).
            // If WebRTC's ADM startRecording runs DURING this burst, the
            // ADM ends up bound to a stale session config — startRecording
            // returns success but playout (remote audio) is silently dead.
            // We poll the lastRouteChangeTime timestamp (updated by
            // handleAudioRouteChange) and wait for `quietPeriodMs` of
            // silence, capped at `maxWaitMs`, before returning success.
            //
            // Why not setActive(false)? iOS blocks it with error -12988
            // during an active CallKit session.
            //
            // Why not overrideOutputAudioPort toggle? Briefly activates
            // the speaker (visible/audible to user).
            let session = AVAudioSession.sharedInstance()
            let args = call.arguments as? [String: Any]
            let settleMs = args?["settleMs"] as? Int ?? 200
            let quietPeriodMs = args?["quietPeriodMs"] as? Int ?? 250
            let maxWaitMs = args?["maxWaitMs"] as? Int ?? 1500
            let originalMode = session.mode
            let currentRoute = session.currentRoute.outputs.first?.portType.rawValue ?? "unknown"
            Self.pluginLog("[CallKit] restartAudioSession: start, mode=\(originalMode.rawValue), route=\(currentRoute), quietMs=\(quietPeriodMs), maxMs=\(maxWaitMs)")

            // Reset route-change timestamp so the quiescence detector
            // doesn't see stale events from before this restart.
            lastRouteChangeTime = nil

            // Pick a toggle mode that differs from the current one.
            // Avoid .measurement (disables AEC, can cause echo).
            let toggleMode: AVAudioSession.Mode = (originalMode == .voiceChat || originalMode == .videoChat)
                ? .default
                : .voiceChat

            do {
                try session.setMode(toggleMode)
                Self.pluginLog("[CallKit] restartAudioSession: toggled to \(toggleMode.rawValue)")
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(settleMs)) { [weak self] in
                    guard let self = self else { result(false); return }
                    do {
                        try AVAudioSession.sharedInstance().setMode(originalMode)
                        Self.pluginLog("[CallKit] restartAudioSession: restored to \(originalMode.rawValue)")
                        // Now wait for iOS to stop firing route changes
                        // before signalling success. The Dart-side ADM
                        // restart sequence will then run against a settled
                        // audio session.
                        self.waitForRouteQuiescence(
                            startedAt: Date(),
                            quietPeriodMs: quietPeriodMs,
                            maxWaitMs: maxWaitMs,
                            completion: { result(true) }
                        )
                    } catch {
                        Self.pluginLog("[CallKit] restartAudioSession mode restore failed: \(error)")
                        result(FlutterError(code: "MODE_RESTORE_FAILED",
                                            message: error.localizedDescription,
                                            details: nil))
                    }
                }
            } catch {
                Self.pluginLog("[CallKit] restartAudioSession mode toggle failed: \(error)")
                result(FlutterError(code: "MODE_TOGGLE_FAILED",
                                    message: error.localizedDescription,
                                    details: nil))
            }
            break;
        case "deactivateAudioSession":
            // Explicitly deactivate the AVAudioSession after a call ends.
            //
            // This is the ROOT CAUSE fix for the cumulative playout-dead bug:
            // between rapid calls, the iOS audio session stays "active" with
            // stale VoiceProcessingIO audio unit bindings. Each new call
            // inherits that stale state, and after N calls the playout
            // pipeline silently wedges.
            //
            // By deactivating between calls (when CallKit no longer owns the
            // session), we force CoreAudio to fully release the audio unit.
            // The next call's didActivate starts with a clean slate.
            //
            // MUST only be called AFTER CallKit has ended the call (otherwise
            // setActive(false) fails with -12988). The Dart side calls this
            // from clearCall() after removeAllStreams + CallKit removeCall.
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                Self.pluginLog("[CallKit] deactivateAudioSession: success")
                result(true)
            } catch {
                // Expected if another call is still active (multi-call) or
                // if CallKit hasn't fully released yet. Not fatal — the next
                // call will just inherit the existing session state.
                Self.pluginLog("[CallKit] deactivateAudioSession: failed (expected if call still active): \(error)")
                result(false)
            }
            break;
        case "requestNotificationPermission":
            guard let args = call.arguments else {
                result(true)
                return
            }
            if let getArgs = args as? [String: Any] {
                self.requestNotificationPermission(getArgs)
            }
            result(true)
            break
         case "requestFullIntentPermission": 
            result(true)
            break
         case "canUseFullScreenIntent": 
            result(true)
            break
        case "hideCallkitIncoming":
            result(true)
            break
        case "endNativeSubsystemOnly":
            result(true)
            break
        case "setAudioRoute":
            result(true)
            break
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    @objc public func setDevicePushTokenVoIP(_ deviceToken: String) {
        UserDefaults.standard.set(deviceToken, forKey: devicePushTokenVoIP)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP, ["deviceTokenVoIP":deviceToken])
    }
    
    @objc public func getDevicePushTokenVoIP() -> String {
        return UserDefaults.standard.string(forKey: devicePushTokenVoIP) ?? ""
    }
    
    @objc public func getAcceptedCall() -> Data? {
        NSLog("Call data ids \(String(describing: data?.uuid)) \(String(describing: answerCall?.uuid.uuidString))")
        if data?.uuid.lowercased() == answerCall?.uuid.uuidString.lowercased() {
            return data
        }
        return nil
    }
    
    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool) {
        self.isFromPushKit = fromPushKit
        if(fromPushKit){
            self.data = data
        }
        
        if(data.isShowMissedCallNotification){
            CallkitNotificationManager.shared.addNotificationCategory(data.missedNotificationCallbackText)
        }
        
        var handle: CXHandle?
        handle = CXHandle(type: self.getHandleType(data.handleType), value: data.getEncryptHandle())
        
        let callUpdate = CXCallUpdate()

        callUpdate.remoteHandle = handle
        callUpdate.supportsDTMF = data.supportsDTMF
        callUpdate.supportsHolding = data.supportsHolding
        callUpdate.supportsGrouping = data.supportsGrouping
        callUpdate.supportsUngrouping = data.supportsUngrouping
        callUpdate.hasVideo = data.type > 0 ? true : false
        callUpdate.localizedCallerName = data.nameCaller
        
        initCallkitProvider(data)
        
        let uuid = UUID(uuidString: data.uuid)
        
        self.configureAudioSession()
        self.sharedProvider?.reportNewIncomingCall(with: uuid!, update: callUpdate) { error in
            if(error == nil) {
                self.configureAudioSession()
                let call = Call(uuid: uuid!, data: data)
                call.handle = data.handle
                self.callManager.addCall(call)
                self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_INCOMING, data.toJSON())
                self.endCallNotExist(data)
            }
        }
    }
    
    @objc public func showCallkitIncoming(_ data: Data, fromPushKit: Bool, completion: @escaping () -> Void) {
        self.isFromPushKit = fromPushKit
        if(fromPushKit){
            self.data = data
        }
        
        if(data.isShowMissedCallNotification){
            CallkitNotificationManager.shared.addNotificationCategory(data.missedNotificationCallbackText)
        }
        
        var handle: CXHandle?
        handle = CXHandle(type: self.getHandleType(data.handleType), value: data.getEncryptHandle())
        
        let callUpdate = CXCallUpdate()
        callUpdate.remoteHandle = handle
        callUpdate.supportsDTMF = data.supportsDTMF
        callUpdate.supportsHolding = data.supportsHolding
        callUpdate.supportsGrouping = data.supportsGrouping
        callUpdate.supportsUngrouping = data.supportsUngrouping
        callUpdate.hasVideo = data.type > 0 ? true : false
        callUpdate.localizedCallerName = data.nameCaller
        
        initCallkitProvider(data)
        
        let uuid = UUID(uuidString: data.uuid)
        
        self.sharedProvider?.reportNewIncomingCall(with: uuid!, update: callUpdate) { error in
            if(error == nil) {
                self.configureAudioSession()
                let call = Call(uuid: uuid!, data: data)
                call.handle = data.handle
                self.callManager.addCall(call)
                self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_INCOMING, data.toJSON())
                self.endCallNotExist(data)
            }
            completion()
        }
    }
    
    
    @objc public func startCall(_ data: Data, fromPushKit: Bool) {
        self.isFromPushKit = fromPushKit
        if(fromPushKit){
            self.data = data
        }
        initCallkitProvider(data)
        self.callManager.startCall(data)
    }
    
    @objc public func muteCall(_ callId: String, isMuted: Bool) {
        guard let callId = UUID(uuidString: callId),
              let call = self.callManager.callWithUUID(uuid: callId) else {
            return
        }
        if call.isMuted == isMuted {
            self.sendMuteEvent(callId.uuidString, isMuted)
        } else {
            self.callManager.muteCall(call: call, isMuted: isMuted)
        }
    }
    
    @objc public func holdCall(_ callId: String, onHold: Bool) {
        guard let callId = UUID(uuidString: callId),
              let call = self.callManager.callWithUUID(uuid: callId) else {
            return
        }
        if call.isOnHold == onHold {
            self.sendMuteEvent(callId.uuidString,  onHold)
        } else {
            self.callManager.holdCall(call: call, onHold: onHold)
        }
    }
    
    @objc public func endCall(_ data: Data) {
        var call: Call? = nil
        if(self.isFromPushKit){
            call = Call(uuid: UUID(uuidString: self.data!.uuid)!, data: data)
            self.isFromPushKit = false
            self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, data.toJSON())
        }else {
            call = Call(uuid: UUID(uuidString: data.uuid)!, data: data)
        }
        self.callManager.endCall(call: call!)
    }
    
    @objc public func connectedCall(_ data: Data) {
        var call: Call? = nil
        if(self.isFromPushKit){
            call = Call(uuid: UUID(uuidString: self.data!.uuid)!, data: data)
            self.isFromPushKit = false
        }else {
            call = Call(uuid: UUID(uuidString: data.uuid)!, data: data)
        }
        self.callManager.connectedCall(call: call!)
    }
    
    @objc public func activeCalls() -> [[String: Any]] {
        return self.callManager.activeCalls()
    }
    
    @objc public func endAllCalls() {
        self.isFromPushKit = false
        self.callManager.endCallAlls()
    }
    
    public func saveEndCall(_ uuid: String, _ reason: Int) {
        switch reason {
        case 1:
            self.sharedProvider?.reportCall(with: UUID(uuidString: uuid)!, endedAt: Date(), reason: CXCallEndedReason.failed)
            break
        case 2, 6:
            self.sharedProvider?.reportCall(with: UUID(uuidString: uuid)!, endedAt: Date(), reason: CXCallEndedReason.remoteEnded)
            break
        case 3:
            self.sharedProvider?.reportCall(with: UUID(uuidString: uuid)!, endedAt: Date(), reason: CXCallEndedReason.unanswered)
            break
        case 4:
            self.sharedProvider?.reportCall(with: UUID(uuidString: uuid)!, endedAt: Date(), reason: CXCallEndedReason.answeredElsewhere)
            break
        case 5:
            self.sharedProvider?.reportCall(with: UUID(uuidString: uuid)!, endedAt: Date(), reason: CXCallEndedReason.declinedElsewhere)
            break
        default:
            break
        }
    }
    
    
    func endCallNotExist(_ data: Data) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(data.duration)) {
            let call = self.callManager.callWithUUID(uuid: UUID(uuidString: data.uuid)!)
            if (call != nil && self.answerCall == nil && self.outgoingCall == nil) {
                self.callEndTimeout(data)
            }
        }
    }
    
    
    
    func callEndTimeout(_ data: Data) {
        self.saveEndCall(data.uuid, 3)
        guard let call = self.callManager.callWithUUID(uuid: UUID(uuidString: data.uuid)!) else {
            return
        }
        self.showMissedCallNotification(data)
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TIMEOUT, data.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onTimeOut(call)
        }
    }
    
    func getHandleType(_ handleType: String?) -> CXHandle.HandleType {
        var typeDefault = CXHandle.HandleType.generic
        switch handleType {
        case "number":
            typeDefault = CXHandle.HandleType.phoneNumber
            break
        case "email":
            typeDefault = CXHandle.HandleType.emailAddress
        default:
            typeDefault = CXHandle.HandleType.generic
        }
        return typeDefault
    }
    
    func initCallkitProvider(_ data: Data) {
        if(self.sharedProvider == nil){
            self.sharedProvider = CXProvider(configuration: createConfiguration(data))
            self.sharedProvider?.setDelegate(self, queue: nil)
        }
        self.callManager.setSharedProvider(self.sharedProvider!)
    }
    
    func createConfiguration(_ data: Data) -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration(localizedName: data.appName)
        configuration.supportsVideo = data.supportsVideo
        configuration.maximumCallGroups = data.maximumCallGroups
        configuration.maximumCallsPerCallGroup = data.maximumCallsPerCallGroup
        
        configuration.supportedHandleTypes = [
            CXHandle.HandleType.generic,
            CXHandle.HandleType.emailAddress,
            CXHandle.HandleType.phoneNumber
        ]
        if #available(iOS 11.0, *) {
            configuration.includesCallsInRecents = data.includesCallsInRecents
        }
        if !data.iconName.isEmpty {
            if let image = UIImage(named: data.iconName) {
                configuration.iconTemplateImageData = image.pngData()
            } else {
                print("Unable to load icon \(data.iconName).");
            }
        }
        if !data.ringtonePath.isEmpty || data.ringtonePath != "system_ringtone_default"  {
            configuration.ringtoneSound = data.ringtonePath
        }
        return configuration
    }
    
    func sendDefaultAudioInterruptionNotificationToStartAudioResource(){
        var userInfo : [AnyHashable : Any] = [:]
        let intrepEndeRaw = AVAudioSession.InterruptionType.ended.rawValue
        userInfo[AVAudioSessionInterruptionTypeKey] = intrepEndeRaw
        userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: self, userInfo: userInfo)
    }
    
    func configureAudioSession(){
        if data?.configureAudioSession != false {
            let session = AVAudioSession.sharedInstance()
            do{
                try session.setCategory(AVAudioSession.Category.playAndRecord, options: [
                    .allowBluetoothA2DP,
                    .duckOthers,
                    .allowBluetooth,
                ])

                let mode = self.getAudioSessionMode(data?.audioSessionMode)
                try session.setMode(mode)
                try session.setActive(data?.audioSessionActive ?? true)
                try session.setPreferredSampleRate(data?.audioSessionPreferredSampleRate ?? 44100.0)
                try session.setPreferredIOBufferDuration(data?.audioSessionPreferredIOBufferDuration ?? 0.005)
                Self.pluginLog("[CallKit] configureAudioSession: category=playAndRecord, mode=\(mode.rawValue)")
            }catch{
                Self.pluginLog("[CallKit] configureAudioSession failed: \(error)")
            }
        }
    }
    
    func getAudioSessionMode(_ audioSessionMode: String?) -> AVAudioSession.Mode {
        var mode = AVAudioSession.Mode.default
        switch audioSessionMode {
        case "gameChat":
            mode = AVAudioSession.Mode.gameChat
            break
        case "measurement":
            mode = AVAudioSession.Mode.measurement
            break
        case "moviePlayback":
            mode = AVAudioSession.Mode.moviePlayback
            break
        case "spokenAudio":
            mode = AVAudioSession.Mode.spokenAudio
            break
        case "videoChat":
            mode = AVAudioSession.Mode.videoChat
            break
        case "videoRecording":
            mode = AVAudioSession.Mode.videoRecording
            break
        case "voiceChat":
            mode = AVAudioSession.Mode.voiceChat
            break
        case "voicePrompt":
            if #available(iOS 12.0, *) {
                mode = AVAudioSession.Mode.voicePrompt
            } else {
                // Fallback on earlier versions
            }
            break
        default:
            mode = AVAudioSession.Mode.default
        }
        return mode
    }
    
    public func providerDidReset(_ provider: CXProvider) {
        for call in self.callManager.calls {
            call.endCall()
        }
        self.callManager.removeAllCalls()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let call = Call(uuid: action.callUUID, data: self.data!, isOutGoing: true)
        call.handle = action.handle.value
        configureAudioSession()
        call.hasStartedConnectDidChange = { [weak self] in
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, startedConnectingAt: call.connectData)
        }
        call.hasConnectDidChange = { [weak self] in
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, connectedAt: call.connectedData)
        }
        self.outgoingCall = call;
        self.callManager.addCall(call)
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_START, self.data?.toJSON())
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else{
            action.fail()
            return
        }
        self.configureAudioSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1200)) {
            self.configureAudioSession()
        }


        call.hasConnectDidChange = { [weak self] in
            self?.sharedProvider?.reportOutgoingCall(with: call.uuid, connectedAt: call.connectedData)
        }
        self.data?.isAccepted = true
        self.answerCall = call
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ACCEPT, self.data?.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onAccept(call, action)
        }else {
            action.fulfill()
        }
    }
    
//    private func checkUnlockedAndFulfill(action: CXAnswerCallAction, counter: Int) {
//        if UIApplication.shared.isProtectedDataAvailable {
//            action.fulfill()
//        } else if counter > 180 { // fail if waiting for more then 3 minutes
//            action.fail()
//        } else {
//            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
//                self.checkUnlockedAndFulfill(action: action, counter: counter + 1)
//            }
//        }
//    }
    
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            if(self.answerCall == nil && self.outgoingCall == nil){
                sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TIMEOUT, self.data?.toJSON())
            } else {
                sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, self.data?.toJSON())
            }
            action.fail()
            return
        }
        call.endCall()
        self.callManager.removeCall(call)
        if (self.answerCall == nil && self.outgoingCall == nil) {
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_DECLINE, self.data?.toJSON())
            if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
                appDelegate.onDecline(call, action)
            } else {
                action.fulfill()
            }
        }else {
            self.answerCall = nil
            sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_ENDED, call.data.toJSON())
            if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
                appDelegate.onEnd(call, action)
            } else {
                action.fulfill()
            }
        }
    }
    
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.isOnHold = action.isOnHold
        call.isMuted = action.isOnHold
        self.callManager.setHold(call: call, onHold: action.isOnHold)
        sendHoldEvent(action.callUUID.uuidString, action.isOnHold)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.callUUID) else {
            action.fail()
            return
        }
        call.isMuted = action.isMuted
        sendMuteEvent(action.callUUID.uuidString, action.isMuted)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        guard (self.callManager.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_GROUP, [ "id": action.callUUID.uuidString, "callUUIDToGroupWith" : action.callUUIDToGroupWith?.uuidString])
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        guard (self.callManager.callWithUUID(uuid: action.callUUID)) != nil else {
            action.fail()
            return
        }
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_DMTF, [ "id": action.callUUID.uuidString, "digits": action.digits, "type": action.type.rawValue ])
        action.fulfill()
    }
    
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        guard let call = self.callManager.callWithUUID(uuid: action.uuid) else {
            action.fail()
            return
        }
        sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TIMEOUT, self.data?.toJSON())
        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.onTimeOut(call)
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Self.pluginLog("[CallKit] didActivate audioSession (mode=\(audioSession.mode.rawValue), category=\(audioSession.category.rawValue))")

        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.didActivateAudioSession(audioSession)
        }

        // Always start the audio route observer and send the activation event,
        // even for already-connected calls. Without this, speaker toggles from
        // the CallKit UI are never detected.
        startAudioRouteObserver()
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, [ "isActivate": true ])

        if(self.answerCall?.hasConnected ?? false){
            // Skip the interruption notification for already-connected calls (call-switch).
            // RTCAudioSession listens for this notification and does a full audio session
            // reconfiguration, which resets the speaker override. The Dart-side ADM restart
            // (stopLocalRecording + startLocalRecording) handles audio recovery directly.
            reapplySpeakerIfNeeded()
            return
        }
        if(self.outgoingCall?.hasConnected ?? false){
            reapplySpeakerIfNeeded()
            return
        }
        self.outgoingCall?.startCall(withAudioSession: audioSession) {success in
            if success {
                self.callManager.addCall(self.outgoingCall!)
                self.outgoingCall?.startAudio()
            }
        }
        self.answerCall?.ansCall(withAudioSession: audioSession) { success in
            if success{
                self.answerCall?.startAudio()
            }
        }
        sendDefaultAudioInterruptionNotificationToStartAudioResource()
        configureAudioSession()
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Self.pluginLog("[CallKit] didDeactivate audioSession")

        if let appDelegate = UIApplication.shared.delegate as? CallkitIncomingAppDelegate {
            appDelegate.didDeactivateAudioSession(audioSession)
        }

        if self.outgoingCall?.isOnHold ?? false || self.answerCall?.isOnHold ?? false{
            Self.pluginLog("[CallKit] didDeactivate: skipped (call on hold)")
            return
        }

        stopAudioRouteObserver()
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_AUDIO_SESSION, [ "isActivate": false ])
    }
    
    private func sendMuteEvent(_ id: String, _ isMuted: Bool) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_MUTE, [ "id": id, "isMuted": isMuted ])
    }
    
    private func sendHoldEvent(_ id: String, _ isOnHold: Bool) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_TOGGLE_HOLD, [ "id": id, "isOnHold": isOnHold ])
    }
    
    @objc public func sendCallbackEvent(_ data: [String: Any]?) {
        self.sendEvent(SwiftFlutterCallkitIncomingPlugin.ACTION_CALL_CALLBACK, data)
    }
    
    
    private func requestNotificationPermission(_ map: [String: Any]) {
        CallkitNotificationManager.shared.requestNotificationPermission(map)
    }
    
    
    private func showMissedCallNotification(_ data: Data) {
        if(!data.isShowMissedCallNotification){
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = "\(data.nameCaller)"
        content.body = "\(data.missedNotificationSubtitle)"
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = "MISSED_CALL_CATEGORY"
        content.userInfo = data.toJSON()

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(
            identifier: data.uuid,
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling missed call notification: \(error)")
            } else {
                print("Missed call notification scheduled.")
            }
        }
    }
    
}

class EventCallbackHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    
    public func send(_ event: String, _ body: Any) {
        let data: [String : Any] = [
            "event": event,
            "body": body
        ]
        eventSink?(data)
    }
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
