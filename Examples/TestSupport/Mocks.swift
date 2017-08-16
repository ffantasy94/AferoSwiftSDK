//
//  Mocks.swift
//  iTokui
//
//  Created by Justin Middleton on 6/6/17.
//  Copyright © 2017 Kiban Labs, Inc. All rights reserved.
//

import Foundation
import OHHTTPStubs
import ReactiveSwift
import HTTPStatusCodes

@testable import Afero


// MARK: - MockDeviceBatchActionRequestable

class MockDeviceBatchActionRequestable: DeviceBatchActionRequestable {
    
    var resultsToReturn: DeviceBatchAction.Results?
    var errorToReturn: Error?
    
    var writeWasInvoked: Bool = false
    
    func post(actions: [DeviceBatchAction.Request], forDeviceId deviceId: String, withAccountId accountId: String, onDone: @escaping WriteAttributeOnDone) {
        writeWasInvoked = true
        onDone(resultsToReturn, errorToReturn)
    }
    
}

// MARK: - MockDeviceAccountProfileSource

class MockDeviceAccountProfilesSource: DeviceAccountProfilesSource {
    
    var errorToReturn: Error?
    var profileToReturn: DeviceProfile?
    
    var fetchCompleteBlock: (()->())?
    
    var fetchProfileByProfileIdRequestCount: Int = 0
    func fetchProfile(accountId: String, profileId: String, onDone: @escaping FetchProfileOnDone) {
        
        self.fetchProfileByProfileIdRequestCount += 1
        
        DispatchQueue.global(qos: .userInitiated).async {
            
            [weak self] in
            
            if let errorToReturn = self?.errorToReturn {
                onDone(nil, errorToReturn)
            } else {
                onDone(self?.profileToReturn, nil)
            }
            
            self?.fetchCompleteBlock?()
            
        }
        
    }
    
    var fetchProfileByDeviceIdRequestCount: Int = 0
    func fetchProfile(accountId: String, deviceId: String, onDone: @escaping FetchProfileOnDone) {
        
        fetchProfileByDeviceIdRequestCount += 1
        
        DispatchQueue.global(qos: .userInitiated).async {
            
            [weak self] in
            
            if let errorToReturn = self?.errorToReturn {
                onDone(nil, errorToReturn)
            } else {
                onDone(self?.profileToReturn, nil)
            }
            
            self?.fetchCompleteBlock?()
            
        }
    }
    
    var accountProfilesToReturn: [String: [DeviceProfile]] = [:]
    var fetchProfilesByAccountIdRequestCount: Int = 0
    
    func fetchProfiles(accountId: String, onDone: @escaping FetchProfilesOnDone) {
        
        fetchProfilesByAccountIdRequestCount += 1
        
        DispatchQueue.global(qos: .userInitiated).async {
            
            [weak self] in
            
            if let errorToReturn = self?.errorToReturn {
                onDone(nil, errorToReturn)
            } else {
                onDone(self?.accountProfilesToReturn[accountId], nil)
            }
            
            self?.fetchCompleteBlock?()
            
        }
    }
    
    
}

// MARK: - MockDeviceCollectionDelegate

/// Mock class for testing consumers of `DeviceCollectionDelegate`.

//class MockDeviceCollectionDelegate: DeviceCollectionDelegate {
//    
//    convenience init(traceEnabledAccounts: [String] = [], shouldStartAccounts: [String] = []) {
//        self.init()
//        traceEnabledAccounts.forEach { traceTable[$0] = true }
//        shouldStartAccounts.forEach { shouldStartTable[$0] = true }
//    }
//    
//    var traceTable: [String: Bool] = [:]
//    
//    func setTraceEnabled(_ enabled: Bool, for accountId: String) {
//        traceTable[accountId] = enabled
//    }
//    
//    func clearTraceTable() { traceTable.removeAll() }
//    
//    var isTraceEnabledCallCount: Int = 0
//    
//    func isTraceEnabled(for accountId: String) -> Bool {
//        isTraceEnabledCallCount += 1
//        return traceTable[accountId] ?? false
//    }
//    
//    var shouldStartTable: [String: Bool] = [:]
//    
//    func setShouldStart(_ shouldStart: Bool, for deviceCollection: DeviceCollection) {
//        shouldStartTable[deviceCollection.accountId] = shouldStart
//    }
//    
//    func clearShouldStartTable() { shouldStartTable.removeAll() }
//    
//    var shouldStartCallCount: Int = 0
//    
//    func deviceCollectionShouldStart(_ deviceCollection: DeviceCollection) -> Bool {
//        shouldStartCallCount += 1
//        return shouldStartTable[deviceCollection.accountId] ?? false
//    }
//    
//}

// MARK: - MockDeviceEventStreamable

class MockDeviceEventStreamable: DeviceEventStreamable {
    
    var clientId: String
    var accountId: String
    
    init(clientId: String, accountId: String) {
        self.clientId = clientId
        self.accountId = accountId
    }
    
    /// The pipe which casts `DeviceStreamEvent`s.
    lazy private final var eventPipe: DeviceStreamEventPipe = {
        return DeviceStreamEventSignal.pipe()
    }()
    
    /// The `Signal` on which `DeviceStreamEvent`s can be received.
    var eventSignal: DeviceStreamEventSignal? {
        return eventPipe.0
    }
    
    /**
     The `Sink` to which `DeviceStreamEvent`s are broadcast.
     */
    
    var eventSink: DeviceStreamEventSink {
        return eventPipe.1
    }
    
    private(set) var isStarted: Bool = false
    var startError: Error?
    var isTraceEnabled: Bool = false
    
    func start(_ trace: Bool, onDone: @escaping (Error?) -> ()) {
        isTraceEnabled = trace
        isStarted = true
        onDone(startError)
    }
    
    func stop() {
        isStarted = false
    }
    
    func publishDeviceListRequest() { /* do nothing; for proto conformance */ }
    
    var isViewingSet: Set<String> = []
    
    func publishIsViewingNotification(_ isViewing: Bool, deviceId: String) {
        
        guard isViewing else {
            isViewingSet.remove(deviceId)
            return
        }
        
        isViewingSet.insert(deviceId)
    }
    
    var lastMetrics: DeviceEventStreamable.Metrics?
    
    func publish(metrics: DeviceEventStreamable.Metrics) {
        lastMetrics = metrics
    }

}

class MockAPIClient: AferoAPIClientProto {

    // We stub out all of our calls using OHHTTPStubs, so we'll go through a real
    // client, and just wrap those calls to inspect things like call verification
    // where necessary.
    
    private var realClient = AFNetworkingAferoAPIClient(
        config: AFNetworkingAferoAPIClient.Config(
            oauthClientId: "mockClient123",
            oauthClientSecret: "mockClient789"
        )
    )
    
    // MARK: Testy Bits
    
    private(set) var refreshOauthCount: Int = 0
    func clearRefreshOauthCount() {
        refreshOauthCount = 0
    }

    private(set) var signOutCount: Int = 0
    func clearSignOutCount() {
        signOutCount = 0
    }

    // MARK: <APIClientProto>
    
    func doRefreshOAuth(passthroughError: Error?, success: @escaping () -> Void, failure: @escaping (Error) -> Void) {
        refreshOauthCount += 1
        realClient.doRefreshOAuth(passthroughError: passthroughError, success: success, failure: failure)
    }
    
    func doSignOut(error: Error?, completion: @escaping () -> Void) {
        signOutCount += 1
        realClient.doSignOut(error: error, completion: completion)
    }
    
    func doPut(urlString: String, parameters: Any?, success: @escaping AferoAPIClientProto.AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProto.AferoAPIClientProtoFailure) -> URLSessionDataTask? {
        return realClient.doPut(urlString: urlString, parameters: parameters, success: success, failure: failure)
    }
    
    func doPost(urlString: String, parameters: Any?, success: @escaping AferoAPIClientProto.AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProto.AferoAPIClientProtoFailure) -> URLSessionDataTask? {
        return realClient.doPost(urlString: urlString, parameters: parameters, success: success, failure: failure)
    }
    
    func doGet(urlString: String, parameters: Any?, success: @escaping AferoAPIClientProto.AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProto.AferoAPIClientProtoFailure) -> URLSessionDataTask? {
        return realClient.doGet(urlString: urlString, parameters: parameters, success: success, failure: failure)
    }
    
    func doDelete(urlString: String, parameters: Any?, success: @escaping AferoAPIClientProto.AferoAPIClientProtoSuccess, failure: @escaping AferoAPIClientProto.AferoAPIClientProtoFailure) -> URLSessionDataTask? {
        return realClient.doDelete(urlString: urlString, parameters: parameters, success: success, failure: failure)
    }
}


