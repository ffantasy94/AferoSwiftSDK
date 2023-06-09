//
//  OfflineSchedule.swift
//  iTokui
//
//  Created by Justin Middleton on 10/3/16.
//  Copyright © 2016 Kiban Labs, Inc. All rights reserved.
//

import Foundation
import CocoaLumberjack
import PromiseKit
import ReactiveSwift

public protocol OfflineScheduleStorage: class {
    
    func set(attributes: [AttributeInstance]) -> Promise<DeviceBatchAction.Results>
    func set(value: AttributeValue, forAttributeId attributeId: Int) -> Promise<DeviceBatchAction.Results>
    func valueForAttributeId(_ attributeId: Int) -> AttributeValue?
    var supportsOfflineSchedules: Bool { get }
    var displayName: String { get }
    var writableAttributes: Set<DeviceProfile.AttributeDescriptor> { get }
    var writableAttributeIds: Set<Int> { get }
    var readableAttributes: Set<DeviceProfile.AttributeDescriptor> { get }
    var readableAttributeIds: Set<Int> { get }
    func eventSignalForAttributeIds<A: Sequence>(_ attributeIds: A?) -> AttributeEventSignal? where A.Iterator.Element == Int
    var types: [Int: DeviceProfile.AttributeDescriptor.DataType] { get }
    
    var offlineScheduleFlags: OfflineSchedule.Flags { get }
    var timeZone: TimeZone? { get }
    func setOfflineScheduleFlags(_ flags: OfflineSchedule.Flags) -> Promise<OfflineSchedule.Flags>
    
}

extension DeviceModelable {

    public var supportsOfflineSchedules: Bool {
        return !writableAttributeIds.intersection(OfflineSchedule.EventAttributeIds).isEmpty
    }
    
    public var types: [Int: DeviceProfile.AttributeDescriptor.DataType] {
        return profile?.attributes.reduce([:]) {
            curr, next in
            var ret = curr
            ret?[next.0] = next.1.dataType
            return ret
            } ?? [:]
    }
    
    public var offlineScheduleFlags: OfflineSchedule.Flags {
        return OfflineSchedule.Flags(rawValue: valueForAttributeId(OfflineSchedule.FlagsAttributeId)?.suited() ?? 0)
    }
    
    public func setOfflineScheduleFlags(_ flags: OfflineSchedule.Flags) -> Promise<OfflineSchedule.Flags> {

        let value: AttributeValue = .signedInt16(flags.rawValue)
        
        return
            set(value: value, forAttributeId: OfflineSchedule.FlagsAttributeId)
            .then {
                _ in return OfflineSchedule.Flags(rawValue: value.suited() ?? 0)
        }
        
    }
    
    /// If this `DeviceModelable` supports offline schedules, then this returns an
    /// offline schedule instance. Otherwise, returns nil.
    /// - parameter collator: An `OfflineScheduleCollator` instance. If omitted, defaults to
    ///                       a `DefaultOfflineScheduleCollator` instance.
    
    public func offlineSchedule(with collator: OfflineScheduleCollator =  DefaultOfflineScheduleCollator()) -> OfflineSchedule? {
        guard supportsOfflineSchedules else {
            return nil
        }
        
        return OfflineSchedule(storage: self)
    }

}

public extension DeviceRule.Schedule {
    
 var firstDayOfWeek: DateTypes.DayOfWeek? {
        return dayOfWeek.sorted().first
    }
}

public extension OfflineSchedule {

    /// See [the Afero attribute registry](http://wiki.afero.io/display/FIR/Device+Attribute+Registry).
 static var FlagsAttributeId: Int {
        return 59001
    }
    
 static let EventAttributeIds = Set(Array(59002...59999))
    
}

/// Responsible for providing a sorted "view" on an offline schedule
public protocol OfflineScheduleCollator {
    func numberOfOfflineScheduleEvents(_ schedule: OfflineSchedule) -> Int
    func attributeIdForIndex(_ schedule: OfflineSchedule, index: Int) throws -> Int
    func deltas(_ before: [OfflineSchedule.ScheduleEvent], after: [OfflineSchedule.ScheduleEvent]) -> OfflineScheduleIndexDeltas
    func scheduleEvents(_ schedule: OfflineSchedule) -> [OfflineSchedule.ScheduleEvent]
    func isOrderedBefore(_ lhs: OfflineSchedule.ScheduleEvent, rhs: OfflineSchedule.ScheduleEvent) -> Bool
}

public extension OfflineScheduleCollator {
    
    func attributeIdForIndex(_ schedule: OfflineSchedule, index: Int) throws -> Int {
        
        guard index < schedule.attributeIds.count else {
            throw "index \(index) out of bounds (max \(schedule.attributeIds.count - 1)"
        }
        
        let collatedAttributeIds = schedule.attributeIdEventMap.sorted {
            self.isOrderedBefore($0.1, rhs: $1.1)
        }
        
        return collatedAttributeIds[index].0
        
    }
    
    func isOrderedBefore(_ lhs: OfflineSchedule.ScheduleEvent, rhs: OfflineSchedule.ScheduleEvent) -> Bool { return lhs < rhs }
    
    func deltas(_ before: [OfflineSchedule.ScheduleEvent], after: [OfflineSchedule.ScheduleEvent]) -> OfflineScheduleIndexDeltas {
        
        let deletions = NSMutableIndexSet()
        let insertions = NSMutableIndexSet()
        
        let afterSet = Set(after)
        before.enumerated().forEach {
            idx, elem in
            if !afterSet.contains(elem) {
                deletions.add(idx)
            }
        }
        
        let beforeSet = Set(before)
        after.enumerated().forEach {
            idx, elem in
            if !beforeSet.contains(elem) {
                insertions.add(idx)
            }
        }
        
        return (deletions: deletions as IndexSet, insertions: insertions as IndexSet)
        
    }
    
    func scheduleEvents(_ schedule: OfflineSchedule) -> [OfflineSchedule.ScheduleEvent] {
        return schedule.attributeIdEventMap.values.sorted()
    }
    
    func numberOfOfflineScheduleEvents(_ schedule: OfflineSchedule) -> Int {
        return schedule.attributeIdEventMap.count
    }
    
}

public typealias OfflineScheduleIndexDeltas = (deletions: IndexSet, insertions: IndexSet)

public class DefaultOfflineScheduleCollator: OfflineScheduleCollator {
    public init() {}
}

// MARK: Public Interface

extension OfflineSchedule {
    
    public var numberOfEvents: Int { return collatedEvents.count }
    
    public func eventIndex(for event: OfflineSchedule.ScheduleEvent) -> Int? {
        #if compiler(>=5)
        return collatedEvents.firstIndex(of: event)
        #endif
        #if !compiler(>=5)
        return collatedEvents.index(of: event)
        #endif
    }
    
    func attributeId(for event: OfflineSchedule.ScheduleEvent) -> Int? {
        return attributeIdEventMap.filter { $0.value == event }.first?.key
    }
    
    public func scheduleEvent(_ index: Int) -> OfflineSchedule.ScheduleEvent {
        return event(index)
    }

    /// Remove an event at the given index as per the collator.
    /// - parameter index: the collator-index of the event to remove.
    /// - parameter commit: If true (the default), will automatically commit the attribute.
    /// - returns: A `Promise<Set<Int>>`, which resolves to a set containing the
    ///            `attributeId` of the uncommitted attribute, if any.
    /// - note: If `commit == true`, then the promise will resolve to an empty set,
    ///         since there's nothing remaining to commit.
    
    @discardableResult
    public func removeScheduleEvent(atIndex index: Int, commit: Bool = true) -> Promise<Set<Int>> {
        
        do {
            
            let attributeId = try collator.attributeIdForIndex(self, index: index)
            
            DDLogDebug("Removing event at attributeId \(attributeId)", tag: TAG)
            removeEvent(attributeId)

            if commit {
                DDLogDebug("Commit requested for remove; autocommitting attrId \(attributeId)", tag: TAG)
                return commitEvents(forAttributeIds: [attributeId])
                    .then {
                        _ in return Set()
                }
            }
            
            DDLogDebug("Skipping autocommit; returning \(attributeId) for manual remove commit", tag: TAG)
            return Promise { fulfill, _ in fulfill([attributeId]) }
            
        } catch {
            return Promise { _, reject in reject(error) }
        }
    }
    
    /// Remove an event at the given index as per the collator.
    /// - parameter event: The event to remove.
    /// - parameter commit: If true (the default), will automatically commit the attribute.
    /// - returns: A `Promise<Set<Int>>`, which resolves to a set containing the
    ///            `attributeId` of the uncommitted attribute, if any.
    /// - note: If `commit == true`, then the promise will resolve to an empty set,
    ///         since there's nothing remaining to commit.
    
    public func removeScheduleEvent(_ event: OfflineSchedule.ScheduleEvent, commit: Bool = true) -> Promise<Set<Int>> {
        
        guard let index = eventIndex(for: event) else {
            DDLogDebug("No event matching given event; bailing remove (event: \(String(describing: event))", tag: TAG)
            return Promise { fulfill, _ in fulfill([]) }
        }
        
        return removeScheduleEvent(atIndex: index, commit: commit)
    }
    
    /// Add an event. Promise reject called if there's no more room.
    /// - parameter event: the event to add.
    /// - parameter commit: If true (the default), will automatically commit the attribute, if any changes were made.
    /// - returns: A `Promise<Set<Int>>`, which resolves to a set containing the
    ///            `attributeId` of the uncommitted attribute, if any.
    /// - note: The promise will resolve to an empty set if either of the following conditions are met:
    ///         1. `commit == true`.
    ///         2. No actual changes were made, because the even matches an existing event.
    
    @discardableResult
    public func addScheduleEvent(_ event: OfflineSchedule.ScheduleEvent, commit: Bool = true) -> Promise<Set<Int>> {
        
        do {
            
            if attributeIdEventMap.values.contains(event) {
                DDLogDebug("Duplicate event being added; bailing (event: \(String(describing: event))", tag: TAG)
                return Promise { fulfill, _ in fulfill(Set()) }
            }
            
            guard let attributeId = unusedAttributeIds.sorted().first else {
                throw "Maximum number of events reached."
            }
            
            setEvent(event: event, forAttributeId: attributeId)

            if commit {
                DDLogDebug("Commit requested; committing attributeIds \(String(describing: [attributeId]))", tag: TAG)
                return commitEvents(forAttributeIds: [attributeId])
                    .then { _ in return Set() }
            }
            
            DDLogDebug("Skipping autocommit; returning \(attributeId) for manual add commit", tag: TAG)
            return Promise { fulfill, _ in fulfill([attributeId]) }
            
        } catch {
            return Promise { _, reject in reject(error) }
        }
    }
    
    /// Add a collection of `OfflineSchedule.ScheduleEvent`s.
    /// - parameter events: The events to add.
    /// - parameter commit: If true, commit automatically
    /// - returns: A `Promise<Set<Int>>`, which resolves to a set containing the
    ///            `attributeId` of uncommitted attributes, if any.
    /// - warning: If any of the adds fail (e.g. due to capacity), autocommit is cancelled,
    ///            but successful uncommitted changes to the schedule will persist.
    
    public func addScheduleEvents<T>(_ events: T, commit: Bool = true) -> Promise<Set<Int>>
        where T: Collection, T.Iterator.Element == OfflineSchedule.ScheduleEvent {
        
            let promises = events.map {
                event in addScheduleEvent(event, commit: false)
            }
            
            return when(fulfilled: promises)
                .then {
                    
                    (results: [Set<Int>]) -> Set<Int> in
                    DDLogDebug("Merging addScheduleEvent results: \(String(describing: results))", tag: self.TAG)
                    return results.reduce ([]) {
                        curr, next in
                        var ret = curr
                        ret.formUnion(next)
                        return ret
                    }
                    
                }.then {
                    
                    commitIds -> Promise<Set<Int>> in

                    DDLogDebug("Merged addScheduleEvent results: \(String(describing: commitIds))", tag: self.TAG)
                    guard commit else {
                        DDLogDebug("Skipping autocommit; returning \(String(describing: commitIds)) for manual commit.", tag: self.TAG)
                        return Promise { fulfill, _ in fulfill(commitIds) }
                    }
                    
                    DDLogDebug("Autocommiting attributeIds \(String(describing: commitIds))", tag: self.TAG)
                    return self.commitEvents(forAttributeIds: commitIds).then {
                        instances in
                        return Promise { fulfill, _ in fulfill(Set(instances.map { $0.id })) }
                    }
            }
    }
    
    public typealias ReplaceEventResult = (oldEvent: OfflineSchedule.ScheduleEvent, newEvent: OfflineSchedule.ScheduleEvent, attributeId: Int)
    
    public typealias EventReplacement = (oldEvent: OfflineSchedule.ScheduleEvent, newEvent: OfflineSchedule.ScheduleEvent)

    
    /// Replace one event with another, essentially "updating" the event.
    /// - parameter oldEvent: The event to replace
    /// - parameter newEvent: The replacement event
    /// - parameter commit: If true, automatically commit results. If false, do not, and have the returned
    ///                     promise resolve the attributeIds that need to be committed.
    
    public func replaceScheduleEvent(_ oldEvent: OfflineSchedule.ScheduleEvent, with newEvent: OfflineSchedule.ScheduleEvent, commit: Bool = true) -> Promise<ReplaceEventResult> {
        
        guard let attributeIdForOldEvent = attributeId(for: oldEvent) else {
            let msg = "No attributeId for event \(String(describing: oldEvent)); bailing."
            DDLogWarn(msg, tag: TAG)
            return Promise { _, reject in reject(msg) }
        }
        
        let ret = (oldEvent: oldEvent, newEvent: newEvent, attributeId: attributeIdForOldEvent)
        
        if oldEvent == newEvent {
            DDLogDebug("Replacing old event with equivalent event; no work to do (oldEvent: \(String(describing: oldEvent)) newEvent: \(String(describing: newEvent)))", tag: TAG)
            return Promise { fulfill, _ in fulfill(ret) }
        }
        
        self.setEvent(event: newEvent, forAttributeId: attributeIdForOldEvent)
        
        guard commit else {
            DDLogDebug("Skipping autocommit; returning \(attributeIdForOldEvent) for manual replace commit", tag: TAG)
            return Promise { fulfill, _ in fulfill(ret) }
        }
            
        DDLogDebug("Commit requested; committing attributeIds \(String(describing: [attributeIdForOldEvent]))", tag: TAG)
        return commitEvents(forAttributeIds: [attributeIdForOldEvent])
            .then {
                _ in return ret
        }

    }
    
    /// Replace the event at the given event index with a new event.
    /// - parameter index: The eventIndex of the event to replace
    /// - parameter newEvent: The replacement event
    /// - parameter commit: If true, automatically commit results. If false, do not, and have the returned
    ///                     promise resolve the attributeIds that need to be committed.
    
    public func replaceScheduleEvent(at index: Int, with newEvent: OfflineSchedule.ScheduleEvent, commit: Bool = true) -> Promise<ReplaceEventResult> {
        return replaceScheduleEvent(event(index), with: newEvent, commit: commit)
    }
    
    /// Perform a series of of event replacements.
    ///
    /// - parameter replacements: A `Collection` of `EventReplacement` instances.
    ///             Each of these will be performed; unsuccessful results
    ///             will be filtered out.
    ///
    /// - parameter commit: If true, automatically commit after completion. If false,
    ///                     do not commit changes.
    
    public func performReplacements<T: Collection> (_ replacements: T, commit: Bool = true) -> Promise<[ReplaceEventResult]> where T.Iterator.Element == EventReplacement {
        
        
        return when(resolved: replacements.map {
            (oldEvent, newEvent) -> Promise<ReplaceEventResult> in
            return replaceScheduleEvent(oldEvent, with: newEvent, commit: false)
            }
            ).then {
                results -> [ReplaceEventResult] in
                return results.compactMap {
                    result in switch result {
                    case .fulfilled(let replaceResult): return replaceResult
                    case .rejected: return nil
                    }
                }
            }.then {
                results -> Promise<[ReplaceEventResult]> in
                
                guard commit else {
                    return Promise { fulfill, _ in fulfill(results) }
                }
                
                return self.commitEvents(forAttributeIds: results.map { $0.attributeId})
                    .then {
                        _ -> [ReplaceEventResult] in return results
                }
        }
        
    }
    
    /// Pairwise replace events in `oldEvents` with those in `newEvents`.
    ///
    /// - parameter oldEvents: A `Collection` of `OfflineScheduleEvent`s which will
    ///             be replaced.
    ///
    /// - parameter newEvents: A `Collection` of `OfflineScheduleEvent`s which will replace
    ///             those in `oldEvents`.
    ///
    /// - parameter commit: If true, automatically commit after completion. If false,
    ///                     do not commit changes.
    
    func replace<T: Collection>(oldEvents: T, with newEvents: T, commit: Bool = false) -> Promise<[ReplaceEventResult]> where T.Iterator.Element == OfflineSchedule.ScheduleEvent {
        
        guard oldEvents.count == newEvents.count else {
            let msg = "Number of oldEvents must equal number of new events; oldEvents.count == \(oldEvents.count); newEvents.count == \(newEvents.count)"
            DDLogError(msg, tag: TAG)
            return Promise { _, reject in reject(msg) }
        }
        
        return performReplacements(
            Array(zip(oldEvents, newEvents).map {
                return (oldEvent: $0, newEvent: $1)
            }),
            commit: commit
        )
    }
    
    /// Commit schedule events identified by event index (as per the collator).
    /// - parameter forEventIds: A `Sequence` of `eventIds` referencing the events
    ///                          to commit.
    
    public func commitEvents<T>(forEventIds eventIds: T?) -> Promise<[AttributeInstance]>
        where T: Collection, T.Iterator.Element == Int {
            
            guard let eventIds = eventIds, !eventIds.isEmpty else {
                DDLogDebug("empty or nil eventIds passed to commitEvents; assuming no work to do.", tag: TAG)
                return Promise { fulfill, _ in fulfill([]) }
            }
            
            do {
                
                let attributeIds: [Int] = try eventIds.map {
                    if let ret = try? self.collator.attributeIdForIndex(self, index: $0) {
                        return ret
                    }
                    throw "No attributeId for eventId \($0)"
                }
                
                return commitEvents(forAttributeIds: attributeIds)
                
            } catch {
                return Promise { _, reject in reject(error) }
            }
    }
    
    /// Commit schedule events by `attributeId`.
    /// - parameter forAttributeIds: A sequence of attributeIds to commit.
    ///
    
    public func commitEvents<T>(forAttributeIds attributeIds: T?) -> Promise<[AttributeInstance]>
        where T: Collection, T.Iterator.Element == Int {
            
            guard let attributeIds = attributeIds, !attributeIds.isEmpty else {
                DDLogDebug("empty or nil attributeIds passed to commitEvents; assuming no work to do.", tag: TAG)
                return Promise { fulfill, _ in fulfill([]) }
            }
            
            let instances = attributeIds.enumerated().map {
                idx, attributeId -> AttributeInstance in

                DDLogDebug("Will commit value for schedule idx \(idx) attributeId \(attributeId)", tag: "OfflineSchedule")
                
                var value: AttributeValue = .rawBytes([0x00])
                
                if let event = attributeIdEventMap[attributeId] {
                    DDLogDebug("Will commit \(event) for attribueId \(attributeId)", tag: "OfflineSchedule")
                    value = .rawBytes(event.serialized.bytes)
                } else {
                    DDLogDebug("Will clear event for attributeId \(attributeId)", tag: "OfflineSchedule")
                }
                
                DDLogDebug("Will use new value \(value) for schedule idx \(idx) attributeId \(attributeId)", tag: "OfflineSchedule")
                
                return AttributeInstance(id: attributeId, value: value)
            }
            
            return firstly {
                self.storage?.set(attributes: instances) ?? Promise {
                    fulfill, _ in fulfill((instances.batchActionRequests ?? []).successfulUnpostedResults)
                }
                }.then {
                    results in return instances.filter {
                        instance in results.wasSuccessfulFor(attributeId: instance.id)
                    }
            }
    }
    
    /// Commit the enabled model to storage.
    fileprivate func commitEnabled() -> Promise<Void> {
        
        return (storage?.setOfflineScheduleFlags(flags) ?? Promise {
            _, reject in reject("No storage.")
            }).then {
                _ in return
        }
        
    }

    
}

open class OfflineSchedule: NSObject {

    var TAG: String { return "OfflineSchedule" }
    
    var collator: OfflineScheduleCollator

    fileprivate(set) weak var storage: OfflineScheduleStorage? {
        didSet {
            startObservingStorageEvents()
            primeStorage()
        }
    }

    public init?(storage: OfflineScheduleStorage, collator: OfflineScheduleCollator = DefaultOfflineScheduleCollator()) {
        
        guard storage.supportsOfflineSchedules else {
            DDLogInfo("Device \(storage.displayName) doesn't support offline schedules.", tag: "OfflineScheduleAdapter")
            return nil
        }
        
        self.storage = storage
        self.collator = collator
        self.flags = storage.offlineScheduleFlags
        super.init()
        
        startObservingStorageEvents()
        primeStorage()
    }
    
    private func primeStorage() {
        for attributeId in attributeIds {
            guard let value = storage?.valueForAttributeId(attributeId) else { continue }
            storageUpdated(attributeId, attributeValue: value)
        }
    }
    
    // MARK: Model Observation
    
    fileprivate var disposable: Disposable? {
        willSet { disposable?.dispose() }
    }
    
    func startObservingStorageEvents() {
        
        let TAG = self.TAG
        
        guard let attributeIds = attributeIds else { return }
        var observableAttributeIds = attributeIds
        
        observableAttributeIds.append(OfflineSchedule.FlagsAttributeId)
        
        disposable = storage?.eventSignalForAttributeIds(observableAttributeIds)?.observeValues {
            [weak self] event in switch event {
            case let .update(_, _, attribute):
                DDLogDebug("Got attributeUpdate: \(String(reflecting: attribute))", tag: TAG)
                self?.storageUpdated(attribute.config.descriptor.id, attributeValue: attribute.value)
            }
        }
    }
    
    func stopObservingStorageEvents() {
        disposable = nil
    }
    
    func storageUpdated(_ attributeId: Int, attributeValue: AttributeValue?) {
        
        guard let storage = storage else { return }

        if attributeId == OfflineSchedule.FlagsAttributeId {
            flags = Flags(rawValue: attributeValue?.suited() ?? 0x00)
            signalEnabledValueChanged(flags.contains(.enabled))
            return
        }
        
        guard let attributeValue = attributeValue else {
            setEvent(event: nil, forAttributeId: attributeId)
            return
        }
        
        do {
            let eventFromBytes: ScheduleEvent.ScheduleEventFromBytes = try ScheduleEvent.FromBytes(attributeValue.byteArray, types: storage.types)
            setEvent(event: eventFromBytes.event, forAttributeId: attributeId)
        } catch {
            DDLogError("Unable to set event for id \(attributeId) bytes \(attributeValue.byteArray): \(error)", tag: TAG)
        }
        
    }
    
    // MARK: Internal Model

    /// Canonical ScheduleEvent storage
    fileprivate var attributeIdEventMap: [Int: ScheduleEvent] = [:]
    
    /// An array of AttributeIDs to be used as oflfine schedule events
    lazy fileprivate(set) var attributeIds: [Int]! = {

        guard let deviceModel = self.storage else { return [] }
        
        return deviceModel.writableAttributeIds
            .intersection(type(of: self).EventAttributeIds)
            .sorted()
    }()
    
    var unusedAttributeIds: Set<Int> {
        return Set(attributeIds).subtracting(attributeIdEventMap.keys)
    }
    
    /// All of the writable dataTypes for this deviceModel, as an `[id: type]`
    lazy fileprivate(set) var dataTypes: [Int: DeviceProfile.AttributeDescriptor.DataType]! = {

        guard let deviceModel = self.storage else { return [:] }
        
        return deviceModel.readableAttributes.reduce([:]) {
            curr, next in
            var ret = curr
            ret?[next.id] = next.dataType
            return ret
        }
        
    }()
    
    // MARK: Change signaling
    
    fileprivate func signalEnabledValueChanged(_ enabled: Bool) {
        offlineScheduleEventSink.send(
            value: .offlineSchedulesEnabledStateChanged(
                enabled: enabled
            )
        )
    }
    
    fileprivate func signalEventsChanged(_ deltas: OfflineScheduleIndexDeltas) {
        offlineScheduleEventSink.send(
            value: .scheduleEventsChanged(deltas: deltas)
        )
    }
    
    private var _collatedEvents: [OfflineSchedule.ScheduleEvent]?
    
    /// A cache for collated (sorted) events.
    fileprivate var collatedEvents: [OfflineSchedule.ScheduleEvent]! {

        get {
            if let collatedEvents = _collatedEvents { return collatedEvents }
            let collatedEvents = self.collator.scheduleEvents(self)
            _collatedEvents = collatedEvents
            return collatedEvents
        }
        
        set { _collatedEvents = newValue }
    }
    
    /// Set an event for a given index by attributeId
    open func setEvent(event newEvent: ScheduleEvent?, forAttributeId newAttributeId: Int) {
        
        let oldEvents = collatedEvents
        attributeIdEventMap[newAttributeId] = newEvent
        collatedEvents = nil
        let newEvents = collatedEvents
        
        let deltas = collator.deltas(oldEvents!, after: newEvents!)
        
        signalEventsChanged(deltas)
    }
    
    /// Remove any event for the given `attributeId`. This is just an alias
    /// for `setEvent(nil, forAttributeId: attributeId)`.
    func removeEvent(_ attributeId: Int) {
        setEvent(event: nil, forAttributeId: attributeId)
    }

    /// Get an event at the given index (as per the collator)
    open func event(_ index: Int) -> OfflineSchedule.ScheduleEvent {
        return collatedEvents[index]
    }
    
    // MARK: - Public Interface
    
    public enum Event {
        case offlineSchedulesEnabledStateChanged(enabled: Bool)
        case scheduleEventsChanged(deltas: OfflineScheduleIndexDeltas)
        case scheduleEventsReloaded
    }
    
    /// Type for the sink to which we send `Event`s.
    fileprivate typealias EventSink = Signal<Event, Never>.Observer
    
    /// Type for the signal on which clients listen for `Event`s.
    public typealias EventSignal = Signal<Event, Never>
    
    /// Type for the pipe that ties `EventSink` and `EventSignal` together.
    fileprivate typealias EventPipe = (output: EventSignal, input: EventSink)
    
    /// The pipe which casts `Event`s.
    lazy fileprivate var offlineScheduleEventPipe: EventPipe = {
        return EventSignal.pipe()
    }()
    
    /// The `Signal` on which  events can be received.
    open var offlineScheduleEventSignal: EventSignal {
        return offlineScheduleEventPipe.0
    }
    
    /**
     The `Sink` to which  events are broadcast after being chaned.
     */
    
    fileprivate var offlineScheduleEventSink: EventSink {
        return offlineScheduleEventPipe.1
    }
    
    open var enabled: Bool {
        
        get {
            return flags.contains(.enabled)
        }
        
        set {
            DDLogDebug("Setting enabled \(newValue); flags before modification: \(flags.debugDescription)", tag: TAG)
            if newValue {
                flags.insert(.enabled)
            } else {
                flags.remove(.enabled)
            }
            DDLogDebug("Setting enabled \(newValue); flags after modification: \(flags.debugDescription)", tag: TAG)
            _ = commitEnabled()
        }
    }
    
    open var flags: Flags = .enabled
    
    // MARK: - End Public Interface
    
    /// Represents a scheduled setting of an attribute
    
    public struct ScheduleEvent: Hashable {
        
        public var TAG: String { return "ScheduleEvent" }
        
        public func hash(into h: inout Hasher) {
            h.combine(timeSpecification)
        }
        
        public var flags: TimeSpecification.Flags {
            get { return timeSpecification.flags }
            set { timeSpecification.flags = newValue }
        }
        
        /// Accessor for the `repeats` property of the `timeSpecificaion`
        public var repeats: Bool {
            get { return timeSpecification.repeats }
            set { timeSpecification.repeats = newValue }
        }
        
        /// Accessor for the `timeSpecification`'s local-timezone day of week, starting with Sunday == 1, ending with Saturday == 7
        @available(*, deprecated, message: "Use daysOfWeek instead.")
        public var dayOfWeek: TimeSpecification.DayOfWeek {
            get { return timeSpecification.dayOfWeek }
            set { timeSpecification.dayOfWeek = newValue }
        }
        
        public var daysOfWeek: Set<TimeSpecification.DayOfWeek> {
            get { return timeSpecification.daysOfWeek }
            set { timeSpecification.daysOfWeek = newValue }
        }
        
        
        @available(*, deprecated, message: "Use `dayOfWeek` instead.")
        public var localDayOfWeek: TimeSpecification.DayOfWeek {
            get { return dayOfWeek }
            set { dayOfWeek = newValue }
        }
        
        /// Accessor for the local-timezone hour of the `timeSpecification`. Assumed UTC.
        public var hour: TimeSpecification.Hour {
            get { return timeSpecification.hour }
            set { timeSpecification.hour = newValue }
        }

        /// Accessor for the local-timezone hour of the `timeSpecification`. Assumed UTC.
        @available(*, deprecated, message: "Use `hour` instead.")
        public var localHour: TimeSpecification.Hour {
            get { return hour }
            set { hour = newValue }
        }

        /// Accessor for the local-timezone minute of the `timeSpecification`
        public var minute: TimeSpecification.Minute {
            get { return timeSpecification.minute }
            set { timeSpecification.minute = newValue }
        }
        
        /// Accessor for the local-timezone minute of the `timeSpecification`
        @available(*, deprecated, message: "Use `minute` instead.")
        public var localMinute: TimeSpecification.Minute {
            get { return minute }
            set { minute = newValue }
        }

        /// Describes the schedule on which this event runs.
        public var timeSpecification: TimeSpecification
        
        /// Attribute store
        public var attributes: [Int: AttributeValue] = [:]
        
        public init(timeSpecification: TimeSpecification? = nil, attributes: [Int: AttributeValue] = [:]) {
            self.timeSpecification = timeSpecification ?? TimeSpecification()
            self.attributes = attributes
        }
        
        /// Represents the time (possibly repeating) when an attribute will be set
        /// in an offline schedule.
        
        public struct TimeSpecification: Hashable, Comparable {
            
            public var TAG: String { return "TimeSpecification" }
            
            public typealias Repeats = Bool
            public typealias UsesDeviceTimeZone = Bool

            public typealias DayOfWeek = DateTypes.DayOfWeek
            public typealias Hour = UInt8
            public typealias Minute = UInt8
            
            private var _daysOfWeek: Set<DayOfWeek> = []

            public var useCompactDayRepresentation: Bool = false

            private static let compactFlag: UInt8 = 128;
            
            public var daysOfWeek: Set<DayOfWeek> {
                get {
                    return _daysOfWeek }
                set {
                    _daysOfWeek = newValue
                    useCompactDayRepresentation = true
                }
            }
            
            public var dayOfWeek: DayOfWeek {
                get {
                    return daysOfWeek.first ?? DayOfWeek.sunday }
                set { daysOfWeek = [newValue] }
            }
            
            @available(*, deprecated, message: "Use `dayOfWeek` instead.")
            public var localDayOfWeek: DayOfWeek {
                get { return dayOfWeek }
                set { dayOfWeek = newValue }
            }
            
            
            static func byteToDays( days: UInt8) -> Set<DayOfWeek>? {
                var daySet: Set<DayOfWeek> = []
                
                if (days & TimeSpecification.compactFlag == 0) {
                    return nil
                }
                
                for day in DayOfWeek.allDays {
                    let bit: UInt8 = (2 << (6 - day.dayNumber))
                    if (days & bit != 0) {
                        daySet.insert(day)
                    }
                }
                
                return daySet
            }
            
            
            static func daysToByte(days: Set<DayOfWeek>) ->  UInt8 {
                return days.reduce(compactFlag, {(cur, next) -> UInt8 in cur | (2 << (6 - next.dayNumber)) })
            }
            
            
            
            public var hour: Hour

            @available(*, deprecated, message: "Use `hour` instead.")
            public var localHour: Hour {
                get { return UInt8(hour) }
                set { hour = newValue }
            }

            public var minute: Minute
            
            @available(*, deprecated, message: "Use `minute` instead.")
            public var localMinute: Minute {
                get { return minute }
                set { minute = newValue }
            }
            
            public var flags: Flags = .none

            public var repeats: Repeats {
                get { return flags.contains(.repeats) }
                set {
                    if newValue { flags.insert(.repeats) }
                    else { flags.remove(.repeats) }
                }
            }

            public var usesDeviceTimeZone: UsesDeviceTimeZone {
                get { return flags.contains(.usesDeviceTimeZone) }
                set {
                    if newValue { flags.insert(.usesDeviceTimeZone) }
                    else { flags.remove(.usesDeviceTimeZone) }
                }
            }

            
            public init(daysOfWeek: Set<DayOfWeek> = [], hour: Hour = 0, minute: Minute = 0, flags: Flags = [.usesDeviceTimeZone], useCompactDayRepresentation: Bool = false ) {
                self._daysOfWeek = daysOfWeek
                if (useCompactDayRepresentation || daysOfWeek.count > 1) {
                    self.useCompactDayRepresentation = true
                } else {
                    self.useCompactDayRepresentation = useCompactDayRepresentation
                }
                
                self.hour = hour
                self.minute = minute
                self.flags = flags
            }
            
            
            public init(dayOfWeek: DayOfWeek, hour: Hour, minute: Minute, repeats: Repeats, usesDeviceTimeZone: UsesDeviceTimeZone) {
                
                var flags: Flags = .none

                if repeats {
                    flags.insert(.repeats)
                }
                
                if usesDeviceTimeZone {
                    flags.insert(.usesDeviceTimeZone)
                }
                
                self.init(daysOfWeek: [dayOfWeek], hour: hour, minute: minute, flags: flags, useCompactDayRepresentation: false)
                
            }

            // MARK: Hashable
            
            public static func ==(lhs: OfflineSchedule.ScheduleEvent.TimeSpecification, rhs: OfflineSchedule.ScheduleEvent.TimeSpecification) -> Bool {
                return lhs.dayOfWeek == rhs.dayOfWeek
                    && lhs.hour == rhs.hour
                    && lhs.minute == rhs.minute
                    && lhs.flags == rhs.flags
            }
            
            public func hash(into h: inout Hasher) {
                h.combine(dayOfWeek)
                h.combine(hour)
                h.combine(minute)
                h.combine(flags)
            }
            
            // MARK: Comparable
            
            public static func <(lhs: OfflineSchedule.ScheduleEvent.TimeSpecification, rhs: OfflineSchedule.ScheduleEvent.TimeSpecification) -> Bool {
                
                if lhs.dayOfWeek < rhs.dayOfWeek {
                    return true
                }
                
                if lhs.dayOfWeek == rhs.dayOfWeek {
                    
                    if lhs.hour < rhs.hour {
                        return true
                    }
                    
                    if lhs.hour == rhs.hour {
                        
                        if lhs.minute < rhs.minute {
                            return true
                        }
                        
                        if lhs.minute == rhs.minute {
                            return lhs.flags.rawValue < rhs.flags.rawValue
                        }
                    }
                    
                }
                
                return false
            }


        }

    }
    
}

public extension OfflineSchedule.ScheduleEvent.TimeSpecification {

    init(schedule: DeviceRule.Schedule, repeats: Repeats = true, targetTimezone: TimeZone? = nil, usesDeviceTimeZone: Bool = true) {
        
        let localComponents: DateComponents
        
        if let targetTimezone = targetTimezone {
            localComponents = schedule.time.components(in: targetTimezone)
        } else {
            localComponents = schedule.time.components
        }
        
        self.init(dayOfWeek: schedule.firstDayOfWeek ?? .sunday, hour: Hour(localComponents.hour!), minute: Minute(localComponents.minute!), repeats: repeats, usesDeviceTimeZone: true)
    }
    
}

// MARK: - Public event queries -

public extension OfflineSchedule {

    /// The total number of events this device supports
 var numberOfSupportedEvents: Int { return attributeIds.count }
    
    /// The total number of events per day that this device supports
 var numberOfSupportedEventsPerDay: Int { return numberOfSupportedEvents / 7 }
    
    /// Local days in the schedule which which have maxed out their event count.
 var unavailableDays: Set<ScheduleEvent.TimeSpecification.DayOfWeek> {
        return Set(ScheduleEvent.TimeSpecification.DayOfWeek.allDays).subtracting(availableDays)
    }
    
    /// Local days in the schedule which which have *not* maxed out their event count.
 var availableDays: Set<ScheduleEvent.TimeSpecification.DayOfWeek> {
        return Set(dayEventCounts.filter {
            $0.value < self.numberOfSupportedEventsPerDay
            }.map {
                return $0.key
        })
    }
    
    /// A map of `DayOfWeek` to the number of events currently scheduled on that local day.
 var dayEventCounts: [ScheduleEvent.TimeSpecification.DayOfWeek: Int] {
        return ScheduleEvent.TimeSpecification.DayOfWeek.allDays.reduce([:]) {
            curr, next in
            var ret = curr
            ret[next] = self.events(forDayOfWeek: next).count
            return ret
        }
    }
    
    /// Return all events for a given local day of week
    /// - parameter localDayOfWeek: The local-timezone day of week for which to query.
    
 func events(forDayOfWeek dayOfWeek: ScheduleEvent.TimeSpecification.DayOfWeek) -> [ScheduleEvent] {
        return eventFilterResults(forDayOfWeek: dayOfWeek).map {
            (result: EventFilterResult) -> ScheduleEvent in result.event
        }
    }
    
    /// Return all events whose local day of week is in `localDaysOfWeek`
    /// - parameter localDaysOfWeek: The local days for which to filter
    
 func events<T: Sequence>(forDaysOfWeek daysOfWeek: T) -> [ScheduleEvent]
        where T.Iterator.Element == ScheduleEvent.TimeSpecification.DayOfWeek {
            return events(matching: { $0.dayOfWeek ∈ daysOfWeek })
    }
    
    /// Return all events matching the given predicate.
    /// - parameter predicate: The predicate which to evaluate each `ScheduleEvent` against.
    ///                        defaults to matching all.
    
 func events(matching predicate: ScheduleEventPredicate = { _ in return true }) -> [ScheduleEvent] {
        return eventFilterResults(matching: predicate).map {
            (result: EventFilterResult) -> ScheduleEvent in result.event
        }
    }
    
}

public extension OfflineSchedule {

    /// Type for results from event query/filter operations.
    /// Fields:
    /// * `event`: The actual schedule event instance (copy; remember these are value types)
    /// * `index`: The index of the event in the schedule in collator-sort order
    /// * `attributeId`: The event's attribute id in the schedule's storage.
    
    fileprivate typealias EventFilterResult = (event: ScheduleEvent, index: Int, attributeId: Int)
    
    /// Return an `[EventFilterResult]` for all events on the given local-timezone day.
    /// - parameter localDayOfWeek: The local-timezone day of week for which to query.
    
    fileprivate func eventFilterResults(forDayOfWeek dayOfWeek: ScheduleEvent.TimeSpecification.DayOfWeek) -> [EventFilterResult] {
        return eventFilterResults(forDaysOfWeek: [dayOfWeek])
    }

    /// Return an `[EventFilterResult]` for all events on the given local-timezone days.
    /// - parameter localDayOfWeek: The local-timezone day of week for which to query.
    
    fileprivate func eventFilterResults<T: Sequence>(forDaysOfWeek daysOfWeek: T) -> [EventFilterResult]
        where T.Iterator.Element == ScheduleEvent.TimeSpecification.DayOfWeek {
            return eventFilterResults { $0.dayOfWeek ∈ daysOfWeek }
    }

    typealias ScheduleEventPredicate = (ScheduleEvent) -> Bool

    /// Return an `[EventFilterResult]` matching the given predicate.
    /// - parameter predicate: The predicate which to evaluate each `ScheduleEvent` against.
    ///                        defaults to matching all.
    ///
    /// - warning: The results of this call should be considered **extremely** ephemeral.
    ///            Especially if events are deleted, the `index` field if the returned results
    ///            will almost certainly be incorrect.
    
    fileprivate func eventFilterResults(matching predicate: ScheduleEventPredicate = { _ in return true }) -> [EventFilterResult] {
        
        return collatedEvents.enumerated().filter {
            return predicate($0.element)
            }.compactMap {
                guard let attributeId = try? self.collator.attributeIdForIndex(self, index: $0.offset) else {
                    DDLogError("No attributeId for index \($0.offset); skipping.")
                    return nil
                }
                return (event: $0.element, index: $0.offset, attributeId: attributeId)
        }
        
    }

}

// MARK: Public event queries (deprecated)

public extension OfflineSchedule {
    
    @available(*, deprecated, message: "Use unavailableDays instead.")
 var unavailableLocalDays: Set<ScheduleEvent.TimeSpecification.DayOfWeek> {
        return unavailableDays
    }
    
    @available(*, deprecated, message: "Use availableDays instead.")
 var availableLocalDays: Set<ScheduleEvent.TimeSpecification.DayOfWeek> {
        return availableDays
    }
    
    @available(*, deprecated, message: "Use dayEventCounts instead.")
 var localDayEventCounts: [ScheduleEvent.TimeSpecification.DayOfWeek: Int] {
        return dayEventCounts
    }
    
    @available(*, deprecated, message: "Use events(forDayOfWeek:) instead.")
 func events(forLocalDayOfWeek localDayOfWeek: ScheduleEvent.TimeSpecification.DayOfWeek) -> [ScheduleEvent] {
        return events(forDayOfWeek: localDayOfWeek)
    }
    
    @available(*, deprecated, message: "Use events(forDaysOfWeek:) instead.")
 func events<T: Sequence>(forLocalDaysOfWeek localDaysOfWeek: T) -> [ScheduleEvent]
        where T.Iterator.Element == ScheduleEvent.TimeSpecification.DayOfWeek {
            return events(forDaysOfWeek: localDaysOfWeek)
    }
    
    /// Return an `[EventFilterResult]` for all events on the given local-timezone day.
    /// - parameter localDayOfWeek: The local-timezone day of week for which to query.
    @available(*, deprecated, message: "Use `eventFilterResults(forDayOfWeek:)` instead.")
    fileprivate func eventFilterResults(forLocalDayOfWeek localDayOfWeek: ScheduleEvent.TimeSpecification.DayOfWeek) -> [EventFilterResult] {
        return eventFilterResults(forLocalDaysOfWeek: [localDayOfWeek])
    }
    
    /// Return an `[EventFilterResult]` for all events on the given local-timezone days.
    /// - parameter localDayOfWeek: The local-timezone day of week for which to query.
    @available(*, deprecated, message: "Use `eventFilterResults(forDaysOfWeek:)` instead.")
    fileprivate func eventFilterResults<T: Sequence>(forLocalDaysOfWeek localDaysOfWeek: T) -> [EventFilterResult]
        where T.Iterator.Element == ScheduleEvent.TimeSpecification.DayOfWeek {
            return eventFilterResults { $0.localDayOfWeek ∈ localDaysOfWeek }
    }
    
}


public extension OfflineSchedule {
    
    /// Remove all events in the schedule.
 func removeAllEvents() -> Promise<Void> {
        return removeEvents { _ in true }
    }
    
    /// Remove all events for a given `localDayOfWeek`, and commit the removal.
    
 func removeEvents(forDayOfWeek dayOfWeek: ScheduleEvent.TimeSpecification.DayOfWeek) -> Promise<Void> {
        return removeEvents(forDaysOfWeek: [dayOfWeek])
    }

    /// Remove all events for a given `localDayOfWeek`, and commit the removal.
    @available(*, deprecated, message: "Use `removeEvents(forDayOfWeek:) instead.")
 func removeEvents(forLocalDayOfWeek localDayOfWeek: ScheduleEvent.TimeSpecification.DayOfWeek) -> Promise<Void> {
        return removeEvents(forLocalDaysOfWeek: [localDayOfWeek])
    }
    
    /// Remove all events with `localDayOfWeek` in the given sequence, and commit the removal.
    
 func removeEvents<T>(forDaysOfWeek daysOfWeek: T) -> Promise<Void>
        where T: Sequence, T.Iterator.Element == ScheduleEvent.TimeSpecification.DayOfWeek {
            return commitEvents(forAttributeIds: eventFilterResults(forDaysOfWeek: daysOfWeek).map {
                (result: EventFilterResult) -> Int in
                removeEvent(result.attributeId)
                return result.attributeId
            }).then { _ -> Void in }
    }

    /// Remove all events with `localDayOfWeek` in the given sequence, and commit the removal.
    @available(*, deprecated, message: "Use `removeEvents(forDaysOfWeek:) instead.")
 func removeEvents<T>(forLocalDaysOfWeek localDaysOfWeek: T) -> Promise<Void>
        where T: Sequence, T.Iterator.Element == ScheduleEvent.TimeSpecification.DayOfWeek {
            return commitEvents(forAttributeIds: eventFilterResults(forDaysOfWeek: localDaysOfWeek).map {
                (result: EventFilterResult) -> Int in
                removeEvent(result.attributeId)
                return result.attributeId
            }).then { _ -> Void in }
    }
    
    /// Remove all events with `utcDayOfWeek` in the given sequence, and commit the removal.
    /// - parameter predicate: The predicate for which matching events will be removed.
    /// - note: Because of the destructive nature of this operation, there is no default
    ///         predicate.
    
 func removeEvents(matching predicate: ScheduleEventPredicate) -> Promise<Void> {
            return commitEvents(forAttributeIds: eventFilterResults(matching: predicate).map {
                (result: EventFilterResult) -> Int in
                removeEvent(result.attributeId)
                return result.attributeId
            }).then { _ -> Void in }
    }

}

public extension DateTypes.Time {
    
 init(timeSpecification: OfflineSchedule.ScheduleEvent.TimeSpecification, timeZone: TimeZone) {
        self.init(
            hour: Int(timeSpecification.hour),
            minute: Int(timeSpecification.minute),
            seconds: 0,
            timeZone: timeZone
        )
    }
}

public extension DeviceRule.Schedule {
    
 init(timeSpecification: OfflineSchedule.ScheduleEvent.TimeSpecification, timeZone: TimeZone) {
        self.init(
            dayOfWeek: [timeSpecification.dayOfWeek],
            time: DateTypes.Time(timeSpecification: timeSpecification, timeZone: timeZone)
        )
    }
    
}

public extension OfflineSchedule.ScheduleEvent {
    
 init(timeSpecification: TimeSpecification? = nil, attributeSpecifications: [AttributeInstance]) {
        self.timeSpecification = timeSpecification ?? TimeSpecification()
        self.attributes = attributeSpecifications.reduce([:]) {
            curr, next in
            var ret = curr
            ret[next.id] = next.value
            return ret
        }
    }

}

public extension OfflineSchedule.ScheduleEvent {
    
 var schedule: DeviceRule.Schedule {
        
        get {
            return DeviceRule.Schedule(
                dayOfWeek: Set([timeSpecification.dayOfWeek]),
                time: DateTypes.Time(
                    timeSpecification: timeSpecification,
                    timeZone: TimeZone(abbreviation: "UTC")!
                )
            )
        }
    }
}

public extension OfflineSchedule.ScheduleEvent {
    
    /// Initialize a device rule event with the current state of a device.
    
 init(device: DeviceModelable, repeats: Bool = false, schedule: DeviceRule.Schedule) {
        
        let attributes: [Int: AttributeValue] = device.writableAttributes.reduce([:]) {
            intermed, descriptor in
            var ret = intermed
            ret[descriptor.id] = device.valueForAttributeId(descriptor.id)
            return ret
        }
        
        let timeSpec = TimeSpecification(schedule: schedule, repeats: repeats, usesDeviceTimeZone: false)
        self.init(timeSpecification: timeSpec, attributes: attributes)
    }
    
}

// MARK: - Offline Schedule Flags -

extension OfflineSchedule {
    
    public struct Flags: OptionSet, CustomDebugStringConvertible, Hashable {
        
        public var debugDescription: String {
            var lflags: [String] = []
            if contains(.enabled) {
                lflags.append("Enabled")
            }
            return "<OfflineSchedule.Flags> [\(lflags.joined(separator: ", "))]"
        }
        
        // MARK: Actual values
        
        /// Emtpy Set
        
        public static var none: Flags { return allZeros }
        
        public static var enabled: Flags { return self.init(bitIndex: 0) }
        
        // Yes, this is what a bitfield looks like in Swift :(
        
        public typealias RawValue = Int16
        
        fileprivate var value: RawValue = 0
        
        // MARK: Hashable
        
        public var hashValue: Int {
            return rawValue.hashValue
        }
        
        // MARK: NilLiteralConvertible
        
        public init(nilLiteral: Void) {
            self.value = 0
        }
        
        // MARK: RawLiteralConvertible
        
        public init(rawValue: RawValue) {
            self.value = rawValue
        }
        
        static func fromRaw(_ raw: RawValue) -> Flags {
            return self.init(rawValue: raw)
        }
        
        public init(bitIndex: RawValue) {
            self.init(rawValue: 0x01 << bitIndex)
        }
        
        public var rawValue: RawValue { return self.value }
        
        // MARK: BooleanType
        
        public var boolValue: Bool {
            return value != 0
        }
        
        // MARK: BitwiseOperationsType
        
        public static var allZeros: Flags {
            return self.init(rawValue: 0)
        }
        
        public static func fromMask(_ raw: RawValue) -> Flags {
            return self.init(rawValue: raw)
        }
        
    }

}

// MARK: TimeSpecification Flags

extension OfflineSchedule.ScheduleEvent.TimeSpecification {
    
    
    public struct Flags: OptionSet, CustomDebugStringConvertible, Hashable {
    
        public var debugDescription: String {
            var lflags: [String] = []
            if contains(.usesDeviceTimeZone) {
                lflags.append("UsesDeviceTimezone(\(Flags.usesDeviceTimeZone.rawValue))")
            }
            if contains(.repeats) {
                lflags.append("Repeats(\(Flags.repeats.rawValue))")
            }
            return "<OfflineSchedule.ScheduleEvent.TimeSpecification.Flags> \(rawValue) [\(lflags.joined(separator: ", "))]"
        }
        
        // MARK: Actual values
        
        /// Emtpy Set
        public static var none: Flags { return allZeros }
        
        /// The schedule repeats.
        public static var repeats: Flags { return self.init(bitIndex: 0) }
        
        /// The schedule is in the timezone associated with the device, rather
        /// than UTC.
        public static var usesDeviceTimeZone: Flags { return self.init(bitIndex: 1) }
        
        // Yes, this is what a bitfield looks like in Swift :(
        
        public typealias RawValue = UInt8
        
        fileprivate var value: RawValue = 0
        
        // MARK: Hashable
        
        public var hashValue: Int {
            return rawValue.hashValue
        }
        
        // MARK: NilLiteralConvertible
        
        public init(nilLiteral: Void) {
            self.value = 0
        }
        
        // MARK: RawLiteralConvertible
        
        public init(rawValue: RawValue) {
            self.value = rawValue
        }
        
        static func fromRaw(_ raw: RawValue) -> Flags {
            return self.init(rawValue: raw)
        }
        
        public init(bitIndex: RawValue) {
            self.init(rawValue: 0x01 << bitIndex)
        }
        
        public var rawValue: RawValue { return self.value }
        
        // MARK: BooleanType
        
        public var boolValue: Bool {
            return value != 0
        }
        
        // MARK: BitwiseOperationsType
        
        public static var allZeros: Flags {
            return self.init(rawValue: 0)
        }
        
        public static func fromMask(_ raw: RawValue) -> Flags {
            return self.init(rawValue: raw)
        }
        
        // MARK: ByteArray handling
        
        public var bytes: [UInt8] {
            return rawValue.bytes
        }
        
    }

}

// MARK: TimeSpecification Codec

extension OfflineSchedule.ScheduleEvent.TimeSpecification {
    
    // MARK: Coding
    
    /// Get a binary encoding of this `timeSpecification`.
    public var bytes: [UInt8] {
        
        return [
            flags.bytes,
            [useCompactDayRepresentation ?
             OfflineSchedule.ScheduleEvent.TimeSpecification.daysToByte(days: daysOfWeek) : UInt8(  dayOfWeek.dayNumber)],
            [hour],
            [minute],
            ].flatMap { $0 }
        
    }

    /// Get the binary encoding as an `NSData` object.
    public var data: Data {
        return Data(bytes: UnsafePointer<UInt8>(bytes), count: bytes.count)
    }
    
    static var FlagsOffset: Int { return 0 }
    static var FlagsSize: Int { return MemoryLayout<Flags.RawValue>.size }
    static var DayOfWeekOffset: Int { return FlagsOffset + FlagsSize }
    static var DayOfWeekSize: Int { return MemoryLayout<UInt8>.size }
    static var HourOffset: Int { return DayOfWeekOffset + DayOfWeekSize }
    static var HourSize: Int { return MemoryLayout<UInt8>.size }
    static var MinuteOffset: Int { return HourOffset + HourSize }
    static var MinuteSize: Int { return MemoryLayout<UInt8>.size }
    
    static var SerializedSize: Int { return FlagsSize + DayOfWeekSize + HourSize + MinuteSize }
    
    public init?(bytes: [UInt8]) {
        
        self.init()
        
        guard bytes.count >= type(of: self).SerializedSize else {
            DDLogError("Insufficient bytes to unpack for time specification (\(bytes.count)")
            return nil
        }
        
        flags = Flags(rawValue: bytes[type(of: self).FlagsOffset])
        
        
        let dayInt = bytes[type(of: self).DayOfWeekOffset]
        let isCompact = dayInt & OfflineSchedule.ScheduleEvent.TimeSpecification.compactFlag
        if (isCompact != 0) {
            useCompactDayRepresentation = true
            guard let daysOfWeek =             OfflineSchedule.ScheduleEvent.TimeSpecification.byteToDays(days: dayInt) else {
                DDLogError("Unexpected value for encoded 'daysOfWeek'")
                return nil
            }
            self.daysOfWeek = daysOfWeek
        } else {
            guard let dayOfWeek = DayOfWeek(dayNumber: Int(dayInt)) else {
                DDLogError("Unexpected value \(bytes[type(of: self).DayOfWeekOffset]) for encoded 'dayOfWeek'")
                return nil
            }
            
            self.dayOfWeek = dayOfWeek
        }
        
        guard (0...23).contains(bytes[type(of: self).HourOffset]) else {
            DDLogError("Unexpected value \(bytes[type(of: self).HourOffset]) for encoded 'hour'")
            return nil
        }
        
        self.hour = bytes[type(of: self).HourOffset]
        
        guard (0...59).contains(bytes[type(of: self).MinuteOffset]) else {
            DDLogError("Unexpected value \(bytes[type(of: self).MinuteOffset]) for encoded 'minute'")
            return nil
        }
        
        self.minute = bytes[type(of: self).MinuteOffset]
    }
    
    public init?(slice: ArraySlice<UInt8>) {
        self.init(bytes: Array(slice))
    }
    
}

extension OfflineSchedule.ScheduleEvent: Comparable { }

public func ==<T>(lhs: T, rhs: T) -> Bool where T: OfflineScheduleEventSerializable {
    return lhs.timeSpecification == rhs.timeSpecification && lhs.attributes == rhs.attributes
}

public func <<T>(lhs: T, rhs: T) -> Bool where T: OfflineScheduleEventSerializable {
    return lhs.timeSpecification < rhs.timeSpecification
}

private extension AttributeInstance {
    
    var offlineScheduleBytes: [UInt8] {
        let id = self.id
        var ret: [UInt8] = CFSwapInt16HostToLittle(UInt16(id)).bytes
        ret.append(contentsOf: bytes)
        return ret
    }
    
}

extension AttributeValue {
    
    var dataType: DeviceProfile.AttributeDescriptor.DataType {
        switch self {
        case .boolean: return .boolean
        case .float32: return .float32
        case .float64: return .float64
        case .q1516: return .q1516
        case .q3132: return .q3132
        case .rawBytes: return .bytes
        case .utf8S: return .utf8S
        case .signedInt8: return .sInt8
        case .signedInt16: return .sInt16
        case .signedInt32: return .sInt32
        case .signedInt64: return .sInt64
        }
    }
    
}

public protocol OfflineScheduleEventSerializable {
    
    var serialized: (bytes: [UInt8], types: [Int: DeviceProfile.AttributeDescriptor.DataType]) { get }

    var timeSpecification: OfflineSchedule.ScheduleEvent.TimeSpecification { get }
    var attributes: [Int: AttributeValue] { get }
    
    static func FromBytes(_ slice: ArraySlice<UInt8>, types: [Int: DeviceProfile.AttributeDescriptor.DataType]) throws -> (event: Self?, consumed: Int)

    static func FromBytes(_ bytes: [UInt8], types: [Int: DeviceProfile.AttributeDescriptor.DataType]) throws -> (event: Self?, consumed: Int)
    
}

public extension OfflineScheduleEventSerializable {
    
    static func FromBytes(_ slice: ArraySlice<UInt8>, types: [Int: DeviceProfile.AttributeDescriptor.DataType]) throws -> (event: Self?, consumed: Int) {
        return try FromBytes(Array(slice), types: types)
    }

}

public extension Array where Element: OfflineScheduleEventSerializable {
    
    var serialized: (bytes: [UInt8], types: [Int: DeviceProfile.AttributeDescriptor.DataType]) {
        return reduce((bytes: [], types: [:])) {
            curr, next in
            var ret = curr
            ret.bytes.append(contentsOf: next.serialized.bytes)
            _ = ret.types.update(next.serialized.types)
            return ret
        }
    }
    
}

extension OfflineSchedule.ScheduleEvent: OfflineScheduleEventSerializable {
    
    public var serialized: (bytes: [UInt8], types: [Int: DeviceProfile.AttributeDescriptor.DataType]) {
        
        var types: [Int: DeviceProfile.AttributeDescriptor.DataType] = [:]
        
        let bytes: [UInt8] = attributes.keys.sorted().reduce(timeSpecification.bytes) {
            curr, next in
            var ret = curr
            let instance = AttributeInstance(id: next, value: attributes[next]!)
            ret.append(contentsOf: instance.offlineScheduleBytes)
            types[instance.id] = instance.value.dataType
            return ret
        }
        
        return (bytes: bytes, types: types)
    }
    
    public typealias ScheduleEventFromBytes = (event: OfflineSchedule.ScheduleEvent?, consumed: Int)
    
    /// Parse a single ScheduleEvent from a byteArray.
    ///
    /// This method takes an array of bytes, and a map of attributeIds to DataTypes, and attempts
    /// to parse a full Schedule event, returning the event and number of bytes consumed. If data are incomplete,
    /// the method returns `(nil, 0)`. If various other conditions are not met, the method will throw (see below for details).
    ///
    /// - parameter bytes: A `[UInt8]` containing the `ScheduleEvent` data staring at index 0.
    /// - parameter types: A map of `attributeIds` to `DataType`s. All referenced ids in the serialized data
    ///                    must dereference from this map, otherwise we throw.
    /// - returns: The event, if any, that was parsed out, along with the number of bytes, if any, consumed from
    ///            the data.
    ///
    /// - note:
    ///   * If data are incomplete, we return `(nil, 0)`, since it's possible we just have an empty chunk.
    ///   * If data are complete, but any of the following conditions are met, then we throw:
    ///     - The TimeSpecification does not parse.
    ///     - The AttributeSpecification does not parse.
    ///     - The AttributeId is not contained in the `types` map
    ///     - The type mapped to the given `AttributeId` is not of fixed size.
    
    public static func FromBytes(_ bytes: [UInt8], types: [Int: DeviceProfile.AttributeDescriptor.DataType]) throws -> ScheduleEventFromBytes {
        
        let TAG = "ScheduleEvent"
        
        let timeSpecOffset = 0
        let timeSpecSize = TimeSpecification.SerializedSize
        
        let attributeStartOffset = timeSpecOffset + timeSpecSize

        var idOffset = attributeStartOffset
        let idSize = MemoryLayout<UInt16>.size
        
        let hdrSize = timeSpecSize + idSize
        let minSize = hdrSize + MemoryLayout<UInt8>.size
        
        DDLogVerbose("timeSpecSize: \(timeSpecSize) idSize: \(idSize) hdrSize: \(hdrSize) minSize: \(minSize)", tag: TAG)
        
        // Verify we have at least enough data to parse a header and the smallest
        // attribute value. If we don't, its not a failure... we may just be seeing an
        // incomplete chunk.
        
        guard bytes.count >= minSize else {
            if bytes.count == 1 && bytes[0] == 0 {
                DDLogVerbose("Got zero length scheduleEntry, ignoring")
            } else {
                DDLogError("Not enough data to parse scheduleEntry: (have \(bytes.count), need \(minSize)", tag: TAG)
            }
            return (event: nil, consumed: 0)
        }
        
        // Done with checks; we now know we have the amount of data we need.
        // At this point, if we fail to parse out EITHER the timespec OR
        // the valueSpec, then this is an error that needs to be thrown.
        
        let timeSpecRange = timeSpecOffset..<(timeSpecOffset + timeSpecSize)
        
        guard let timeSpecification = TimeSpecification(slice: bytes[timeSpecRange]) else {
            DDLogError("Unable to decode timeSpecification from \(bytes) from range \(timeSpecRange)", tag: "ScheduleEvent")
            throw NSError(domain: "OfflineSchedule.ScheduleEvent", code: -1010, userInfo: nil)
        }
        
        DDLogVerbose("timeSpecOffs: \(timeSpecOffset) timeSpecSize: \(timeSpecSize) timeSpecRange: \(timeSpecRange) attributeStartOffset: \(attributeStartOffset)")
        
        var event = OfflineSchedule.ScheduleEvent(timeSpecification: timeSpecification)
        var consumed = 0
        
        while idOffset < bytes.count {
            
            // Ok, we know we can at least parse the timespec, id, and smallest possible
            // value. Pull the type, and then see if we still have enough.
            
            let idRange = idOffset..<(idOffset + idSize)
            let id: UInt16 = CFSwapInt16LittleToHost(UInt16(byteArray: bytes[idRange])!)
            
            // Check to see that we have a comprensible type for this ID. If not,
            // then that's an error and we throw.
            
            guard let valueType = types[Int(id)] else {
                DDLogError("No type for id \(id) in range \(idRange) of bytes \(bytes)", tag: TAG)
                throw(NSError(domain: "OfflineSchedule.ScheduleEvent", code: -1007, userInfo: nil))
            }
            
            DDLogDebug("Parsed type \(valueType) for id \(id) from range \(idRange) of bytes \(bytes)")

            
            // Check to see that the type is fixed-length. If not, that's
            // an error and we throw.
            
            guard let valueSize = valueType.size else {
                DDLogError("Type \(valueType) has no fixed length", tag: TAG)
                throw(NSError(domain: "OfflineSchedule.ScheduleEvent", code: -1008, userInfo: nil))
            }
            
            // Now check that we at least have enough data to parse the known value.
            // If not, we may just have an incomplete chunk.
            
            let expectedSize = idOffset + idSize + valueSize
            
            guard bytes.count >= expectedSize else {
                DDLogError("Not enough data to parse scheduleEntry with type \(valueType): (have \(bytes.count), need \(expectedSize)", tag: TAG)
                return (event: nil, consumed: 0)
            }
            
            let valueOffset = idOffset + idSize
            let valueRange = valueOffset..<(valueOffset + valueSize)
            
            DDLogDebug("idSize: \(idSize) idRange: \(idRange) valueOffset: \(valueOffset) valueSize: \(valueSize) valueRange: \(valueRange)", tag: "ScheduleEvent")
            
            guard let value = AttributeValue(type: valueType, slice: bytes[valueRange]) else {
                DDLogError("Unable to convert bytes to attributeValue of type \(valueType) for bytes \(bytes[valueRange]) in range \(valueRange) of \(bytes)", tag: "ScheduleEvent")
                throw NSError(domain: "OfflineSchedule.ScheduleEvent", code: -1011, userInfo: nil)
            }
            
            event.attributes[Int(id)] = value
            
            idOffset = expectedSize
            consumed = idOffset
        }
        
        return (event: event, consumed: consumed)
    }
    
    
}

// MARK: - UTC → Local migration -

extension OfflineSchedule.ScheduleEvent.TimeSpecification {
    
    /// Get this TimeSpecification as `DateComponents` using the given
    /// calendar/timezone.
    /// - parameter calendar: The calendar to use. Defaults to `.autoupdatingCurrent`.
    /// - parameter timeZone: The timeZone to use; if present, overrides any timeZone in `calendar`. Defaults to `nil`.
    /// - returns: A "weekly" `DateComponents` instance representing this timespec.
    
    func components(with calendar: Calendar? = nil, in timeZone: TimeZone? = nil) -> DateComponents {

        return DateComponents.weekly(
            calendar: calendar,
            timeZone: timeZone,
            dayOfWeek: dayOfWeek,
            hour: Int(hour),
            minute: Int(minute)
        )
        
    }
    
    /// Get this TimeSpecification as a `Date` using the given
    /// calendar/timezone.
    /// - parameter calendar: The calendar to use. Defaults to `.autoupdatingCurrent`.
    /// - parameter timeZone: The timeZone to use; if present, overrides any timeZone in `calendar`. Defaults to `nil`.
    /// - returns: A `Date` instance representing the time this specification represents in the current week.
    
    func date(with calendar: Calendar? = nil, in timeZone: TimeZone? = nil) -> Date? {
        return components(with: calendar, in: timeZone).date
    }
    
    /// Return a copy of this `TimeSpecification` converted to "device local time",
    /// if necessary. If already converted, simply returns self.
    /// - parameter timeZone: The `TimeZone` to which to convert. This should be
    ///                       acquired from the schedule storage object that houses
    ///                       this entry.
    /// - returns: A `TimeSpecification` converted to "device local time" as per the
    ///            provided `TimeZone`, if necessary.
    /// - throws: If there are any errors in date arithmetic.
    
    func asDeviceLocalTimeSpecification(in timeZone: TimeZone) throws -> OfflineSchedule.ScheduleEvent.TimeSpecification {
        
        if usesDeviceTimeZone { return self } // Already conveted; no work to do.
        
        let fromComponents = DateComponents.weekly(
            timeZone: .UTC,
            dayOfWeek: dayOfWeek,
            hour: Int(hour),
            minute: Int(minute)
        )
        
        guard let date = fromComponents.date else {
            let msg = "Unable to convert \(String(describing: self)) to date (components: \(String(reflecting: fromComponents))"
            
            DDLogError(msg, tag: TAG)
            throw msg
        }
        
        
        let toComponents = Calendar.autoupdatingCurrent.dateComponents(in: timeZone, from: date)

        guard
            let dayOfWeek = toComponents.dayOfWeek,
            let hour = toComponents.hour,
            let minute = toComponents.minute else {
                let msg = "Unable to get dayOfWeek, hour, or minute from \(String(reflecting: toComponents))"
                DDLogError(msg, tag: TAG)
                throw msg
        }
        
        let newTimeSpec = OfflineSchedule.ScheduleEvent.TimeSpecification(
            daysOfWeek: [dayOfWeek],
            hour: UInt8(hour),
            minute: UInt8(minute),
            flags: flags.union([.usesDeviceTimeZone])
        )
        
        return newTimeSpec
        
    }
    
    /// Convert this `TimeSpecification` to "device local time",
    /// if necessary. If already converted, does nothing.
    /// - parameter timeZone: The `TimeZone` to which to convert. This should be
    ///                       acquired from the schedule storage object that houses
    ///                       this entry.
    /// - returns: A `Bool` indicating whether or not conversion took place:
    ///            If `true`, conversion took place.
    ///            If `false`, no conversion took place.
    /// - throws: If there are any errors in date arithmetic.
    
    mutating func convertToLocalTime(in timeZone: TimeZone) throws -> Bool {
        let newValue = try asDeviceLocalTimeSpecification(in: timeZone)
        if newValue == self { return false }
        self = newValue
        return true
    }
    
}

extension OfflineSchedule.ScheduleEvent {
    
    /// If `true`, this event's `timeSpecification` uses device-local time.
    /// If false, the time indicated in `timeSpecification` is in UTC.
    public var usesDeviceTimeZone: Bool {
        return timeSpecification.usesDeviceTimeZone
    }
    
    /// Convert a schedule event, possibly with a UTC timespec, and produce an event with a localtime
    /// timespec.
    /// - parameter timeZone: The `TimeZone` to which to convert. This should be
    ///                       acquired from the schedule storage object that houses
    ///                       this entry.
    /// - returns: A ScheduleEvent with converted time. The event's `timeSpecification` will
    ///            at the very least have its `.usesDeviceTimeZone` flag set.
    /// - throws: If any underlying calls throw (e.g. date arithmetic)
    
    func asDeviceLocalTimeEvent(in timeZone: TimeZone) throws -> OfflineSchedule.ScheduleEvent {
        guard !timeSpecification.usesDeviceTimeZone else { return self }
        
        var ret = self
        _ = try ret.timeSpecification.convertToLocalTime(in: timeZone)
        return ret
    }
    
    /// Convert this schedule event's timespec to localtime if necessary.
    /// - parameter timeZone: The `TimeZone` to which to convert. This should be
    ///                       acquired from the schedule storage object that houses
    ///                       this entry.
    /// - returns: A `Bool` indicating whether or not conversion took place:
    ///            If `true`, conversion took place.
    ///            If `false`, no conversion took place.
    /// - throws: If there are any errors in date arithmetic.
    
    mutating func convertToLocalTime(in timeZone: TimeZone) throws -> Bool {
        let newValue = try asDeviceLocalTimeEvent(in: timeZone)
        if newValue == self { return false }
        self = newValue
        return true
    }
    
}

extension OfflineSchedule {
    
    /// An array of UTC-based events in this schedule which need migration
    /// to `storage.timeZone`.
    
    var utcEvents: [ScheduleEvent] {
        return events(matching: { !$0.usesDeviceTimeZone } )
    }
    
    typealias OfflineScheduleMigrationResult = (from: ScheduleEvent, to: ScheduleEvent)
    
    /// Migrate UTC events to storage local timezone, up to `maxCount`.
    ///
    /// - parameter maxCount: The maximum number of events to migrate.
    /// - returns: A Promise<[OfflineScheduleMigrationResult]> which resolves to the successful
    ///            migrations.
    ///
    /// - note: If `storage.timeZone == nil`, then this will immediately resolve to an empty
    ///         result set.
    /// - warning: There should only ever be one pending `migrateUTCEvents(_:)` result pending,
    ///            as this ensures that only `maxCount` are being migrated at the same time.
    
    func migrateUTCEvents(maxCount: Int = 5) -> Promise<[OfflineScheduleMigrationResult]> {
        
        guard let timeZone = storage?.timeZone else {
            // This isn't fatal, so we'll just fulfill with empty results.
            DDLogVerbose("Storage has no timeZone set; not migrating events.", tag: self.TAG)
            return Promise { fulfill, _ in fulfill([]) }
        }

        let replacements: [OfflineSchedule.EventReplacement]
        
        do {
            replacements = try utcEvents.prefix(maxCount).map {
                (oldEvent: $0, newEvent: try $0.asDeviceLocalTimeEvent(in: timeZone))
            }
        } catch {
            return Promise { _, reject in reject(error) }
        }
        
        return performReplacements(replacements).then {
            replacements -> [OfflineScheduleMigrationResult] in
            return replacements.map {
                (from: $0.0, to: $0.1)
            }
        }
        
//        let promises: [Promise<OfflineScheduleMigrationResult>] = events.map {
//            event -> Promise<OfflineScheduleMigrationResult> in
//            return self.migrateUTCEvent(event: event)
//        }
//        
//        return when(resolved: promises)
//            .then {
//                results -> [OfflineScheduleMigrationResult] in
//                results.flatMap {
//                    result -> OfflineScheduleMigrationResult? in
//                    switch result {
//                    case let .fulfilled(value):
//                        DDLogInfo("Successfully migrated \(String(describing: value))", tag: self.TAG)
//                        return value
//                    case let .rejected(error):
//                        DDLogError("Rejected migration: \(String(describing: error))", tag: self.TAG)
//                        return nil
//                    }
//                }
//        }
        
    }
    
    /// Migrate a single UTC event to storage local timeZone.
    ///
    /// - parameter event: The event to migrate.
    /// - returns: a Promise<OfflineScheduleMigrationResult> containing the from/to migration
    ///            upon success. See *Resolution Rules* below for interpretation.
    ///
    /// ## Resolution Rules
    ///
    /// ### Rejections
    /// * If no `storage.timeZone` is present, then the migration will reject.
    /// * If the event isn't found in this schedule, then the migration will reject.
    /// * If there is an arithmetic problem converting the event from UTC to localTime,
    ///   then the migration will reject.
    ///
    /// ### Fulfillment
    /// * If the event is already in local time, then the migration will fulfill,
    ///   but changes will be made.
    /// * If the event is able to be transformed to local time and written, then
    ///   the migration will fulfill.
    
    func migrateUTCEvent(event: OfflineSchedule.ScheduleEvent) -> Promise<OfflineScheduleMigrationResult> {

        guard let timeZone = storage?.timeZone else {
            let msg = "No timeZone for storage; bailing on migration"
            DDLogVerbose(msg, tag: self.TAG)
            return Promise { _, reject in reject(msg) }
        }
        
        guard !event.usesDeviceTimeZone else {
            let msg = "Event \(String(describing: event)) already uses device timeZone; bailing."
            DDLogVerbose(msg, tag: TAG)
            return Promise { fulfill, _ in fulfill((from: event, to: event))}
        }
        guard let _ = eventIndex(for: event) else {
            let msg = "Attempting to migrate event not present in storage: \(String(describing: event)); bailing."
            DDLogError(msg, tag: TAG)
            return Promise { _, reject in reject(msg) }
        }
        
        DDLogInfo("Offline Schedule UTC Migration: migrating from UTC to \(String(describing: timeZone)) (UTC offset \(timeZone.secondsFromGMT())), event: \(String(describing: event))", tag: TAG)
        
        let migratedEvent: ScheduleEvent
        
        do {
            migratedEvent = try event.asDeviceLocalTimeEvent(in: timeZone)
        } catch {
            return Promise { _, reject in reject(error) }
        }
        
        DDLogDebug("Offline Schedule UTC Migration: new localTime event: \(String(describing: migratedEvent))", tag: TAG)
        
        return replaceScheduleEvent(event, with: migratedEvent).then {
            results -> OfflineScheduleMigrationResult in
            return (from: event, to: migratedEvent)
        }
    }
    
}

extension DeviceModelable {
    
    /// Migrate any UTC offline schedules events for this device to the device's local time.
    /// - parameter maxBatchSize: the maximum number of events to convert at a time. Must be > 0,
    ///                           or the method will assert.
    /// - parameter waitBetweenBatches: The number of seconds to wait after one batch completes
    ///                                 before attempting another batch. Must be >= 0, or
    ///                                 the method will assert.
    /// - returns: A `Promise` that resolves when all batches have been committed.
    ///
    /// ## Notes
    /// * The method will assert if `maxBatchSize <= 0` or `waitBetweenBatches` < 0.
    /// * The returned `Promise` will resolve with no effect if:
    ///   - the `timeZone` is `nil`
    ///   - `offlineSchedule()` returns `nil`
    ///   - `offlineSchedule()?.utcEvents.counts == 0`
    ///   - A migration is already in progress.
    
    func migrateUTCOfflineScheduleEvents(maxBatchSize: Int = 5, waitBetweenBatches: TimeInterval = 5.0) -> Promise<Void> {

        guard !((self as? BaseDeviceModel)?.utcMigrationIsInProgress ?? false) else {
            DDLogVerbose("Offline Schedule UTC migration currently in progress for \(deviceId); bailing.", tag: TAG)
            return Promise { fulfill, _ in fulfill(()) }
        }
        
        guard timeZone != nil else {
            DDLogVerbose("Device \(deviceId) has no timeZone; not migrating UTC events.", tag: TAG)
            return Promise { fulfill, _ in fulfill(()) }
        }
        
        (self as? BaseDeviceModel)?.utcMigrationIsInProgress = true
        
        return _migrateUTCOfflineScheduleEvents(maxBatchSize: maxBatchSize, waitBetweenBatches: waitBetweenBatches)
            .always {
            (self as? BaseDeviceModel)?.utcMigrationIsInProgress = false
        }
    }

    /// Migrate any UTC offline schedules events for this device to the device's local time.
    /// - parameter maxBatchSize: the maximum number of events to convert at a time. Must be > 0,
    ///                           or the method will assert.
    /// - parameter waitBetweenBatches: The number of seconds to wait after one batch completes
    ///                                 before attempting another batch. Must be >= 0, or
    ///                                 the method will assert.
    /// - parameter batchNumber: The batch number to report in logs.
    /// - returns: A `Promise` that resolves when all batches have been committed.
    ///
    /// ## Notes
    /// * The method will assedrt if `maxBatchSize <= 0` or `waitBetweenBatches` < 0.
    /// * The returned `Promise` will resolve with no effect if:
    ///   - the `timeZone` is `nil`
    ///   - `offlineSchedule()` returns `nil`
    ///   - `offlineSchedule()?.utcEvents.counts == 0`
    
    fileprivate func _migrateUTCOfflineScheduleEvents(maxBatchSize: Int = 3, waitBetweenBatches: TimeInterval = 5.0, batchNumber: Int = 1) -> Promise<Void> {

        let TAG = self.TAG
        
        assert(maxBatchSize > 0, "maxBatchSize must be > 0")
        assert(waitBetweenBatches >= 0, "waitBetweenBatchesmust be >= 0")

        guard let schedule = offlineSchedule() else {
            DDLogVerbose("Offline schedules unsupported for device \(deviceId); not migrating UTC events.", tag: TAG)
            return Promise { fulfill, _ in fulfill(()) }
        }
        
        guard schedule.utcEvents.count > 0 else {
            DDLogVerbose("No UTC events to migrate for device \(deviceId); bailing.", tag: TAG)
            return Promise { fulfill, _ in fulfill(()) }
        }
        
        let preCount = schedule.utcEvents.count

        DDLogDebug("Migrating UTC \(min(preCount, maxBatchSize)) events for device \(deviceId) (batch \(batchNumber)", tag: TAG)

        return Promise {
            fulfill, reject in
            _ = schedule.migrateUTCEvents(maxCount: maxBatchSize)
                .then {
                    
                    results -> Void in
                    
                    DDLogDebug("Offline schedule UTC migration: migrated \(results.count) events in batch \(batchNumber), with \(preCount - results.count) remaining.", tag: TAG)
                    
                    guard schedule.utcEvents.count > 0 else {
                        DDLogDebug("Offline schedule UTC migration for device \(self.deviceId): done.", tag: self.TAG)
                        fulfill(())
                        return
                    }
                    
                    after(waitBetweenBatches) {
                        _ = self._migrateUTCOfflineScheduleEvents(maxBatchSize: maxBatchSize, waitBetweenBatches: waitBetweenBatches, batchNumber: batchNumber + 1)
                            .then {
                                ()->Void in
                                DDLogVerbose("Offline schedule UTC migration for device \(self.deviceId) batch \(batchNumber) unwind.", tag: self.TAG)
                                fulfill(())
                        }
                    }
                    
                    DDLogVerbose("Offline schedule UTC migration for \(self.deviceId): scheduled batch \(batchNumber + 1) for \(waitBetweenBatches) from now.", tag: self.TAG)
                    
                }.catch {
                    err in reject(err)
            }
        }
        
    }
}
