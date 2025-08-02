import Foundation

/// Pending command awaiting response
public class PendingCommand {
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
    let maxPendingCommands: Int
    let cleanupInterval: TimeInterval
    let defaultTimeout: TimeInterval
    
    public init(maxPendingCommands: Int = 1000, cleanupInterval: TimeInterval = 30.0, defaultTimeout: TimeInterval = 30.0) {
        self.maxPendingCommands = maxPendingCommands
        self.cleanupInterval = cleanupInterval
        self.defaultTimeout = defaultTimeout
    }
}

/// Command statistics for monitoring
public struct CommandStatistics {
    public let totalPendingCommands: Int
    public let totalResolvedCommands: Int
    public let totalRejectedCommands: Int
    public let totalTimeoutCommands: Int
    public let averageResponseTime: TimeInterval
    public let oldestPendingAge: TimeInterval?
    
    public init(totalPendingCommands: Int, totalResolvedCommands: Int, totalRejectedCommands: Int, totalTimeoutCommands: Int, averageResponseTime: TimeInterval, oldestPendingAge: TimeInterval?) {
        self.totalPendingCommands = totalPendingCommands
        self.totalResolvedCommands = totalResolvedCommands
        self.totalRejectedCommands = totalRejectedCommands
        self.totalTimeoutCommands = totalTimeoutCommands
        self.averageResponseTime = averageResponseTime
        self.oldestPendingAge = oldestPendingAge
    }
}

/// Async response correlation and timeout handling for Swift
public class ResponseTracker {
    private var pendingCommands: [String: PendingCommand] = [:]
    private let queue = DispatchQueue(label: "response.tracker", attributes: .concurrent)
    private var dispatchTimer: DispatchSourceTimer?
    private let config: TrackerConfig
    private var eventHandlers: [String: [(Any) -> Void]] = [:]
    private var isShutdown = false
    
    // Statistics tracking
    private var totalResolvedCommands = 0
    private var totalRejectedCommands = 0
    private var totalTimeoutCommands = 0
    private var totalResponseTime: TimeInterval = 0.0
    
    /// Initialize response tracker with configuration
    public init(config: TrackerConfig = TrackerConfig()) {
        self.config = config
        setupCleanupTimer()
    }
    
    deinit {
        shutdown()
    }
    
    /// Register a command for response tracking
    public func registerCommand(
        commandId: String,
        timeout: TimeInterval? = nil,
        resolve: @escaping (JanusResponse) -> Void,
        reject: @escaping (Error) -> Void
    ) throws {
        try queue.sync(flags: .barrier) {
            guard !isShutdown else {
                throw JSONRPCError.create(code: .responseTrackingError, details: "Response tracker has been shutdown")
            }
            
            guard pendingCommands.count < config.maxPendingCommands else {
                throw JSONRPCError.create(code: .responseTrackingError, details: "Maximum pending commands (\(config.maxPendingCommands)) exceeded")
            }
            
            let effectiveTimeout = timeout ?? config.defaultTimeout
            let pendingCommand = PendingCommand(resolve: resolve, reject: reject, timeout: effectiveTimeout)
            pendingCommands[commandId] = pendingCommand
            
            // Emit register event
            emit("register", data: ["commandId": commandId, "timeout": effectiveTimeout])
            
            // Setup individual command timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + effectiveTimeout) { [weak self] in
                self?.timeoutCommand(commandId: commandId)
            }
        }
    }
    
    /// Resolve a command with response
    public func resolveCommand(commandId: String, response: JanusResponse) -> Bool {
        return queue.sync(flags: .barrier) {
            guard let pendingCommand = pendingCommands.removeValue(forKey: commandId) else {
                return false
            }
            
            let responseTime = Date().timeIntervalSince(pendingCommand.timestamp)
            totalResolvedCommands += 1
            totalResponseTime += responseTime
            
            // Emit resolve event
            emit("resolve", data: ["commandId": commandId, "responseTime": responseTime])
            
            pendingCommand.resolve(response)
            return true
        }
    }
    
    /// Reject a command with error
    public func rejectCommand(commandId: String, error: Error) -> Bool {
        return queue.sync(flags: .barrier) {
            guard let pendingCommand = pendingCommands.removeValue(forKey: commandId) else {
                return false
            }
            
            totalRejectedCommands += 1
            
            // Emit reject event
            emit("reject", data: ["commandId": commandId, "error": error.localizedDescription])
            
            pendingCommand.reject(error)
            return true
        }
    }
    
    /// Cancel a specific command
    public func cancelCommand(commandId: String) -> Bool {
        return rejectCommand(commandId: commandId, error: JSONRPCError.create(code: .responseTrackingError, details: "Command cancelled"))
    }
    
    /// Cancel all pending commands
    public func cancelAllCommands() -> Int {
        return queue.sync(flags: .barrier) {
            return cancelAllCommandsUnsafe()
        }
    }
    
    /// Cancel all pending commands (unsafe - must be called within queue)
    private func cancelAllCommandsUnsafe() -> Int {
        let cancelledCount = pendingCommands.count
        let commandIds = Array(pendingCommands.keys)
        
        for commandId in commandIds {
            if let pendingCommand = pendingCommands.removeValue(forKey: commandId) {
                totalRejectedCommands += 1
                pendingCommand.reject(JSONRPCError.create(code: .responseTrackingError, details: "All commands cancelled"))
            }
        }
        
        // Emit cancel all event
        emit("cancel_all", data: ["cancelledCount": cancelledCount])
        
        return cancelledCount
    }
    
    /// Get command statistics
    public func getStatistics() -> CommandStatistics {
        return queue.sync {
            let totalPendingCommands = pendingCommands.count
            let averageResponseTime = totalResolvedCommands > 0 ? totalResponseTime / Double(totalResolvedCommands) : 0.0
            
            let oldestPendingAge: TimeInterval? = pendingCommands.values.min { a, b in
                a.timestamp < b.timestamp
            }?.timestamp.timeIntervalSinceNow.magnitude
            
            return CommandStatistics(
                totalPendingCommands: totalPendingCommands,
                totalResolvedCommands: totalResolvedCommands,
                totalRejectedCommands: totalRejectedCommands,
                totalTimeoutCommands: totalTimeoutCommands,
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
        queue.sync(flags: .barrier) {
            guard !isShutdown else { return }
            isShutdown = true
            
            dispatchTimer?.cancel()
            dispatchTimer = nil
            
            // Cancel all pending commands
            _ = cancelAllCommandsUnsafe()
            
            // Emit shutdown event
            emit("shutdown", data: ["timestamp": Date().timeIntervalSince1970])
        }
    }
    
    // MARK: - Private Implementation
    
    private func setupCleanupTimer() {
        // Use DispatchQueue timer instead of Timer to avoid RunLoop dependency in tests
        let interval = DispatchTimeInterval.seconds(Int(config.cleanupInterval))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.cleanupExpiredCommands()
        }
        timer.resume()
        // Store the timer reference (we'll need to update the property type)
        self.dispatchTimer = timer
    }
    
    private func cleanupExpiredCommands() {
        queue.async(flags: .barrier) {
            let now = Date()
            var expiredCommands: [String] = []
            
            for (commandId, pendingCommand) in self.pendingCommands {
                if now.timeIntervalSince(pendingCommand.timestamp) > pendingCommand.timeout {
                    expiredCommands.append(commandId)
                }
            }
            
            for commandId in expiredCommands {
                self.timeoutCommand(commandId: commandId)
            }
        }
    }
    
    private func timeoutCommand(commandId: String) {
        queue.async(flags: .barrier) {
            guard let pendingCommand = self.pendingCommands.removeValue(forKey: commandId) else {
                return
            }
            
            self.totalTimeoutCommands += 1
            
            // Emit timeout event
            self.emit("timeout", data: ["commandId": commandId, "elapsedTime": Date().timeIntervalSince(pendingCommand.timestamp)])
            
            pendingCommand.reject(JSONRPCError.create(code: .responseTrackingError, details: "Command \(commandId) timed out after \(pendingCommand.timeout) seconds"))
        }
    }
}