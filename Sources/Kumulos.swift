//
//  Kumulos.swift
//  Copyright © 2016 Kumulos. All rights reserved.
//

import Foundation
import UserNotifications

// MARK: delegate protocol
/*!
 *  The KumulosDelegate defines the methods for completion or failure of Kumulos operations.
 */
protocol KumulosDelegate: class {
    func didComplete(_ kumulos: Kumulos, operation: KSAPIOperation, method: String, results: KSResponse)
    func didFail(_ kumulos: Kumulos, operation: KSAPIOperation, error: NSError?)
}

internal enum KumulosEvent : String {
    case STATS_FOREGROUND = "k.fg"
    case STATS_BACKGROUND = "k.bg"
    case STATS_CALL_HOME = "k.stats.installTracked"
    case STATS_ASSOCIATE_USER = "k.stats.userAssociated"
    case STATS_USER_ASSOCIATION_CLEARED = "k.stats.userAssociationCleared"
    case PUSH_DEVICE_REGISTER = "k.push.deviceRegistered"
    case ENGAGE_BEACON_ENTERED_PROXIMITY = "k.engage.beaconEnteredProximity"
    case ENGAGE_LOCATION_UPDATED = "k.engage.locationUpdated"
    case DEVICE_UNSUBSCRIBED = "k.push.deviceUnsubscribed"
    case IN_APP_CONSENT_CHANGED = "k.inApp.statusUpdated"
    case MESSAGE_OPENED = "k.message.opened"
    case MESSAGE_DISMISSED = "k.message.dismissed"
    case MESSAGE_DELIVERED = "k.message.delivered"
    case MESSAGE_DELETED_FROM_INBOX = "k.message.inbox.deleted"
}

public typealias InAppDeepLinkHandlerBlock = ([AnyHashable:Any]) -> Void
public typealias PushOpenedHandlerBlock = (KSPushNotification) -> Void

@available(iOS 10.0, *)
public typealias PushReceivedInForegroundHandlerBlock = (KSPushNotification, (UNNotificationPresentationOptions)->Void) -> Void

public enum InAppConsentStrategy : String {
    case NotEnabled = "NotEnabled"
    case AutoEnroll = "AutoEnroll"
    case ExplicitByUser = "ExplicitByUser"
}

// MARK: class
open class Kumulos {

    private static let installIdLock = DispatchSemaphore(value: 1)
    
    internal let baseApiUrl = "https://api.kumulos.com"
    internal let basePushUrl = "https://push.kumulos.com"
    internal let baseCrashUrl = "https://crash.kumulos.com/v1"
    internal let baseEventsUrl = "https://events.kumulos.com"

    internal let pushHttpClient:KSHttpClient
    internal let rpcHttpClient:KSHttpClient
    internal let eventsHttpClient:KSHttpClient

    internal let pushNotificationDeviceType = 1
    internal let pushNotificationProductionTokenType:Int = 1
    
    internal let sdkVersion : String = "8.3.3"

    var networkRequestsInProgress = 0

    fileprivate static var instance:Kumulos?
    
    internal var notificationCenter:Any?
    
    internal static var sharedInstance:Kumulos {
        get {
            if(false == isInitialized()) {
                assertionFailure("The KumulosSDK has not been initialized")
            }

            return instance!
        }
    }
    
    public static func getInstance() -> Kumulos
    {
        return sharedInstance;
    }

    fileprivate(set) var config : KSConfig
    fileprivate(set) var apiKey: String
    fileprivate(set) var secretKey: String
    fileprivate(set) var inAppConsentStrategy:InAppConsentStrategy = InAppConsentStrategy.NotEnabled
    
    internal static var inAppConsentStrategy : InAppConsentStrategy {
        get {
            return sharedInstance.inAppConsentStrategy
        }
    }
    
    fileprivate(set) var inAppHelper: InAppHelper
        
    fileprivate(set) var analyticsHelper: AnalyticsHelper

    fileprivate var pushHelper: PushHelper

    public static var apiKey:String {
        get {
            return sharedInstance.apiKey
        }
    }

    public static var secretKey:String {
        get {
            return sharedInstance.secretKey
        }
    }

    weak var delegate:KumulosDelegate?

    internal var operationQueue = OperationQueue()

    fileprivate var sessionToken: String

    /**
        The token for the current session
    */
    public static var sessionToken:String {
        get {
            return sharedInstance.sessionToken
        }
        set {
            sharedInstance.sessionToken = newValue
        }
    }

    /**
        The unique installation Id of the current app

        - Returns: String - UUID
    */
    public static var installId :String {
        get {
            installIdLock.wait()
            defer {
                installIdLock.signal()
            }
            
            if let existingID = UserDefaults.standard.object(forKey: "KumulosUUID") {
                return existingID as! String
            }

            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "KumulosUUID")
            UserDefaults.standard.synchronize()
            
            return newID
        }
    }

    internal static func isInitialized() -> Bool {
        return instance != nil
    }

    /**
        Initialize the KumulosSDK.

        - Parameters:
              - config: An instance of KSConfig
    */
    public static func initialize(config: KSConfig) {
        if (instance !== nil) {
            assertionFailure("The KumulosSDK has already been initialized")
        }

        instance = Kumulos(config: config)
        
        instance!.initializeHelpers()
        
        DispatchQueue.global().async {
            instance!.sendDeviceInformation()
        }
        
        if (config.enableCrash) {
            instance!.trackAndReportCrashes()
        }
    }

    fileprivate init(config: KSConfig) {
        self.config = config
        apiKey = config.apiKey
        secretKey = config.secretKey
        inAppConsentStrategy = config.inAppConsentStrategy

        sessionToken = UUID().uuidString

        pushHttpClient = KSHttpClient(baseUrl: URL(string: basePushUrl)!, requestFormat: .json, responseFormat: .json)
        pushHttpClient.setBasicAuth(user: config.apiKey, password: config.secretKey)
        rpcHttpClient = KSHttpClient(baseUrl: URL(string: baseApiUrl)!, requestFormat: .json, responseFormat: .plist)
        rpcHttpClient.setBasicAuth(user: config.apiKey, password: config.secretKey)
        eventsHttpClient = KSHttpClient(baseUrl: URL(string: baseEventsUrl)!, requestFormat: .json, responseFormat: .json)
        eventsHttpClient.setBasicAuth(user: config.apiKey, password: config.secretKey)
        
        analyticsHelper = AnalyticsHelper()
        inAppHelper = InAppHelper()
        pushHelper = PushHelper()
    }
    
    private func initializeHelpers() {
        analyticsHelper.initialize(kumulos: self)
        inAppHelper.initialize()
        _ = pushHelper.pushInit
    }

    deinit {
        operationQueue.cancelAllOperations()
        rpcHttpClient.invalidateSessionCancellingTasks(true)
        pushHttpClient.invalidateSessionCancellingTasks(true)
        eventsHttpClient.invalidateSessionCancellingTasks(false)
    }

}
