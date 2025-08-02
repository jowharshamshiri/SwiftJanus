// TimeoutManager.swift
// Bilateral timeout management for SOCK_DGRAM commands

import Foundation
import Dispatch

/// Bilateral timeout manager for handling both caller and handler timeouts
/// Matches Go and Rust timeout management functionality exactly
public final class TimeoutManager {
    
    // MARK: - Private Properties
    
    private let queue = DispatchQueue(label: "com.janus.timeout-manager", qos: .utility)
    private var activeTimeouts: [String: TimeoutEntry] = [:]
    private let lock = NSLock()
    
    // MARK: - Private Types
    
    private struct TimeoutEntry {
        let workItem: DispatchWorkItem
        let callback: () -> Void
        let registeredAt: Date
        var timeout: TimeInterval
    }
    
    // MARK: - Initialization
    
    public init() {}
    
    deinit {
        clearAllTimeouts()
    }
    
    // MARK: - Public Interface
    
    /// Register a timeout for a command ID (matches Go implementation exactly)
    /// - Parameters:
    ///   - commandId: Unique identifier for the command
    ///   - timeout: Duration before timeout triggers
    ///   - callback: Function to call when timeout occurs
    public func registerTimeout(
        commandId: String,
        timeout: TimeInterval,
        callback: @escaping () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        // Cancel existing timeout for this command ID if present
        cancelTimeout(commandId: commandId, acquireLock: false)
        
        // Create new timeout work item
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout(commandId: commandId, callback: callback)
        }
        
        // Store the timeout entry
        let entry = TimeoutEntry(
            workItem: workItem,
            callback: callback,
            registeredAt: Date(),
            timeout: timeout
        )
        activeTimeouts[commandId] = entry
        
        // Schedule the timeout
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }
    
    /// Cancel a timeout for a specific command ID (matches Go implementation exactly)
    /// - Parameter commandId: Command ID to cancel timeout for
    /// - Returns: true if timeout was found and cancelled, false otherwise
    @discardableResult
    public func cancelTimeout(commandId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return cancelTimeout(commandId: commandId, acquireLock: false)
    }
    
    /// Check if a timeout is active for a command ID
    /// - Parameter commandId: Command ID to check
    /// - Returns: true if timeout is active, false otherwise
    public func hasActiveTimeout(commandId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return activeTimeouts[commandId] != nil
    }
    
    /// Get count of active timeouts
    /// - Returns: Number of active timeouts
    public var activeTimeoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        
        return activeTimeouts.count
    }
    
    /// Clear all active timeouts
    public func clearAllTimeouts() {
        lock.lock()
        defer { lock.unlock() }
        
        for (_, entry) in activeTimeouts {
            entry.workItem.cancel()
        }
        activeTimeouts.removeAll()
    }
    
    // MARK: - Advanced Timeout Management
    
    /// Register a timeout with custom error handling
    /// - Parameters:
    ///   - commandId: Unique identifier for the command
    ///   - timeout: Duration before timeout triggers
    ///   - onTimeout: Function to call when timeout occurs
    ///   - onError: Function to call if timeout registration fails
    public func registerTimeoutWithErrorHandling(
        commandId: String,
        timeout: TimeInterval,
        onTimeout: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard timeout > 0 else {
            onError(JanusError.validationError("Timeout must be positive"))
            return
        }
        
        guard !commandId.isEmpty else {
            onError(JanusError.validationError("Command ID cannot be empty"))
            return
        }
        
        registerTimeout(commandId: commandId, timeout: timeout, callback: onTimeout)
    }
    
    /// Register bilateral timeout (both request and response timeouts)
    /// - Parameters:
    ///   - commandId: Unique identifier for the command
    ///   - requestTimeout: Timeout for the request phase
    ///   - responseTimeout: Timeout for the response phase
    ///   - onRequestTimeout: Callback for request timeout
    ///   - onResponseTimeout: Callback for response timeout
    public func registerBilateralTimeout(
        commandId: String,
        requestTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        onRequestTimeout: @escaping () -> Void,
        onResponseTimeout: @escaping () -> Void
    ) {
        // Register request timeout
        let requestTimeoutId = "\(commandId)-request"
        registerTimeout(
            commandId: requestTimeoutId,
            timeout: requestTimeout,
            callback: onRequestTimeout
        )
        
        // Register response timeout
        let responseTimeoutId = "\(commandId)-response"
        registerTimeout(
            commandId: responseTimeoutId,
            timeout: responseTimeout,
            callback: onResponseTimeout
        )
    }
    
    /// Cancel bilateral timeout
    /// - Parameter commandId: Base command ID
    /// - Returns: Number of timeouts cancelled (0-2)
    @discardableResult
    public func cancelBilateralTimeout(commandId: String) -> Int {
        var cancelledCount = 0
        
        if cancelTimeout(commandId: "\(commandId)-request") {
            cancelledCount += 1
        }
        
        if cancelTimeout(commandId: "\(commandId)-response") {
            cancelledCount += 1
        }
        
        return cancelledCount
    }
    
    /// Extend an existing timeout
    /// - Parameters:
    ///   - commandId: Command ID to extend timeout for
    ///   - additionalTime: Additional time to add to the timeout
    /// - Returns: true if timeout was found and extended, false otherwise
    @discardableResult
    public func extendTimeout(commandId: String, additionalTime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let existingEntry = activeTimeouts[commandId] else {
            return false
        }
        
        // Cancel existing timeout
        existingEntry.workItem.cancel()
        
        // Preserve the original callback and create new extended timeout
        let originalCallback = existingEntry.callback
        let newTimeout = existingEntry.timeout + additionalTime
        
        let newWorkItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout(commandId: commandId, callback: originalCallback)
        }
        
        // Create new entry with extended timeout
        let newEntry = TimeoutEntry(
            workItem: newWorkItem,
            callback: originalCallback,
            registeredAt: existingEntry.registeredAt,
            timeout: newTimeout
        )
        
        activeTimeouts[commandId] = newEntry
        
        // Schedule with additional time
        queue.asyncAfter(deadline: .now() + additionalTime, execute: newWorkItem)
        
        return true
    }
    
    // MARK: - Timeout Statistics
    
    /// Get timeout statistics
    /// - Returns: Dictionary with timeout statistics
    public func getTimeoutStatistics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        
        return [
            "activeTimeouts": activeTimeouts.count,
            "queueLabel": queue.label
        ]
    }
    
    // MARK: - Private Methods
    
    private func cancelTimeout(commandId: String, acquireLock: Bool) -> Bool {
        if acquireLock {
            lock.lock()
            defer { lock.unlock() }
        }
        
        guard let entry = activeTimeouts.removeValue(forKey: commandId) else {
            return false
        }
        
        entry.workItem.cancel()
        return true
    }
    
    private func handleTimeout(commandId: String, callback: @escaping () -> Void) {
        // Remove from active timeouts
        lock.lock()
        activeTimeouts.removeValue(forKey: commandId)
        lock.unlock()
        
        // Execute callback
        callback()
    }
    
    private func handleTimeoutWithCleanup(commandId: String) {
        lock.lock()
        activeTimeouts.removeValue(forKey: commandId)
        lock.unlock()
        
        // Default timeout handling - could be extended
        print("Timeout occurred for command: \(commandId)")
    }
}

// MARK: - Convenience Extensions

extension TimeoutManager {
    
    /// Register timeout with default error handling
    /// - Parameters:
    ///   - commandId: Command ID
    ///   - timeout: Timeout duration
    ///   - callback: Timeout callback
    public func registerTimeout(
        commandId: String,
        timeout: TimeInterval,
        callback: @escaping (String) -> Void
    ) {
        registerTimeout(commandId: commandId, timeout: timeout) {
            callback(commandId)
        }
    }
    
    /// Register timeout that throws JanusError on timeout
    /// - Parameters:
    ///   - commandId: Command ID
    ///   - timeout: Timeout duration
    ///   - completion: Completion handler that will receive timeout error
    public func registerTimeoutWithErrorCompletion(
        commandId: String,
        timeout: TimeInterval,
        completion: @escaping (Result<Void, JanusError>) -> Void
    ) {
        registerTimeout(commandId: commandId, timeout: timeout) {
            completion(.failure(JanusError.timeout("Command \(commandId) timed out after \(timeout) seconds")))
        }
    }
}