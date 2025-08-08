// TimeoutManager.swift
// Bilateral timeout management for SOCK_DGRAM requests

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
    
    /// Register a timeout for a request ID (matches Go implementation exactly)
    /// - Parameters:
    ///   - requestId: Unique identifier for the request
    ///   - timeout: Duration before timeout triggers
    ///   - callback: Function to call when timeout occurs
    public func registerTimeout(
        requestId: String,
        timeout: TimeInterval,
        callback: @escaping () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        // Cancel existing timeout for this request ID if present
        cancelTimeout(requestId: requestId, acquireLock: false)
        
        // Create new timeout work item
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout(requestId: requestId, callback: callback)
        }
        
        // Store the timeout entry
        let entry = TimeoutEntry(
            workItem: workItem,
            callback: callback,
            registeredAt: Date(),
            timeout: timeout
        )
        activeTimeouts[requestId] = entry
        
        // Schedule the timeout
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }
    
    /// Cancel a timeout for a manifestific request ID (matches Go implementation exactly)
    /// - Parameter requestId: Request ID to cancel timeout for
    /// - Returns: true if timeout was found and cancelled, false otherwise
    @discardableResult
    public func cancelTimeout(requestId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return cancelTimeout(requestId: requestId, acquireLock: false)
    }
    
    /// Check if a timeout is active for a request ID
    /// - Parameter requestId: Request ID to check
    /// - Returns: true if timeout is active, false otherwise
    public func hasActiveTimeout(requestId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return activeTimeouts[requestId] != nil
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
    ///   - requestId: Unique identifier for the request
    ///   - timeout: Duration before timeout triggers
    ///   - onTimeout: Function to call when timeout occurs
    ///   - onError: Function to call if timeout registration fails
    public func registerTimeoutWithErrorHandling(
        requestId: String,
        timeout: TimeInterval,
        onTimeout: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard timeout > 0 else {
            onError(JSONRPCError.create(code: .invalidParams, details: "Timeout must be positive"))
            return
        }
        
        guard !requestId.isEmpty else {
            onError(JSONRPCError.create(code: .invalidParams, details: "Request ID cannot be empty"))
            return
        }
        
        registerTimeout(requestId: requestId, timeout: timeout, callback: onTimeout)
    }
    
    /// Register bilateral timeout (both request and response timeouts)
    /// - Parameters:
    ///   - requestId: Unique identifier for the request
    ///   - requestTimeout: Timeout for the request phase
    ///   - responseTimeout: Timeout for the response phase
    ///   - onRequestTimeout: Callback for request timeout
    ///   - onResponseTimeout: Callback for response timeout
    public func registerBilateralTimeout(
        requestId: String,
        requestTimeout: TimeInterval,
        responseTimeout: TimeInterval,
        onRequestTimeout: @escaping () -> Void,
        onResponseTimeout: @escaping () -> Void
    ) {
        // Register request timeout
        let requestTimeoutId = "\(requestId)-request"
        registerTimeout(
            requestId: requestTimeoutId,
            timeout: requestTimeout,
            callback: onRequestTimeout
        )
        
        // Register response timeout
        let responseTimeoutId = "\(requestId)-response"
        registerTimeout(
            requestId: responseTimeoutId,
            timeout: responseTimeout,
            callback: onResponseTimeout
        )
    }
    
    /// Cancel bilateral timeout
    /// - Parameter requestId: Base request ID
    /// - Returns: Number of timeouts cancelled (0-2)
    @discardableResult
    public func cancelBilateralTimeout(requestId: String) -> Int {
        var cancelledCount = 0
        
        if cancelTimeout(requestId: "\(requestId)-request") {
            cancelledCount += 1
        }
        
        if cancelTimeout(requestId: "\(requestId)-response") {
            cancelledCount += 1
        }
        
        return cancelledCount
    }
    
    /// Extend an existing timeout
    /// - Parameters:
    ///   - requestId: Request ID to extend timeout for
    ///   - additionalTime: Additional time to add to the timeout
    /// - Returns: true if timeout was found and extended, false otherwise
    @discardableResult
    public func extendTimeout(requestId: String, additionalTime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let existingEntry = activeTimeouts[requestId] else {
            return false
        }
        
        // Cancel existing timeout
        existingEntry.workItem.cancel()
        
        // Preserve the original callback and create new extended timeout
        let originalCallback = existingEntry.callback
        let newTimeout = existingEntry.timeout + additionalTime
        
        let newWorkItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout(requestId: requestId, callback: originalCallback)
        }
        
        // Create new entry with extended timeout
        let newEntry = TimeoutEntry(
            workItem: newWorkItem,
            callback: originalCallback,
            registeredAt: existingEntry.registeredAt,
            timeout: newTimeout
        )
        
        activeTimeouts[requestId] = newEntry
        
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
    
    private func cancelTimeout(requestId: String, acquireLock: Bool) -> Bool {
        if acquireLock {
            lock.lock()
            defer { lock.unlock() }
        }
        
        guard let entry = activeTimeouts.removeValue(forKey: requestId) else {
            return false
        }
        
        entry.workItem.cancel()
        return true
    }
    
    private func handleTimeout(requestId: String, callback: @escaping () -> Void) {
        // Remove from active timeouts
        lock.lock()
        activeTimeouts.removeValue(forKey: requestId)
        lock.unlock()
        
        // Execute callback
        callback()
    }
    
    private func handleTimeoutWithCleanup(requestId: String) {
        lock.lock()
        activeTimeouts.removeValue(forKey: requestId)
        lock.unlock()
        
        // Default timeout handling - could be extended
        // Timeout logging should be handled by the caller or logging system
        // print("Timeout occurred for request: \(requestId)")
    }
}

// MARK: - Convenience Extensions

extension TimeoutManager {
    
    /// Register timeout with default error handling
    /// - Parameters:
    ///   - requestId: Request ID
    ///   - timeout: Timeout duration
    ///   - callback: Timeout callback
    public func registerTimeout(
        requestId: String,
        timeout: TimeInterval,
        callback: @escaping (String) -> Void
    ) {
        registerTimeout(requestId: requestId, timeout: timeout) {
            callback(requestId)
        }
    }
    
    /// Register timeout that throws JanusError on timeout
    /// - Parameters:
    ///   - requestId: Request ID
    ///   - timeout: Timeout duration
    ///   - completion: Completion handler that will receive timeout error
    public func registerTimeoutWithErrorCompletion(
        requestId: String,
        timeout: TimeInterval,
        completion: @escaping (Result<Void, JSONRPCError>) -> Void
    ) {
        registerTimeout(requestId: requestId, timeout: timeout) {
            completion(.failure(JSONRPCError.create(code: .handlerTimeout, details: "Request \(requestId) timed out after \(timeout) seconds")))
        }
    }
}