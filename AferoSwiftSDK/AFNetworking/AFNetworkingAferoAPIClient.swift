//
//  AferoAPIClient.swift
//  AferoLab
//
//  Created by Justin Middleton on 3/17/17.
//  Copyright © 2017 Afero, Inc. All rights reserved.
//

import Foundation
import AFNetworking
import AFOAuth2Manager
import PromiseKit
import CocoaLumberjack


public class AFNetworkingAferoAPIClient {

    public struct Config {

        let oauthClientId: String
        let oauthClientSecret: String?
        let apiHostname: String
        
        var apiBaseURL: URL {
            URL(string: "https://\(apiHostname)")!
        }
        
        let oAuthOpenIdURL: URL?
        
        let softhubService: String?
        let authenticatorCert: String?
        
        public init(apiHostname: String = "api.afero.io", softhubService:String?,
                    authenticatorCert:String?,
                    oAuthOpenIdURL: String?,
                    oauthClientId: String,
                    oauthClientSecret: String?) {
            self.apiHostname = apiHostname
            self.softhubService = softhubService
            self.authenticatorCert = authenticatorCert
            self.oAuthOpenIdURL = oAuthOpenIdURL != nil ? URL(string: oAuthOpenIdURL!) : nil
            self.oauthClientId = oauthClientId
            self.oauthClientSecret = oauthClientSecret
        }
        
        static let OAuthClientIdKey = "OAuthClientId"
        static let OAuthClientSecretKey = "OAuthClientSecret"
        static let APIHostnameKey = "APIHostname"
        static let SofthubServiceKey = "SofthubService"
        static let AuthenticatorCertKey = "AuthenticatorCert"
        static let OAuthOpenIdUrlKey = "OAuthOpenIdURL"

        
        init(with plistData: Data) {
            
            let plistDict: [String: Any]
            
            do {
                guard let maybePlistDict = try PropertyListSerialization.propertyList(from: plistData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] else {
                    fatalError("plist data is not a dict.")
                }
                plistDict = maybePlistDict
                
            } catch {
                fatalError("Unable to read dictionary from plistData: \(String(reflecting: error))")
            }
            
            let clientIdKey = type(of: self).OAuthClientIdKey
            let clientSecretKey = type(of: self).OAuthClientSecretKey
            
            guard let oauthClientId = plistDict[clientIdKey] as? String else {
                fatalError("No string keyed by \(clientIdKey) found in \(String(describing: plistDict))")
            }
            
            let oauthClientSecret = plistDict[clientSecretKey] as? String
            
            var apiHostname = "api.afero.io"
            
            if let maybeApiHostnameString = plistDict[type(of: self).APIHostnameKey] as? String {
                apiHostname = maybeApiHostnameString
                DDLogWarn("Overriding apiBaseUrl with \(apiHostname)", tag: "AFNetworkingAferoAPIClient.Config")
            }
            
            let oAuthOpenIdURL: String? = plistDict[type(of: self).OAuthOpenIdUrlKey] as? String
                        
            let softhubService = plistDict[type(of: self).SofthubServiceKey] as? String
            
            let authenticatorCert = plistDict[type(of: self).AuthenticatorCertKey] as? String
     
            
            self.init(apiHostname: apiHostname,
                      softhubService: softhubService,
                      authenticatorCert: authenticatorCert,
                      oAuthOpenIdURL: oAuthOpenIdURL,
                      oauthClientId: oauthClientId,
                      oauthClientSecret: oauthClientSecret)
        }
        
        init(withPlistNamed plistName: String) {
            
            guard let plist = Bundle.main.path(forResource: plistName, ofType: "plist") else {
                fatalError("Unable to find plist '\(plistName).plist' in main bundle; can't create API client.")
            }
            
            guard let plistData = FileManager.default.contents(atPath: plist) else {
                fatalError("Unable to read plist '\(plistName).plist' in main bundle.")
            }
            
            self.init(with: plistData)
        }
        
    }

    public var TAG: String { return "AFNetworkingAferoAPIClient" }

    public var softhubService: String? { return config.softhubService }
    public var authenticatorCert: String? { return config.authenticatorCert }
    public var apiHostname: String { return config.apiHostname }
    public var apiBaseURL: URL { return config.apiBaseURL }
    public var oAuthOpenIdURL: URL? { return config.oAuthOpenIdURL }
        
    public var oauthClientId: String { return config.oauthClientId }
    var oauthClientSecret: String { return config.oauthClientSecret ?? "" }
    
    let config: Config
    
    public init(config: Config) {
        self.config = config
    }
    
    public convenience init(withPlistNamed plistName: String) {
        self.init(config: Config(withPlistNamed: plistName))
    }

    // MARK: - Session Manager... management -
    
    private var _defaultSessionManager: AFHTTPSessionManager?
    fileprivate var defaultSessionManager: AFHTTPSessionManager! {
        
        get {
            if let sessionManager = _defaultSessionManager {
                return sessionManager
            }

            _defaultSessionManager = type(of: self).createSessionManager(
                baseURL: apiBaseURL,
                oauthCredential: oauthCredential
            )
            
            return _defaultSessionManager
        }
        
        set { _defaultSessionManager = newValue }
        
    }
    
    func sessionManager(with httpRequestHeaders: HTTPRequestHeaders? = nil) -> AFHTTPSessionManager {
        
        if httpRequestHeaders?.isEmpty ?? true {
            return defaultSessionManager
        }
        
        let ret = defaultSessionManager.copy() as! AFHTTPSessionManager
        
        httpRequestHeaders?.keys.forEach {
            ret.requestSerializer.setValue(httpRequestHeaders![$0], forHTTPHeaderField: $0)
        }
        
        return ret
    }
    
    /// Create an AFHTTPSessionManager whith the given parameters.
    ///
    /// - parameter baseURL: The base URL for requests made by this manager.
    /// - parameter requestSerializer: The serializer to be used when forming requests.
    ///   If `nil`, a default `AferoAFJSONRequestSerializer` will be used.
    /// - parameter responseSerializer: The serializer to be used for deserializing
    ///   responses. If `nil`, a default `AferoAFJSONResponseSerializer` will be used.
    /// - parameter httpHeaders: Optionally a dictionary of HTTP headers to be associated
    ///   with the manager.
    ///
    /// - note: If a non-`nil` `httpHeaders` dictionary is provided, then they will be added
    ///   to the given serializer prior to any standard-required headers.
    
    class func createSessionManager(baseURL: URL? = nil,
                                requestSerializer: AFHTTPRequestSerializer? = nil,
                                responseSerializer: AFHTTPResponseSerializer? = nil,
                                httpHeaders: HTTPRequestHeaders? = nil,
                                oauthCredential maybeOauthCredential: AFOAuthCredential? = nil
        ) -> AFHTTPSessionManager {
        
        let ret = AFHTTPSessionManager(baseURL: baseURL)
        
        ret.responseSerializer = responseSerializer ?? AferoAFJSONResponseSerializer()
        ret.requestSerializer = requestSerializer ?? AferoAFJSONRequestSerializer()
        
        httpHeaders?.keys.forEach {
            ret.requestSerializer.setValue(httpHeaders![$0], forHTTPHeaderField: $0)
        }
        
        ret.requestSerializer.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        
        if let oauthCredential = maybeOauthCredential {
            ret.requestSerializer.setAuthorizationHeaderFieldWith(oauthCredential)
        }
        
        return ret

    }
    
    
}

// MARK: - OAuth -

public extension AFNetworkingAferoAPIClient {

    var oauthCredentialIdentifier: String { return apiBaseURL.host! }

    var oauthCredential: AFOAuthCredential? {
        get {
            return AFOAuthCredential.retrieveCredential(withIdentifier: self.oauthCredentialIdentifier)
        }
    }

    static let OAUTH_TOKEN_PATH = "/oauth/token"

    /// Attempt to obtain a valid OAUTH2 token from the service.
    /// - parameter username: The "username" (currently email address) to use to authenticate to the service.
    /// - parameter password: The password to use for authentication
    /// - parameter scope: Should always be `account` (the default)
    /// - returns: A Promise<Void> which fulfills once the OAUTH2 token has been successfully retrieved and stored,
    ///            and rejects on any failure.

    func signIn(username: String, password: String, scope: String = "account") -> Promise<Void> {

        let clientTokenPath = type(of: self).OAUTH_TOKEN_PATH
        let TAG = self.TAG
        
        return Promise {

            fulfill, reject in

            DDLogInfo("Authenticating...", tag: TAG)
            
            let oauthManager = AFOAuth2Manager(
                baseURL: self.apiBaseURL,
                clientID: self.oauthClientId,
                secret: self.oauthClientSecret
            )

            _ = oauthManager.authenticateUsingOAuth(
                withURLString: clientTokenPath,
                username: username,
                password: password,
                scope: scope,

                success: {
                    credential in

                    DDLogInfo("Successfully acquired OAuth2 token.", tag: TAG)
                    
                    self.signIn(credential: credential).then {
                        _ in fulfill(())
                    }
            },

                failure: {
                    error in
                    DDLogError("Failed to acquire OAuth2 token: \(String(reflecting: error))", tag: TAG)
                    reject(error)
            }
            )
        }
    }

    /// Given an accessToken, tokentType, and refreshToken, store, initialized the session manager,
    /// and resolve.
    ///
    /// - parameter oAuthToken: The token acquired from the Afero cloud.
    /// - parameter tokenType: The type of the token. Defaults to "Bearer".
    /// - parameter refreshToken: If available, the refresh token to store.
    ///
    /// - returns: A Promise<Void> which resolves after storage is complete.
    
    func signIn(oAuthToken: String, tokenType: String = "Bearer", refreshToken: String? = nil) -> Promise<Void> {
        let credential = AFOAuthCredential(oAuthToken: oAuthToken, tokenType: tokenType)
        if let refreshToken = refreshToken {
            credential.setRefreshToken(refreshToken)
        }
        
        return signIn(credential: credential)
    }
    
    func signIn(credential: AFOAuthCredential) -> Promise<Void> {
        
        AFOAuthCredential.store(
            credential,
            withIdentifier: self.oauthCredentialIdentifier,
            withAccessibility: kSecAttrAccessibleAfterFirstUnlock
        )
        
        self.defaultSessionManager.requestSerializer.setAuthorizationHeaderFieldWith(credential)
        
        return Promise()
        
    }
    
    

    func signOut(_ error: Error? = nil) -> Promise<Void> {
        return Promise { fulfill, _ in self.doSignOut(error: error) { fulfill(()) } }
    }
    
}

extension AFNetworkingAferoAPIClient: AferoAPIClientProto {

    public func doSignOut(error: Error?, completion: @escaping ()->Void) {
        defaultSessionManager.requestSerializer.clearAuthorizationHeader()
        AFOAuthCredential.delete(withIdentifier: oauthCredentialIdentifier)
        completion()
    }
    
    public func doRefreshOAuth(passthroughError: Error? = nil, success: @escaping ()->Void, failure: @escaping (Error)->Void) {
        
        let TAG = self.TAG
        
        DDLogInfo("Requesting oauth refresh", tag: TAG)
        
        guard let credential = oauthCredential else {
            DDLogInfo("No credential; bailing on refresh attempt", tag: TAG)
            asyncMain { failure(passthroughError ?? "No credential.") }
            return
        }

        let oAuthTokenUrl: String? = oAuthOpenIdURL != nil ? "\(oAuthOpenIdURL!.absoluteString )/token" : nil
        
        DDLogInfo("RefreshUrl \(String(describing: oAuthTokenUrl))", tag: TAG)

        
        let oauthManager = AFOAuth2Manager(
            baseURL: apiBaseURL,
            clientID: oauthClientId,
            secret: oauthClientSecret
        )

        oauthManager.authenticateUsingOAuth(
            withURLString: oAuthTokenUrl ?? type(of: self).OAUTH_TOKEN_PATH,
            refreshToken: credential.refreshToken,
            success: {
                credential in
                DDLogInfo("Successfully refreshed OAuth2 token.", tag: TAG)
                AFOAuthCredential.store(
                    credential,
                    withIdentifier: self.oauthCredentialIdentifier,
                    withAccessibility: kSecAttrAccessibleAfterFirstUnlock
                )
                self.defaultSessionManager.requestSerializer.setAuthorizationHeaderFieldWith(credential)
                success()
        },
            failure: {
                error in
                DDLogError("Failed to refresh OAuth2 token: \(String(reflecting: error))", tag: TAG)
                failure(error)
        })
        
    }
    
    public func doGet(urlString: String, parameters: Any?, httpRequestHeaders: HTTPRequestHeaders? = nil, success: @escaping AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProtoFailure) -> URLSessionDataTask? {

        let TAG = self.TAG
        
        
        return sessionManager(with: httpRequestHeaders).get(
            urlString,
            parameters: parameters,
            progress: nil,
            success: { (task, result) -> Void in
                DDLogDebug("SUCCESS task: \(String(reflecting: task)) result: \(String(reflecting: result))", tag: TAG)
                asyncGlobalDefault {
                    success(task, result)
                }
        }) { (task, error) -> Void in
            DDLogDebug("FAILURE task: \(String(reflecting: task)) result: \(String(reflecting: error))", tag: TAG)
            asyncGlobalDefault {
                failure(task, error)
            }
        }

    }
    
    public func doPut(urlString: String, parameters: Any?, httpRequestHeaders: HTTPRequestHeaders? = nil, success: @escaping AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProtoFailure) -> URLSessionDataTask? {

        let TAG = self.TAG

        return sessionManager(with: httpRequestHeaders).put(
            urlString,
            parameters: parameters,
            success: { (task, result) -> Void in
                DDLogDebug("SUCCESS task: \(String(reflecting: task)) result: \(String(reflecting: result))", tag: TAG)
                asyncGlobalDefault {
                    success(task, result)
                }
        }) { (task, error) -> Void in
            DDLogDebug("FAILURE task: \(String(reflecting: task)) result: \(String(reflecting: error))", tag: TAG)
            asyncGlobalDefault {
                failure(task, error)
            }
        }

    }
    
    public func doPost(urlString: String, parameters: Any?, httpRequestHeaders: HTTPRequestHeaders? = nil, success: @escaping AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProtoFailure) -> URLSessionDataTask? {
        
        let TAG = self.TAG
        
        return sessionManager(with: httpRequestHeaders).post(
            urlString,
            parameters: parameters,
            progress: nil,
            success: { (task, result) -> Void in
                DDLogDebug("SUCCESS task: \(String(reflecting: task)) result: \(String(reflecting: result))", tag: TAG)
                asyncGlobalDefault {
                    success(task, result)
                }
        }) { (task, error) -> Void in
            DDLogDebug("FAILURE task: \(String(reflecting: task)) result: \(String(reflecting: error))", tag: TAG)
            asyncGlobalDefault {
                failure(task, error)
            }
        }

    }
    
    public func doDelete(urlString: String, parameters: Any?, httpRequestHeaders: HTTPRequestHeaders? = nil, success: @escaping AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProtoFailure) -> URLSessionDataTask? {
        
        let TAG = self.TAG
        
        return sessionManager(with: httpRequestHeaders).delete(
            urlString,
            parameters: parameters,
            success: { (task, result) -> Void in
                DDLogDebug("SUCCESS task: \(String(reflecting: task)) result: \(String(reflecting: result))", tag: TAG)
                asyncGlobalDefault {
                    success(task, result)
                }
        }) { (task, error) -> Void in
            DDLogDebug("FAILURE task: \(String(reflecting: task)) result: \(String(reflecting: error))", tag: TAG)
            asyncGlobalDefault {
                failure(task, error)
            }
        }

    }
    

}

// MARK: - Logging and Debugging Support -

class AferoAFJSONResponseSerializer: AFJSONResponseSerializer {

    override func responseObject(for response: URLResponse?, data: Data?, error: NSErrorPointer) -> Any? {

        var bodyString = "<empty>"

        if let prettyJson = data?.prettyJSONValue, !prettyJson.isEmpty {
            bodyString = prettyJson
        }

        DDLogDebug("Response: <body>\(bodyString)</body>", tag: "AferoAFJSONResponseSerializer")
        return super.responseObject(for: response, data: data, error: error) as AnyObject?
    }

}

class AferoAFJSONRequestSerializer: AFJSONRequestSerializer {

    override func request(bySerializingRequest request: URLRequest, withParameters parameters: Any?, error: NSErrorPointer) -> URLRequest? {
        let request = super.request(bySerializingRequest: request, withParameters: parameters, error: error)

        var bodyString = "<empty>"

        if let maybeBody = request?.httpBody?.prettyJSONValue {
            bodyString = maybeBody
        }

        DDLogDebug("Request: <headers>\(request?.allHTTPHeaderFields.debugDescription ?? "<empty>")</headers> <body>\(bodyString)</body>", tag: "AferoAFJSONRequestSerializer")
        return request
    }
    
}

