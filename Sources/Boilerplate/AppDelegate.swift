//
//  AppDelegate.swift
//  Parklee
//
//  Created by Solution Analysts Pvt. Ltd. on 14/05/15.
//  Copyright (c) 2015 Solution Analysts Pvt. Ltd.. All rights reserved.
//

import UIKit
import Fabric
import Crashlytics
import CoreData
import XHDrawerController
import Reachability
import Parse
import MBProgressHUD
import Stripe

let logParklee = SwiftyBeaver.self
	
@UIApplicationMain

/** Main class,
managing all app states.
*/
class AppDelegate: UIResponder, UIApplicationDelegate, SaveCreditCard {
    
    var window: UIWindow?
    var drawerController : XHDrawerController?
    var navigationController:UINavigationController?
    var fbHelper:SAFBHelper = SAFBHelper()
    var reachability:Reachability?
    var isNetworkAvailable:Bool!
    var dictUserInfo:NSMutableDictionary = NSMutableDictionary()
    var SpaceInfo = Dictionary<String,AnyObject>()
    var arrayCreditCards:NSMutableArray = []

	/**
	Check internet status
	*/
    func checkInternetStatus() {
        NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(AppDelegate.reachabilityChanged(_:)), name: kReachabilityChangedNotification, object: nil)
        reachability = Reachability.reachabilityForInternetConnection()
        reachability!.startNotifier()
        NSNotificationCenter.defaultCenter().postNotificationName(kReachabilityChangedNotification, object: self)
    }

	/**
	Check reachabilityChanged status
	*/
    func reachabilityChanged(notification:NSNotification) {
        let internetStatus:NetworkStatus = reachability!.currentReachabilityStatus()
        if(internetStatus == .NotReachable) {
            isNetworkAvailable = false
            Helper.displayAlertView("Parklee", message: MessageErrorConstant.Network.internetGone.rawValue)
        }
        else {
            isNetworkAvailable = true
            configureUtility()
            NSNotificationCenter.defaultCenter().postNotificationName("reloadMyParklee", object: nil)
        }
    }
	
	/**
	Show Version and Build in Settings
	*/
    func setAppSettingsBundleInformation() {
        let standardUserDefaults = NSUserDefaults.standardUserDefaults()
        if let versionNumber = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") as? String {
            standardUserDefaults.setObject(versionNumber, forKey: "version_number")
        }
        if let buildNumber = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleVersion") as? String {
            standardUserDefaults.setObject(buildNumber, forKey: "build_number")
        }
    }
	
    func application(application: UIApplication, didFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
        self.setAppSettingsBundleInformation()
        NSUserDefaults.standardUserDefaults().setValue(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        checkInternetStatus()
		configureUtility()
        if let mixpanelToken = ParkleeConfiguration.sharedInstance.mixpanelToken {
            if ParkleeConfiguration.sharedInstance.currentConfiguration != "Development" {
                _ = AnalyticsIO.init(WithKey: mixpanelToken)
                AnalyticsIO.sharedInstance.enableAnalytics = true
            }
        }
        setupLogsAndDestination()
        window = UIWindow(frame: UIScreen.mainScreen().bounds)
		registerForRemoteNotification()
        let drawerController:XHDrawerController = getDrawerControllerWithInitialController()
        drawerController.springAnimationOn = false
        self.window!.rootViewController = drawerController
        self.window!.makeKeyAndVisible()
        checkForAppUpdate()
        if launchOptions != nil {
            if let userInfo = launchOptions![UIApplicationLaunchOptionsRemoteNotificationKey] as? [NSObject : AnyObject] {
                PFPush.handlePush(userInfo)
                handleRemoteNotification(userInfo,onAppLaunch:false)
            }
        }
        let loggedIn = Helper.getBoolPREF(prefIsLoggedIn)
        if loggedIn == true {
            checkForPendingRating()
        }
        ParkleeApiManager.getPricePerGlobalValue(log: true, paramsDict: nil) { (object, error) in
            if object != nil {
                pricePer = object?.objectForKey("price_per") as! Double
            } else {
                Helper.displayApiErrorAlertView(message: error?.localizedDescription ?? "")
            }
        }
        Fabric.with([Crashlytics.self])
        if let userID = PFCurrentUser.objectId {
            Crashlytics.sharedInstance().setUserIdentifier(userID)
        }
        
        FBSDKAppLinkUtility.fetchDeferredAppLink({ (url, error) in
            if error != nil {
                print("APPDELEGATE FBAPPLINK ERROR")
            }
            if url != nil {
                UIApplication.sharedApplication().openURL(url)
            }
        })
        return true
    }
	
	/**
	Using SwiftyBeaver Logs
	*/
    func setupLogsAndDestination() {
        if ParkleeConfiguration.sharedInstance.currentConfiguration != "Production" {
        let console = ConsoleDestination()
        console.colored = true
        logParklee.addDestination(console)
        logParklee.info("STARTING LOGS")
        }
    }
	
	/**
	Force Rating View for driver to rate space
	*/
    func loadViewControllersForRating(arrPendingReservations:NSArray) {
        var currentIndex = 0
        logParklee.info(arrPendingReservations.count)
		
        func loadController() {
            if currentIndex < arrPendingReservations.count {
                if let reservationID = arrPendingReservations[currentIndex].objectForKey("reservationID") as? String, let spaceID = arrPendingReservations[currentIndex].objectForKey("spaceID") as? String {
                    if let _ = appDelegate.navigationController!.visibleViewController {
                        let storyBoard = UIStoryboard(name: "FindSpace", bundle: nil)
                        let rateingViewController: RateingViewController = storyBoard.instantiateViewControllerWithIdentifier("RateingViewController") as! RateingViewController
                        rateingViewController.reservationID = reservationID
                        rateingViewController.spaceID = spaceID
                        rateingViewController.isFrom = RatingTo.Space.rawValue
                        ez.topMostVC?.presentViewController(rateingViewController, animated: true, completion: {
							currentIndex += 1
                            loadController()
                        })
                    }
                }
            }
        }
        loadController()
    }
	
	/**
	checkForPendingRating
	*/
    func checkForPendingRating() {
        if let userID = PFCurrentUser.objectId {
            let params: [String:AnyObject] = ["userID":userID]
            ParkleeApiManager.pendingRatingsForDriver(log: true, paramsDict: params, completion: { (object, error) -> Void in
                if object != nil {
                    if let arrPendingReservations = object?.objectForKey("reservations") as? NSArray {
                        self.loadViewControllersForRating(arrPendingReservations)
                    }
                } else {
                    Helper.displayApiErrorAlertView(message: error?.localizedDescription ?? "")
                }
            })
        }
    }

	/**
	Parse and Stripe dynamic configurations
	*/
	func configureUtility() {
        if isNetworkAvailable == true {
            // Stripe
            if let stripKey = ParkleeConfiguration.sharedInstance.stripePublisherKey {
                Stripe.setDefaultPublishableKey(stripKey)
            }
            // Parse
            if let parseAppID = ParkleeConfiguration.sharedInstance.parseAppId,
                let parseClientID = ParkleeConfiguration.sharedInstance.parseClientID,
                let host = ParkleeConfiguration.sharedInstance.host {
                if Parse.currentConfiguration() == nil {
                    let configuration = ParseClientConfiguration {
                        $0.applicationId = parseAppID
                        $0.clientKey = parseClientID
                        $0.server = host
                    }
                    Parse.initializeWithConfiguration(configuration)
                }
            }
        }
	}
	
	/**
	Force check for app update and clear prefs if required
	*/
    func checkForAppUpdate() {
        if isNetworkAvailable == true {
            let appVersionNumber = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleShortVersionString") as? String
            let appBuildNumber = NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleVersion") as? String
            let params: [String:AnyObject] = ["version": appVersionNumber!,
                                              "build": appBuildNumber!,
                                              "deviceType" : "ios"]
            ParkleeApiManager.checkForUpdates(log: true, paramsDict: params, completion: { (object, error) -> Void in
                if object != nil {
                    if let clearPref = object?.objectForKey("cleanPref") as? Bool {
                        if clearPref == true {
                            let appDomain = NSBundle.mainBundle().bundleIdentifier!
                            NSUserDefaults.standardUserDefaults().removePersistentDomainForName(appDomain)
                        }
                    }
                    if let fUpdate = object?.objectForKey("forceUpdate") as? Bool {
                        if fUpdate == true {
                            let webContents = object?.objectForKey("content") as! String
                            if let activeController = appDelegate.navigationController!.visibleViewController {
                                let storyBoard = UIStoryboard(name: "FindSpace", bundle: nil)
                                let forceUpdateViewController: ForceUpdateViewController = storyBoard.instantiateViewControllerWithIdentifier("ForceUpdateViewController") as! ForceUpdateViewController
                                forceUpdateViewController.webContent = webContents
                                activeController.presentViewController(forceUpdateViewController, animated: true, completion: { () -> Void in
                                    
                                })
                            }
                        }
                    }
                }
            })
        }
    }
	
    // MARK:- Remote notification delegate methods
	/**
	 handle Remote notification delegate methods
	*/
    func application(application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: NSData) {
        let currentInstallation = PFInstallation.currentInstallation()
        currentInstallation!.setDeviceTokenFromData(deviceToken)
        currentInstallation!.channels = ["global"]
        currentInstallation!.setObject(ez.appVersion!, forKey: "appVersionNumber")
        currentInstallation!.setObject(ez.appBuild!, forKey: "appBuildNumber")
        currentInstallation!.saveInBackgroundWithBlock { (isSave, error) -> Void in
        }
    }
	
	/**
	handle registerForRemoteNotification
	*/
    func registerForRemoteNotification() {
        UIApplication.sharedApplication().registerForRemoteNotifications()
        let settings = UIUserNotificationSettings(forTypes: [UIUserNotificationType.Alert, UIUserNotificationType.Badge, UIUserNotificationType.Sound], categories: nil)
        UIApplication.sharedApplication().registerUserNotificationSettings(settings)
    }
	
	/**
	handle didReceiveRemoteNotification
	*/
    func application(application: UIApplication, didReceiveRemoteNotification userInfo: [NSObject : AnyObject]) {
        if let notificationType = userInfo["type"] as? Int {
            if notificationType != 2 {
                PFPush.handlePush(userInfo)
            }
        }
        handleRemoteNotification(userInfo,onAppLaunch:false)
    }
	
	/**
	handle handleRemoteNotification
	*/
    func handleRemoteNotification(userInfo:[NSObject : AnyObject] , onAppLaunch:Bool) {
		logParklee.info("user \(userInfo)")
        if let notificationType = userInfo["type"] as? Int {
            
            if notificationType == 2 {
                let navigationController1 = appDelegate.navigationController
                if let activeController = navigationController1!.visibleViewController {
                    let storyBoard = UIStoryboard(name: "FindSpace", bundle: nil)
                    let rateingViewController: RateingViewController = storyBoard.instantiateViewControllerWithIdentifier("RateingViewController") as! RateingViewController
                    rateingViewController.reservationID = userInfo["reservationID"]! as! String
                    rateingViewController.spaceID = userInfo["spaceID"]! as! String
                    rateingViewController.isFrom = RatingTo.Space.rawValue
                    activeController.presentViewController(rateingViewController, animated: true, completion: { () -> Void in
                    })
                }
            }
            
			if notificationType == 3 {
				let navigationController1 = appDelegate.navigationController
                let isLoggedIn = Helper.getBoolPREF(prefIsLoggedIn)
                if isLoggedIn == false {
                    if let activeController = navigationController1!.visibleViewController {
                        let storyBoard = UIStoryboard(name: UIInterface.StoryBoard.Main, bundle: nil)
                        let signUpController: SignInViewController = storyBoard.instantiateViewControllerWithIdentifier("signInViewController") as! SignInViewController
                        signUpController.isFromPushNotification = true
                        let navigation = UINavigationController(rootViewController: signUpController)
                        activeController.presentViewController(navigation, animated: true, completion: { () -> Void in
                        })
                    }
                }   else {
                    if let activeController = navigationController1!.visibleViewController {
                        let storyBoard = UIStoryboard(name: UIInterface.StoryBoard.Main, bundle: nil)
                        guard let currentLoginUser = PFCurrentUser.object else { return }
                        let controller = storyBoard.instantiateViewControllerWithIdentifier("signUpThirdViewController") as! SignUpThirdViewController
                        controller.isFromMyAccount = true
                        controller.delegate = self
                        controller.ispresetnview = true
                        controller.user = currentLoginUser
                        let navigation = UINavigationController(rootViewController: controller)
                        activeController.presentViewController(navigation, animated: true, completion: { () -> Void in
                        })
                    }
                }
			}
        }
    }
	
	/**
	handle getDrawerControllerWithInitialController
	*/
    func getDrawerControllerWithInitialController() -> XHDrawerController {
        let drawerController:XHDrawerController = XHDrawerController()
        drawerController.springAnimationOn = true
        let leftMenuController:LeftMenuViewController = LeftMenuViewController()
        let findSpaceStoryBoard:UIStoryboard = UIStoryboard(name: "FindSpace", bundle: nil)
        let findSpaceController: AnyObject = findSpaceStoryBoard.instantiateInitialViewController()!
        drawerController.leftViewController = leftMenuController
        appDelegate.navigationController = findSpaceController as? UINavigationController
        drawerController.centerViewController = findSpaceController as! UIViewController
        
        let backgroundView = UIView(frame: UIScreen.mainScreen().bounds)
        let imageViewBG = UIImageView(frame: backgroundView.bounds)
        imageViewBG.contentMode = UIViewContentMode.ScaleToFill
        imageViewBG.image = UIImage(named: "App_Bg")
        backgroundView.addSubview(imageViewBG)
        
        let imageViewLogo = UIImageView(frame: CGRectMake(0, 28, 40, 40))
        imageViewLogo.center = CGPointMake(backgroundView.center.x, imageViewLogo.center.y)
        imageViewLogo.image = UIImage(named: "home_logo")
        backgroundView.addSubview(imageViewLogo)

        let viewBlur = UIView(frame: backgroundView.bounds)
        viewBlur.backgroundColor = UIColor.blackColor().colorWithAlphaComponent(0.3)
        backgroundView.addSubview(viewBlur)
        drawerController.backgroundView = backgroundView
        
        return drawerController
    }
	
	/**
	handle showSignUpView
	*/
    func showSignUpView(referCode:String) {
        let isLoggedIn = Helper.getBoolPREF(prefIsLoggedIn)
        if isLoggedIn == true {
            return
        } else {
            if appDelegate.navigationController?.visibleViewController?.isKindOfClass(SignUpViewController) == true {
                logParklee.info(appDelegate.navigationController?.visibleViewController)
                if let activeController = appDelegate.navigationController?.visibleViewController as? SignUpViewController {
                    if (activeController.presentingViewController != nil) {
                        logParklee.error("PRESENTING")
                        activeController.dismissViewControllerAnimated(true, completion: {
                            self.callSignUpScreenWithReferCode(referCode)
                        })
                    }
                    else {
                        logParklee.error("PUSHED")
                        self.callSignUpScreenWithReferCode(referCode)
                    }
                }
            } else {
                callSignUpScreenWithReferCode(referCode)
            }
        }
    }
	
	/**
	handle callSignUpScreenWithReferCode
	*/
    func callSignUpScreenWithReferCode(referCode:String) {
        let navigationController1 = appDelegate.navigationController
        if let activeController = navigationController1!.visibleViewController {
            let storyBoard = UIStoryboard(name: "Main", bundle: nil)
            let controller = storyBoard.instantiateViewControllerWithIdentifier("navigationRoot") as! UINavigationController
            controller.title = "SIGN UP"
            let rootController = controller.viewControllers[0] as! SignUpViewController
            rootController.referralCode = referCode
            rootController.isFromShareUrl = true
            activeController.presentViewController(controller, animated: true, completion: { () -> Void in
            })
        }
    }
	
	/**
	handle sourceApplication
	*/
    func application(application: UIApplication, openURL url: NSURL, sourceApplication: String?, annotation: AnyObject) -> Bool {
//        Branch.getInstance().handleDeepLink(url)
        let urlString = String(url)
        logParklee.info(urlString)
        if urlString.contains("parkleeapp://share") || urlString.contains("parkleeqaapp://share") || urlString.contains("parkleedevapp://share") || urlString.contains("share?referCode=") {
            let referralCode = urlString.componentsSeparatedByString("=")[1]
            logParklee.info("SPLITTED VALUE = \(referralCode)")
            self.showSignUpView(referralCode)
        }
        
        if(FBSDKAccessToken.currentAccessToken() != nil) {
            return FBSDKApplicationDelegate.sharedInstance().application(
                application,
                openURL: url,
                sourceApplication: sourceApplication,
                annotation: annotation)
        } else {
            if(Helper.getBoolPREF(prefFirstFbSignup)) {
                return FBSDKApplicationDelegate.sharedInstance().application(
                    application,
                    openURL: url,
                    sourceApplication: sourceApplication,
                    annotation: annotation)
            } else {
                return FBSDKApplicationDelegate.sharedInstance().application(
                    application,
                    openURL: url,
                    sourceApplication: sourceApplication,
                    annotation: annotation)
            }
        }
    }
    
	
	/**
	handle continueUserActivity
	*/
    func application(application: UIApplication, continueUserActivity userActivity: NSUserActivity, restorationHandler: ([AnyObject]?) -> Void) -> Bool {
        
        if let urlString = userActivity.webpageURL?.absoluteString {
            if urlString.contains("share?referCode=") {
                let referralCode = urlString.componentsSeparatedByString("=")[1]
                logParklee.info("SPLITTED VALUE = \(referralCode)")
                self.showSignUpView(referralCode)
            }
        }
        
        return true
//         return Branch.getInstance().continueUserActivity(userActivity)
    }
	
	// MARK:- delegate method to save credit card detail
	/**
	handle saveCreditCard
	*/
	func saveCreditCard(creditCard:NSDictionary) {
		self.arrayCreditCards.addObject(creditCard)
	}
    
	// --------------------------------------------------
	/**
	handle applicationWillResignActive
	*/
    func applicationWillResignActive(application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
		
		handleLocationServiceOnBackground()
    }
	
	/**
	handle applicationDidEnterBackground
	*/
    func applicationDidEnterBackground(application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }
	
	/**
	handle applicationWillEnterForeground
	*/
    func applicationWillEnterForeground(application: UIApplication) {
        // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
		
		// To check if location service enabled from settings
		handleLocationServiceOnForeground()

    }
	
	/**
	handle applicationDidBecomeActive
	*/
    func applicationDidBecomeActive(application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        FBSDKAppEvents.activateApp()
    }
	
	/**
	handle handleLocationServiceOnForeground
	*/
	func handleLocationServiceOnForeground() {
		if (ParkleeLocationManager.parkleeLocationManager.isLocationPermissionGiven) {
			ParkleeLocationManager.parkleeLocationManager.locationManager?.stopMonitoringSignificantLocationChanges()
			ParkleeLocationManager.parkleeLocationManager.locationManager?.startUpdatingLocation()
		}
	}

	/**
	handle handleLocationServiceOnBackground
	*/
	func handleLocationServiceOnBackground() {
		if (ParkleeLocationManager.parkleeLocationManager.isLocationPermissionGiven) {
			ParkleeLocationManager.parkleeLocationManager.locationManager?.stopUpdatingLocation()
			ParkleeLocationManager.parkleeLocationManager.locationManager?.startMonitoringSignificantLocationChanges()
		}
	}
	
	/**
	handle applicationWillTerminate
	*/
    func applicationWillTerminate(application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
    
    // MARK: - Core Data stack
	/**
	handle applicationDocumentsDirectory
	*/
    lazy var applicationDocumentsDirectory: NSURL = {
        // The directory the application uses to store the Core Data store file. This code uses a directory named "com.parklee.parklee" in the application's documents Application Support directory.
        let urls = NSFileManager.defaultManager().URLsForDirectory(.DocumentDirectory, inDomains: .UserDomainMask)
        return urls[urls.count-1] 
	}()
    
    lazy var managedObjectModel: NSManagedObjectModel = {
        // The managed object model for the application. This property is not optional. It is a fatal error for the application not to be able to find and load its model.
        let modelURL = NSBundle.mainBundle().URLForResource("Parklee", withExtension: "momd")!
        return NSManagedObjectModel(contentsOfURL: modelURL)!
        }()
    
    lazy var persistentStoreCoordinator: NSPersistentStoreCoordinator? = {
        // The persistent store coordinator for the application. This implementation creates and return a coordinator, having added the store for the application to it. This property is optional since there are legitimate error conditions that could cause the creation of the store to fail.
        // Create the coordinator and store
        var coordinator: NSPersistentStoreCoordinator? = NSPersistentStoreCoordinator(managedObjectModel: self.managedObjectModel)
        let url = self.applicationDocumentsDirectory.URLByAppendingPathComponent("Parklee.sqlite")
        var error: NSError? = nil
        var failureReason = "There was an error creating or loading the application's saved data."
        do {
			try coordinator!.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: url, options: [NSMigratePersistentStoresAutomaticallyOption : true , NSInferMappingModelAutomaticallyOption : true])
        } catch var error1 as NSError {
            error = error1
            coordinator = nil
            // Report any error we got.
            var dict = [String: AnyObject]()
            dict[NSLocalizedDescriptionKey] = "Failed to initialize the application's saved data"
            dict[NSLocalizedFailureReasonErrorKey] = failureReason
            dict[NSUnderlyingErrorKey] = error
            error = NSError(domain: "YOUR_ERROR_DOMAIN", code: 9999, userInfo: dict)
            // Replace this with code to handle the error appropriately.
            // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            NSLog("Unresolved error \(error), \(error!.userInfo)")
            abort()
        } catch {
            fatalError()
        }
        
        return coordinator
        }()
    
    lazy var managedObjectContext: NSManagedObjectContext? = {
        // Returns the managed object context for the application (which is already bound to the persistent store coordinator for the application.) This property is optional since there are legitimate error conditions that could cause the creation of the context to fail.
        let coordinator = self.persistentStoreCoordinator
        if coordinator == nil {
            return nil
        }
        var managedObjectContext = NSManagedObjectContext()
        managedObjectContext.persistentStoreCoordinator = coordinator
        return managedObjectContext
        }()
    
    // MARK: - Core Data Saving support
	/**
	handle saveContext
	*/
    func saveContext () {
        if let moc = self.managedObjectContext {
            var error: NSError? = nil
            if moc.hasChanges {
                do {
                    try moc.save()
                } catch let error1 as NSError {
                    error = error1
                    // Replace this implementation with code to handle the error appropriately.
                    // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
                    NSLog("Unresolved error \(error), \(error!.userInfo)")
                    abort()
                }
            }
        }
    }
}
