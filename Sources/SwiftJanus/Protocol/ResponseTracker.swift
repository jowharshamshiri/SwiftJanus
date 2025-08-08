import Foundation

/// Pending request awaiting response
public class PendingRequest {
    let resolve: (JanusResponse) -> Void
    let reject: (Error) -> Void
    let timestamp: Date
    let timeout: TimeInterval
    
    init(resolve: @escaping (JanusResponse) -> Void, reject: @escaping (Error) -> Void, timeout: TimeInterval) {
        self.resolve = resolve
        self.reject = reject
        self.timestamp = Date()
        self.timeout = timeout
    }
}

/// Configuration for response tracker
public struct TrackerConfig {
    let maxPendingRequests: Int
    let cleanupInterval: TimeInterval
    let defaultTimeout: TimeInterval
    
    public init(maxPendingRequests: Int = 1000, cleanupInterval: TimeInterval = 30.0, defaultTimeout: TimeInterval = 30.0) {
        self.maxPendingRequests = maxPendingRequests
        self.cleanupInterval = cleanupInterval
        self.defaultTimeout = defaultTimeout
    }
}

/// Request statistics for monitoring
public struct RequestStatistics {
    public let totalPendingRequests: Int
    public let totalResolvedRequests: Int
    public let totalRejectedRequests: Int
    public let totalTimeoutRequests: Int
    public let averageResponseTime: TimeInterval
    public let oldestPendingAge: TimeInterval?
    
    public init(totalPendingRequests: Int, totalResolvedRequests: Int, totalRejectedRequests: Int, totalTimeoutRequests: Int, averageResponseTime: TimeInterval, oldestPendingAge: TimeInterval?) {
        self.totalPendingRequests = totalPendingRequests
        self.totalResolvedRequests = totalResolvedRequests
        self.totalRejectedRequests = totalRejectedRequests
        self.totalTimeoutRequests = totalTimeoutRequests
        self.averageResponseTime = averageResponseTime
        self.oldestPendingAge = oldestPendingAge
    }
}

/// Async response correlation and timeout handling for Swift
public class ResponseTracker {
    private var pendingRequests: [String: PendingRequest] = [:]
    private let queue = DispatchQueue(label: "response.tracker", attributes: .concurrent)
    private var dispatchTimer: DispatchSourceTimer?
    private let config: TrackerConfig
    private var eventHandlers: [String: [(Any) -> Void]] = [:]
    private var isShutdown = false
    
    // Statistics tracking
    private var totalResolvedRequests = 0
    private var totalRejectedRequests = 0
    private var totalTimeoutRequests = 0
    private var totalResponseTime: TimeInterval = 0.0
    
    /// Initialize response tracker with configuration
    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
        setupCleanupTimer()
    }
    
    deinit {
        shutdown()
    }
    
    /// Register a request for response tracking
    public func registerRequest(
        requestId: String,
        timeout: TimeInterval? = nil,
        resolve: @escaping (JanusResponse) -> Void,
        reject: @escaping (Error) -> Void
    ) throws {
        try queue.sync(flags: .barrier) {
            guard !isShutdown else {
                throw JSONRPCError.create(code: .responseTrackingError, details: "Response tracker has been shutdown")
            }
            
            guard pendingRequests.count < config.maxPendingRequests else {
                throw JSONRPCError.create(code: .responseTrackingError, details: "Maximum pending requests (\(config.maxPendingRequests)) exceeded")
            }
            
            let effectiveTimeout = timeout ?? config.defaultTimeout
            let pendingRequest = PendingRequest(resolve: resolve, reject: reject, timeout: effectiveTimeout)
            pendingRequests[requestId] = pendingRequest
            
            // Emit register event
            emit("register", data: ["requestId": requestId, "timeout": effectiveTimeout])
            
            // Setup individual request timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout) { [weak self] in
                self?.timeoutRequest(requestId: requestId)
            }
        }
    }
    
    /// Resolve a request with response
    public func resolveRequest(requestId: String, response: JanusResponse) -> Bool {
        return queue.sync(flags: .barrier) {
            guard let pendingRequest = pendingRequests.removeValue(forKey: requestId) else {
                return false
            }
            
            let responseTime = Date().timeIntervalSince(pendingRequest.timestamp)
            totalResolvedRequests += 1
            totalResponseTime += responseTime
            
            // Emit resolve event
            emit("resolve", data: ["requestId": requestId, "responseTime": responseTime])
            
            pendingRequest.resolve(response)
            return true
        }
    }
    
    /// Reject a request with error
    public func rejectRequest(requestId: String, error: Error) -> Bool {
        return queue.sync(flags: .barrier) {
            guard let pendingRequest = pendingRequests.removeValue(forKey: requestId) else {
                return false
            }
            
            totalRejectedRequests += 1
            
            // Emit reject event
            emit("reject", data: ["requestId": requestId, "error": error.localizedDescription])
            
            pendingRequest.reject(error)
            return true
        }
    }
    
    /// Cancel a manifestific request
    public func cancelRequest(requestId: String) -> Bool {
        return rejectRequest(requestId: requestId, error: JSONRPCError.create(code: .responseTrackingError, details: "Request cancelled"))
    }
    
    /// Cancel all pending requests
    public func cancelAllRequests() -> Int {
        return queue.sync(flags: .barrier) {
            return cancelAllRequestsUnsafe()
        }
    }
    
    /// Cancel all pending requests (unsafe - must be called within queue)
    private func cancelAllRequestsUnsafe() -> Int {
        let cancelledCount = pendingRequests.count
        let requestIds = Array(pendingRequests.keys)
        
        for requestId in requestIds {
            if let pendingRequest = pendingRequests.removeValue(forKey: requestId) {
                totalRejectedRequests += 1
                pendingRequest.reject(JSONRPCError.create(code: .responseTrackingError, details: "All requests cancelled"))
            }
        }
        
        // Emit cancel all event
        emit("cancel_all", data: ["cancelledCount": cancelledCount])
        
        return cancelledCount
    }
    
    /// Get request statistics
    public func getStatistics() -> RequestStatistics {
        return queue.sync {
            let totalPendingRequests = pendingRequests.count
            let averageResponseTime = totalResolvedRequests > 0 ? totalResponseTime / Double(totalResolvedRequests) : 0.0
            
            let oldestPendingAge: TimeInterval? = pendingRequests.values.min { a, b in
                a.timestamp < b.timestamp
            }?.timestamp.timeIntervalSinceNow.magnitude
            
            return RequestStatistics(
                totalPendingRequests: totalPendingRequests,
                totalResolvedRequests: totalResolvedRequests,
                totalRejectedRequests: totalRejectedRequests,
                totalTimeoutRequests: totalTimeoutRequests,
                averageResponseTime: averageResponseTime,
                oldestPendingAge: oldestPendingAge
            )
        }
    }
    
    /// Add event handler
    public func on(_ event: String, handler: @escaping (Any) -> Void) {
        queue.async(flags: .barrier) {
            if self.eventHandlers[event] == nil {
                self.eventHandlers[event] = []
            }
            self.eventHandlers[event]?.append(handler)
        }
    }
    
    /// Emit event to handlers
    private func emit(_ event: String, data: Any) {
        queue.async {
            self.eventHandlers[event]?.forEach { handler in
                handler(data)
            }
        }
    }
    
    /// Shutdown response tracker
    public func shutdown() {
        // Use async to avoid deadlock during deallocation
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self, !self.isShutdown else { return }
            self.isShutdown = true
            
            self.dispatchTimer?.cancel()
            self.dispatchTimer = nil
            
            // Cancel all pending requests
            _ = self.cancelAllRequestsUnsafe()
            
            // Emit shutdown event
            self.emit("shutdown", data: ["timestamp": Date().timeIntervalSince1970])
        }
    }
    
    // MARK: - Private Implementation
    
    private func setupCleanupTimer() {
        // Use DispatchQueue timer instead of Timer to avoid RunLoop dependency in tests
        let interval = DispatchTimeInterval.seconds(Int(config.cleanupInterval))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.cleanupExpiredRequests()
        }
        timer.resume()
        // Store the timer reference (we'll need to update the property type)
        self.dispatchTimer = timer
    }
    
    private func cleanupExpiredRequests() {
        queue.async(flags: .barrier) {
            let now = Date()
            var expiredRequests: [String] = []
            
            for (requestId, pendingRequest) in self.pendingRequests {
                if now.timeIntervalSince(pendingRequest.timestamp) > pendingRequest.timeout {
                    expiredRequests.append(requestId)
                }
            }
            
            for requestId in expiredRequests {
                self.timeoutRequest(requestId: requestId)
            }
        }
    }
    
    private func timeoutRequest(requestId: String) {
        queue.async(flags: .barrier) {
            guard let pendingRequest = self.pendingRequests.removeValue(forKey: requestId) else {
                return
            }
            
            self.totalTimeoutRequests += 1
            
            // Emit timeout event
            self.emit("timeout", data: ["requestId": requestId, "elapsedTime": Date().timeIntervalSince(pendingRequest.timestamp)])
            
            pendingRequest.reject(JSONRPCError.create(code: .responseTrackingError, details: "Request \(requestId) timed out after \(pendingRequest.timeout) seconds"))
        }
    }
}