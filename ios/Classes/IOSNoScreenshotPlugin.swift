import Flutter
import UIKit
import ScreenProtectorKit

public class IOSNoScreenshotPlugin: NSObject,
    FlutterPlugin, FlutterStreamHandler, UIApplicationDelegate {

    // MARK: - Channels & State
    private var screenProtectorKit: ScreenProtectorKit?
    private static var methodChannel: FlutterMethodChannel?
    private static var eventChannel: FlutterEventChannel?
    private static var preventScreenShot: Bool = false

    private var eventSink: FlutterEventSink?
    private var lastSharedPreferencesState: String = ""
    private var hasSharedPreferencesChanged: Bool = false

    private static let ENABLESCREENSHOT = false
    private static let DISABLESCREENSHOT = true

    private static let preventScreenShotKey = "preventScreenShot"
    private static let methodChannelName = "com.flutterplaza.no_screenshot_methods"
    private static let eventChannelName  = "com.flutterplaza.no_screenshot_streams"
    private static let screenshotPathPlaceholder = "screenshot_path_placeholder"

    // MARK: - Shield (black cover) view
    private var shieldView: UIView?

    private func showShield() {
        guard shieldView == nil else { return }

        let window: UIWindow? = {
            if let w = screenProtectorKit?.window { return w }
            if #available(iOS 13.0, *) {
                return UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }
            } else {
                return UIApplication.shared.keyWindow
            }
        }()

        guard let w = window else { return }
        let v = UIView(frame: w.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        v.backgroundColor = .black
        v.isUserInteractionEnabled = false
        w.addSubview(v)
        w.bringSubviewToFront(v)
        shieldView = v
    }

    private func hideShield() {
        shieldView?.removeFromSuperview()
        shieldView = nil
    }

    // MARK: - Init / Register
    init(screenProtectorKit: ScreenProtectorKit) {
        self.screenProtectorKit = screenProtectorKit
        super.init()

        // Restore saved toggle and apply
        let saved = UserDefaults.standard.bool(forKey: IOSNoScreenshotPlugin.preventScreenShotKey)
        updateScreenshotState(isScreenshotBlocked: saved ? Self.DISABLESCREENSHOT : Self.ENABLESCREENSHOT)

        // Observe screen capture (recording/mirroring)
        if #available(iOS 11.0, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleCaptureChange),
                name: UIScreen.capturedDidChangeNotification,
                object: nil
            )
            if UIScreen.main.isCaptured { showShield() }
        }

        // Observe manual screenshots (telemetry only)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenshotDetected),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        eventChannel  = FlutterEventChannel(name: eventChannelName,  binaryMessenger: registrar.messenger())

        // Scene-safe key window (avoids RTL layout jump on iOS 13+/26)
        var keyWindow: UIWindow?
        if #available(iOS 13.0, *) {
            keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        } else {
            keyWindow = UIApplication.shared.keyWindow
        }

        let spk = ScreenProtectorKit(window: keyWindow)
        spk.configurePreventionScreenshot()

        let instance = IOSNoScreenshotPlugin(screenProtectorKit: spk)
        registrar.addMethodCallDelegate(instance, channel: methodChannel!)
        eventChannel?.setStreamHandler(instance)
        registrar.addApplicationDelegate(instance)
    }

    // MARK: - UIApplicationDelegate (snapshot cover + persistence)
    public func applicationWillResignActive(_ application: UIApplication) {
        // Cover before app switcher snapshot
        showShield()
        persistState()
    }

    public func applicationDidBecomeActive(_ application: UIApplication) {
        hideShield()
        fetchPersistedState()
    }

    public func applicationWillEnterForeground(_ application: UIApplication) {
        fetchPersistedState()
    }

    public func applicationDidEnterBackground(_ application: UIApplication) {
        persistState()
    }

    public func applicationWillTerminate(_ application: UIApplication) {
        persistState()
    }

    // MARK: - Screen recording / mirroring
    @objc private func handleCaptureChange() {
        if #available(iOS 11.0, *) {
            UIScreen.main.isCaptured ? showShield() : hideShield()
        }
    }

    // MARK: - Method channel
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "screenshotOff":
            shotOff(); result(true)
        case "screenshotOn":
            shotOn(); result(true)
        case "toggleScreenshot":
            IOSNoScreenshotPlugin.preventScreenShot ? shotOn() : shotOff()
            result(true)
        case "startScreenshotListening":
            // observers already set; ensure stream ticks
            persistState()
            result("Listening started")
        case "stopScreenshotListening":
            // keep observers; Dart side may stop listening
            persistState()
            result("Listening stopped")
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func shotOff() {
        IOSNoScreenshotPlugin.preventScreenShot = IOSNoScreenshotPlugin.DISABLESCREENSHOT
        screenProtectorKit?.enabledPreventScreenshot()
        persistState()
    }

    private func shotOn() {
        IOSNoScreenshotPlugin.preventScreenShot = IOSNoScreenshotPlugin.ENABLESCREENSHOT
        screenProtectorKit?.disablePreventScreenshot()
        persistState()
    }

    // MARK: - Manual screenshot telemetry (cannot block photo)
    @objc private func screenshotDetected() {
        updateSharedPreferencesState(IOSNoScreenshotPlugin.screenshotPathPlaceholder)
    }

    // MARK: - Persist toggle
    private func persistState() {
        UserDefaults.standard.set(
            IOSNoScreenshotPlugin.preventScreenShot,
            forKey: IOSNoScreenshotPlugin.preventScreenShotKey
        )
        updateSharedPreferencesState("")
    }

    private func fetchPersistedState() {
        let saved = UserDefaults.standard.bool(forKey: IOSNoScreenshotPlugin.preventScreenShotKey)
        updateScreenshotState(isScreenshotBlocked: saved ? Self.DISABLESCREENSHOT : Self.ENABLESCREENSHOT)
    }

    private func updateScreenshotState(isScreenshotBlocked: Bool) {
        if isScreenshotBlocked {
            screenProtectorKit?.enabledPreventScreenshot()
        } else {
            screenProtectorKit?.disablePreventScreenshot()
        }
    }

    // MARK: - Event stream to Dart
    private func updateSharedPreferencesState(_ screenshotData: String) {
        let map: [String: Any] = [
            "is_screenshot_on": IOSNoScreenshotPlugin.preventScreenShot,
            "screenshot_path": screenshotData,
            "was_screenshot_taken": !screenshotData.isEmpty
        ]
        let jsonString = convertMapToJsonString(map)
        if lastSharedPreferencesState != jsonString {
            hasSharedPreferencesChanged = true
            lastSharedPreferencesState = jsonString
        }
    }

    private func convertMapToJsonString(_ map: [String: Any]) -> String {
        if let jsonData = try? JSONSerialization.data(withJSONObject: map, options: .prettyPrinted) {
            return String(data: jsonData, encoding: .utf8) ?? ""
        }
        return ""
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.screenshotStream()
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func screenshotStream() {
        if hasSharedPreferencesChanged {
            eventSink?(lastSharedPreferencesState)
            hasSharedPreferencesChanged = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.screenshotStream()
        }
    }

    deinit {
        screenProtectorKit?.removeAllObserver()
        NotificationCenter.default.removeObserver(self)
    }
}
