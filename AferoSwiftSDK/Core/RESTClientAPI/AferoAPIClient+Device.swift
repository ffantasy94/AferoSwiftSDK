//
//  APIClient+Device.swift
//  Pods
//
//  Created by Justin Middleton on 7/7/17.
//
//

import Foundation
import PromiseKit
import CoreLocation

public extension AferoAPIClientProto {
    
    // MARK: - Association / Disassociation -
    
    /// Associate a device.
    ///
    ///  - parameter accountId: the accountId to which to associate the device.
    ///
    ///  - parameter associationId: the serial number of the device, acquired
    ///                             manually or through QR code scan.
    ///
    ///  - parameter location: the current location of the device.
    ///
    ///  - returns: A `Promise<[String: Any]>`
    
    @available(*, deprecated, message: "Use associateDevice(with:to:locatedAt:ownershipTransferVerified) instead")
    public func associateDevice(_ accountId: String, associationId: String, location: CLLocation? = nil, verified: Bool = false) -> Promise<[String: Any]> {
        
        return associateDevice(with: associationId, to: accountId, locatedAt: location, ownershipTransferVerified: verified)
        
    }
    
    /// Associate a device to an Afero account.
    ///
    /// Associating a device to an Afero account makes the device available to members
    /// of that account, and also enables hardware and mobile software-based hubs on that
    /// account to connect to the device.
    ///
    /// A device can only be associated with one account at a time.
    ///
    ///  - parameter associationId: the serial number of the device, acquired
    ///                             manually or through QR code scan.
    ///
    ///  - parameter accountId: the accountId to which to associate the device.
    ///
    ///  - parameter location: the current location of the device.
    ///
    ///  - parameter ownershipTransferVerified: For devices for which ownership transfer
    ///                                         is allowed, this tells the API that the
    ///                                         user has verified that ownership should transfer.
    ///
    ///  - returns: A `Promise<[String: Any]>`
    
    public func associateDevice(with associationId: String, to accountId: String, locatedAt location: CLLocation? = nil, ownershipTransferVerified verified: Bool = false) -> Promise<[String: Any]> {
        
        var deviceData : [String: Any] = [
            "associationId": associationId,
            ]
        
        if let location = location {
            
            let deviceLocation = DeviceLocation(
                location: location,
                sourceType: .initialDeviceAssociate
            )
            
            deviceData["location"] = deviceLocation.JSONDict!
        }
        
        var additionalParams = AferoAppEnvironment.scaleAndLocale
        if verified {
            additionalParams["verified"] = "true"
        }
        
        return POST("/v1/accounts/\(accountId)/devices", parameters: deviceData, expansions: ["state", "profile"], additionalParams: additionalParams)
    }
    
    /// Device Info With Extended Data
    ///
    /// - parameter accountId: The accountId to which the device belongs.
    /// - parameter deviceId: The UUID of the device.
    
    @available(*, deprecated, message: "Use removeDevice(with deviceId: String, in accountId: String) instead)")
    public func getExtendedDeviceInfo(_ accountId: String, deviceId: String) -> Promise<Any> {
        return getExtendedDeviceInfo(for: deviceId, in: accountId)
    }

    /// Device Info With Extended Data
    ///
    /// - parameter deviceId: The UUID of the device.
    /// - parameter accountId: The accountId to which the device belongs.
    
    public func getExtendedDeviceInfo(for deviceId: String, in accountId: String) -> Promise<Any> {
        return GET("/v1/accounts/\(accountId)/devices/\(deviceId)", expansions: ["extendedData"])
    }

    /// Remove a device.
    ///
    /// - parameter accountId: The accountId to which the device belongs.
    /// - parameter deviceId: The UUID of the device to remove.

    @available(*, deprecated, message: "Use removeDevice(with deviceId: String, in accountId: String) instead)")
    public func removeDevice(_ accountId: String, deviceId: String) -> Promise<Void> {
        return removeDevice(with: deviceId, in: accountId)
    }

    /// Remove a device.
    ///
    /// - parameter deviceId: The UUID of the device to remove.
    /// - parameter accountId: The accountId to which the device belongs.
    
    public func removeDevice(with deviceId: String, in accountId: String) -> Promise<Void> {
        return DELETE("/v1/accounts/\(accountId)/devices/\(deviceId)")
    }

}

// MARK: - Device Location -

public extension AferoAPIClientProto {
    
    @available(*, deprecated, message: "Use getLocation(for:in:) instead.")
    public func getLocation(_ accountId: String, forDeviceId deviceId: String) -> Promise<LocationModel?> {
        return getLocation(for: deviceId, in: accountId)
    }
    
    /// Get the last known location of a device.
    ///
    /// - parameter deviceId: The id of the device for which to fetch location.
    /// - parameter accountId: The id of the account to which the device is associated.
    /// - returns: A Promise<DeviceLocation?>. Resolves to `.some(DeviceLocation)` if the device has
    ///            a set location, and `.none` if not.
    
    public func getLocation(for deviceId: String, in accountId: String) -> Promise<DeviceLocation?> {
        
        guard
            let safeDeviceId = deviceId.pathAllowedURLEncodedString,
            let safeAccountId = accountId.pathAllowedURLEncodedString else {
                return Promise { _, reject in reject("Unable to escape deviceId or accountId") }
        }
        
        return GET("/v1/accounts/\(safeAccountId)/devices/\(safeDeviceId)/location")
    }
    
    /// Set the location of a device.
    /// - parameter location: The new location of the device.
    /// - parameter deviceId: The id of the device to locate.
    /// - parameter accountId: The id of the account to which the device is associated.
    /// - returns: A Promise<DeviceLocation?> that resolves to the given parameters upon success.
    
    public func setLocation(
        as location: DeviceLocation?,
        for deviceId: String,
        in accountId: String
        ) -> Promise<Void> {
        
        guard let location = location else {
            return Promise {
                _, reject in reject("Nil locations are currently unsupported.")
            }
        }
        
        guard
            let safeDeviceId = deviceId.pathAllowedURLEncodedString,
            let safeAccountId = accountId.pathAllowedURLEncodedString else {
                return Promise { _, reject in reject("Unable to escape deviceId or accountId") }
        }
        
        return PUT("/v1/accounts/\(safeDeviceId)/devices/\(safeAccountId)/location", object: location)
    }
    
    @available(*, deprecated, message: "Use setLocation(as:with:formattedAddressLines:for:in:) instead.")
    public func setLocation(_ accountId: String, location: CLLocation, forDeviceId deviceId: String, locationSourceType: LocationSourceType, formattedAddressLines: [String]? = nil) -> Promise<Void> {
        return setLocation(as: location, with: locationSourceType, formattedAddressLines: formattedAddressLines, for: deviceId, in: accountId)
    }
    
    public func setLocation(as location: CLLocation, with sourceType: DeviceLocation.SourceType, formattedAddressLines: [String]? = nil, for deviceId: String, in accountId: String) -> Promise<Void> {
        
        let location = DeviceLocation(
            location: location,
            sourceType: sourceType,
            formattedAddressLines: formattedAddressLines
        )
        
        return setLocation(as: location, for: deviceId, in: accountId)
    }
    
}

