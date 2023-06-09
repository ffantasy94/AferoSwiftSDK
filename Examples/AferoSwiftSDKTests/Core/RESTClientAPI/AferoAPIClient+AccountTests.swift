//
//  APIClientTests.swift
//  iTokui
//
//  Created by Justin Middleton on 5/15/17.
//  Copyright © 2017 Kiban Labs, Inc. All rights reserved.
//

import Foundation
import PromiseKit

import Quick
import Nimble
import HTTPStatusCodes
import OHHTTPStubs

@testable import Afero

/// Tests for the APIClient.
///
/// see https://github.com/AliSoftware/OHHTTPStubs for info on the HTTP stubbing lib.

class APIClientAccountSpec: QuickSpec {
    
    override func spec() {
        
        describe("APIClient+Account") {
            
            var apiClient: MockAPIClient! = nil
            
            beforeEach {
                apiClient = MockAPIClient()
            }
            
            afterEach {
                HTTPStubs.removeAllStubs()
            }
            
            
            describe("when calling fetchAccountInfo()") {
                
                guard let janeDoeUser: UserAccount.User = try! fixture(named: "userJaneDoe")
                    else {
                        fatalError("Unable to read JSON reasource 'userJaneDoe'.")
                }
                
                it("should GET /users/me.") {
                    
                    stub(condition: isPath("/v1/users/me") && isMethodGET()) {
                        request in
                        return OHHTTPStubs.HTTPStubsResponse(jsonObject: janeDoeUser.JSONDict!, statusCode: 200, headers: nil)
                    }
                    
                    var fetchedUser: UserAccount.User?
                    var error: Error?
                    
                    expect(apiClient.refreshOauthCount) == 0
                    
                    _ = apiClient.fetchAccountInfo()
                        .then {
                            user -> Void in
                            fetchedUser = user
                    }.catch {
                        err in
                        error = err
                    }
                    
                    expect(error).to(beNil())
                    expect(apiClient.refreshOauthCount).toNotEventually(beGreaterThan(0), timeout: DispatchTimeInterval.seconds(5))
                    expect(fetchedUser).toEventually(equal(janeDoeUser), timeout: DispatchTimeInterval.seconds(5))
                }
                
                it("should not refresh oauth if a 503 is encountered.") {
                    
                    stub(condition: isPath("/v1/users/me") && isMethodGET()) {
                        request in
                        return OHHTTPStubs.HTTPStubsResponse(jsonObject: ["error_description", "service unavailable"], statusCode: 503, headers: nil)
                    }
                    
                    var fetchedUser: UserAccount.User?
                    var error: Error?
                    
                    expect(apiClient.refreshOauthCount) == 0
                    
                    _ = apiClient.fetchAccountInfo()
                        .then {
                            user -> Void in
                            fetchedUser = user
                    }.catch {
                        err in
                        error  = err
                    }
                    
                    expect(apiClient.refreshOauthCount).toNotEventually(beGreaterThan(0), timeout: DispatchTimeInterval.seconds(5))
                    expect(fetchedUser != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error?.httpStatusCodeValue).toEventually(equal(.serviceUnavailable))
                }
                
                it("should not refresh oauth if a 500 is encountered.") {
                    
                    stub(condition: isPath("/v1/users/me") && isMethodGET()) {
                        request in
                        return OHHTTPStubs.HTTPStubsResponse(jsonObject: ["error_description", "service unavailable"], statusCode: 500, headers: nil)
                    }
                    
                    var fetchedUser: UserAccount.User?
                    var error: Error?
                    
                    expect(apiClient.refreshOauthCount) == 0
                    
                    _ = apiClient.fetchAccountInfo()
                        .then {
                            user -> Void in
                            fetchedUser = user
                    }.catch {
                        err in
                        error  = err
                    }
                    
                    expect(apiClient.refreshOauthCount).toNotEventually(beGreaterThan(0), timeout: DispatchTimeInterval.seconds(5))
                    expect(fetchedUser != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error?.httpStatusCodeValue).toEventually(equal(.internalServerError))
                    
                }
                
                it("should attempt to refresh OAuth but not change availability if a 401 is encountered.") {
                    
                    stub(condition: isPath("/v1/users/me") && isMethodGET()) {
                        _ in
                        let resp = ["error_description": "authentication required"]
                        return OHHTTPStubs.HTTPStubsResponse(jsonObject: resp, statusCode: 401, headers: nil)
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    expect(apiClient.refreshOauthCount) == 0
                    
                    _ = apiClient.fetchAccountInfo()
                        .then {
                            resp -> Void in
                            response = resp
                    }.catch {
                        err in
                        error = err
                    }
                    
                    expect(response != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error).toNotEventually(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error?.httpStatusCodeValue).toEventually(equal(.unauthorized), timeout: DispatchTimeInterval.seconds(5))
                    expect(apiClient.refreshOauthCount).toEventually(equal(1), timeout: DispatchTimeInterval.seconds(5))
                    
                }
                
                it("should not attempt to refresh OAuth or change availability if a 403 is encountered.") {
                    
                    stub(condition: isPath("/v1/users/me") && isMethodGET()) {
                        _ in
                        let resp = ["error_description": "authentication required"]
                        return OHHTTPStubs.HTTPStubsResponse(jsonObject: resp, statusCode: 403, headers: nil)
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    expect(apiClient.refreshOauthCount) == 0
                    
                    _ = apiClient.fetchAccountInfo()
                        .then {
                            resp -> Void in
                            response = resp
                    }.catch {
                        err in
                        error = err
                    }
                    
                    expect(response != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error).toNotEventually(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error?.httpStatusCodeValue).toEventually(equal(.forbidden), timeout: DispatchTimeInterval.seconds(5))
                    expect(apiClient.refreshOauthCount).toNotEventually(beGreaterThan(0), timeout: DispatchTimeInterval.seconds(5))
                    
                }
            }
            
            describe("when calling sendPasswordRecoveryEmail(for:appId:platformId:)") {
                
                it("should POST the expected request") {
                    
                    let credentialId = "foo@bar.com"
                    let pathAllowedCredentialId = credentialId.pathAllowedURLEncodedString!
                    let appId = "my.sooper.app"
                    let base64EncodedAppId = "\(appId):IOS".bytes.toBase64()
                    let path = "/v1/credentials/\(pathAllowedCredentialId)/passwordReset"
                    
                    stub(condition: isPath(path) && isMethodPOST() && hasHeaderNamed("x-afero-app", value: base64EncodedAppId)) {
                        _ in
                        OHHTTPStubs.HTTPStubsResponse(jsonObject: [], statusCode: 204, headers: [:])
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    _ = apiClient.sendPasswordRecoveryEmail(for: credentialId, appId: appId)
                        .then {
                            response = $0
                    }
                    .catch {
                        error = $0
                    }
                    
                    expect(response).toEventuallyNot(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    
                }
            }
            
            describe("when calling updatePassword(with:shortCode:appId:platformId:)") {
                
                it("should POST the expected request") {
                    
                    let shortCode = "31337".pathAllowedURLEncodedString!
                    let appId = "my.sooper.app"
                    let base64EncodedAppId = "\(appId):IOS".bytes.toBase64()
                    let password = "newPassword"
                    
                    let path = "/v1/shortvalues/\(shortCode)/passwordReset"
                    
                    stub(condition: isPath(path) && isMethodPOST() && hasHeaderNamed("x-afero-app", value: base64EncodedAppId) && {
                        req in
                        let data = req.ohhttpStubs_httpBody
                        let body = try? JSONSerialization.jsonObject(with: data!, options: [])
                        return ((body as? [String: Any])?["password"] as? String) == password
                    }) {
                        _ in
                        OHHTTPStubs.HTTPStubsResponse(jsonObject: [], statusCode: 204, headers: [:])
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    _ = apiClient.updatePassword(with: password, shortCode: shortCode, appId: appId)
                        .then {
                            response = $0
                    }
                    .catch {
                        error = $0
                    }
                    
                    expect(response).toEventuallyNot(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    
                }
            }
            
            describe("when calling updatePassword(password:credentialId:accountId:)") {
                
                it("should POST the expected request") {
                    
                    let credentialId = "foo@bar.com".pathAllowedURLEncodedString!
                    let accountId = "myAccountId"
                    let password = "newPassword"
                    
                    let path = "/v1/accounts/\(accountId)/credentials/\(credentialId)/password"
                    
                    stub(condition: isPath(path) && isMethodPUT() && {
                        req in
                        let data = req.ohhttpStubs_httpBody
                        let body = try? JSONSerialization.jsonObject(with: data!, options: [])
                        return ((body as? [String: Any])?["password"] as? String) == password
                    }) {
                        _ in
                        OHHTTPStubs.HTTPStubsResponse(jsonObject: [], statusCode: 204, headers: [:])
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    _ = apiClient.updatePassword(with: password, credentialId: credentialId, accountId: accountId)
                        .then {
                            response = $0
                    }
                    .catch {
                        error = $0
                    }
                    
                    expect(response).toEventuallyNot(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    
                }
            }
            
            describe("when calling resendVerificationToken") {
                it("should POST the expected request.") {
                    
                    let accountId = "jarjar"
                    let credentialId = "foo@bar.com".pathAllowedURLEncodedString!
                    let appId = "my.sooper.app"
                    let base64EncodedAppId = "\(appId):IOS".bytes.toBase64()

                    
                    let path = "/v1/accounts/\(accountId)/credentials/\(credentialId)/resendVerification"
                    
                    stub(condition: isPath(path) && isMethodPOST() && hasHeaderNamed("x-afero-app", value: base64EncodedAppId) && {
                        req in
                        let data = req.ohhttpStubs_httpBody
                        let body = try? JSONSerialization.jsonObject(with: data!, options: [])
                        return ((body as? [String: Any])?["credentialId"] as? String) == credentialId
                    }) {
                        _ in
                        OHHTTPStubs.HTTPStubsResponse(jsonObject: [:], statusCode: 201, headers: [:])
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    _ = apiClient.resendVerificationToken(for: credentialId, accountId: accountId, appId: appId)
                        .then {
                            response = $0
                    }
                    .catch {
                        error = $0
                    }
                    
                    expect(response).toEventuallyNot(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    
                }
            }
            
            describe("when calling createAccount") {
                it("should POST the expected request.") {
                    
                    let credentialId = "foo@bar.com".pathAllowedURLEncodedString!
                    let password = "password"
                    let firstName = "Robbie"
                    let lastName = "Robot"
                    let credentialType = "email"
                    let verified = true
                    let accountType = "PARTNER"
                    let accountDescription = "My Special Account"

                    let appId = "my.sooper.app"
                    let base64EncodedAppId = "\(appId):IOS".bytes.toBase64()
                    
                    
                    let path = "/v1/accounts"
                    
                    stub(condition: isPath(path) && isMethodPOST() && hasHeaderNamed("x-afero-app", value: base64EncodedAppId) && {
                        req in
                        let data = req.ohhttpStubs_httpBody
                        guard let body = (try? JSONSerialization.jsonObject(with: data!, options: [])) as? [String: Any] else {
                            return false
                        }
                        
                        guard let credential = body["credential"] as? [String: Any] else {
                            return false
                        }
                        
                        guard credential["credentialId"] as! String == credentialId else {
                            return false
                        }
                        
                        guard credential["password"] as! String == password else {
                            return false
                        }
                        
                        guard credential["type"] as! String == credentialType else {
                            return false
                        }
                        
                        guard credential["verified"] as! Bool == verified else {
                            return false
                        }
                        
                        guard let user = body["user"] as? [String: String] else {
                            return false
                        }
                        
                        guard user["firstName"] == firstName else {
                            return false
                        }
                        
                        guard user["lastName"] == lastName else {
                            return false
                        }

                        guard let account = body["account"] as? [String: String] else {
                            return false
                        }
                        
                        guard account["type"] == accountType else {
                            return false
                        }
                        
                        guard account["description"] == accountDescription else {
                            return false
                        }
                        
                        return true
                        
                    }) {
                        _ in
                        OHHTTPStubs.HTTPStubsResponse(jsonObject: [:], statusCode: 201, headers: [:])
                    }
                    
                    var response: Any?
                    var error: Error?
                    
                    _ = apiClient.createAccount(
                        credentialId,
                        password: password,
                        firstName: firstName,
                        lastName: lastName,
                        credentialType: credentialType,
                        verified: verified,
                        accountType: accountType,
                        accountDescription: accountDescription,
                        appId: appId
                        ).then {
                            response = $0
                        }
                        .catch {
                            error = $0
                    }
                    
                    expect(response).toEventuallyNot(beNil(), timeout: DispatchTimeInterval.seconds(5))
                    expect(error != nil).toNotEventually(beTrue(), timeout: DispatchTimeInterval.seconds(5))
                    
                }
            }

            
        }
    }
}
