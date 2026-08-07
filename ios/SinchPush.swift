import Foundation
import React
import UIKit
import UserNotifications

private let kSinchPushTokenNotification = "SinchPushTokenNotification"
private let kSinchPushMessageNotification = "SinchPushMessageNotification"

private let kEventTokenReceived = "SinchPush:onTokenReceived"
private let kEventPushReceived = "SinchPush:onPushReceived"

private var gLatestToken: NSDictionary?

@objc(SinchPush)
class SinchPush: RCTEventEmitter {

  private var hasListeners = false

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleTokenNotification(_:)),
      name: NSNotification.Name(kSinchPushTokenNotification),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleMessageNotification(_:)),
      name: NSNotification.Name(kSinchPushMessageNotification),
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - RCTEventEmitter

  override func supportedEvents() -> [String]! {
    return [kEventTokenReceived, kEventPushReceived]
  }

  override func startObserving() {
    hasListeners = true
    if let token = gLatestToken {
      sendEvent(withName: kEventTokenReceived, body: token)
    }
  }

  override func stopObserving() {
    hasListeners = false
  }

  // MARK: - Exported methods

  @objc(getDeviceToken:reject:)
  func getDeviceToken(
    _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    resolve(gLatestToken ?? [:])
  }

  @objc(registerForToken:reject:)
  func registerForToken(
    _ resolve: @escaping RCTPromiseResolveBlock,
    reject: @escaping RCTPromiseRejectBlock
  ) {
    requestNotificationAuthorizationAndRegister()
    resolve(nil)
  }

  @objc
  static func requiresMainQueueSetup() -> Bool {
    return false
  }

  // MARK: - APNs registration

  private func requestNotificationAuthorizationAndRegister() {
    let center = UNUserNotificationCenter.current()
    let options: UNAuthorizationOptions = [.alert, .badge, .sound]
    center.requestAuthorization(options: options) { _, _ in
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  // MARK: - Notification handlers

  @objc
  func handleTokenNotification(_ notification: Notification) {
    guard hasListeners, let userInfo = notification.userInfo else { return }
    sendEvent(withName: kEventTokenReceived, body: userInfo)
  }

  @objc
  func handleMessageNotification(_ notification: Notification) {
    guard hasListeners, let userInfo = notification.userInfo else { return }
    sendEvent(withName: kEventPushReceived, body: userInfo)
  }

  // MARK: - App delegate forwarding

  @objc
  static func didRegisterForRemoteNotificationsWithDeviceToken(_ deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    let token: NSDictionary = ["token": hex, "type": "apns"]
    gLatestToken = token
    NotificationCenter.default.post(
      name: NSNotification.Name(kSinchPushTokenNotification),
      object: nil,
      userInfo: token as? [AnyHashable: Any]
    )
  }

  @objc
  static func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
    NSLog("[SinchPush] APNs registration failed: %@", error.localizedDescription)
  }

  @objc
  static func didReceiveRemoteNotification(_ userInfo: NSDictionary) {
    var data: [String: String] = [:]
    for (key, value) in userInfo {
      if let key = key as? String, key != "aps" {
        data[key] = "\(value)"
      }
    }

    let aps = userInfo["aps"] as? NSDictionary
    let alert = aps?["alert"]

    let message = NSMutableDictionary()
    message["data"] = data
    message["source"] = "apns"

    if let alertDict = alert as? NSDictionary {
      if let title = alertDict["title"] as? String {
        message["title"] = title
      }
      if let body = alertDict["body"] as? String {
        message["body"] = body
      }
    } else if let alertStr = alert as? String {
      message["body"] = alertStr
    }

    if let identity = userInfo["identity"] as? String {
      message["identity"] = identity
    }

    NotificationCenter.default.post(
      name: NSNotification.Name(kSinchPushMessageNotification),
      object: nil,
      userInfo: message as? [AnyHashable: Any]
    )
  }
}
