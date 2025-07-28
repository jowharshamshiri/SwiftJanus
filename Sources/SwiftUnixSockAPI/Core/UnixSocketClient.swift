// UnixSocketClient.swift
// Low-level Unix socket client implementation

import Foundation
import Network

/// Low-level Unix socket client for raw socket communication with security features
public final class UnixSocketClient: @unchecked Sendable {
    private let socketPath: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "UnixSocketClient", qos: .userInitiated)
    private var isConnected = false
    private var messageHandlers: [(Data) -> Void] = []
    private let maxMessageSize: Int
    private let connectionTimeout: TimeInterval
    
    public init(socketPath: String, maxMessageSize: Int = 10 * 1024 * 1024, connectionTimeout: TimeInterval = 5.0) {
        self.socketPath = socketPath
        self.maxMessageSize = maxMessageSize
        self.connectionTimeout = connectionTimeout
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Public API Properties (Read-Only)
    
    /// Get the maximum message size (read-only)
    public var maximumMessageSize: Int {
        return maxMessageSize
    }
    
    /// Connect to the Unix socket with timeout and security validation
    public func connect() async throws {
        return try await withThrowingTaskGroup(of: Void.self) { group in
            // Connection task
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async { [weak self] in
                        guard let self = self else {
                            continuation.resume(throwing: UnixSocketError.connectionFailed("Client deallocated"))
                            return
                        }
                        
                        if self.isConnected {
                            continuation.resume()
                            return
                        }
                        
                        var hasResumed = false
                        
                        let endpoint = NWEndpoint.unix(path: self.socketPath)
                        let parameters = NWParameters()
                        // For Unix domain sockets, use the generic parameters
                        let connection = NWConnection(to: endpoint, using: parameters)
                        self.connection = connection
                        
                        connection.stateUpdateHandler = { [weak self] state in
                            guard let self = self, !hasResumed else { return }
                            
                            switch state {
                            case .ready:
                                hasResumed = true
                                self.isConnected = true
                                self.startReceiving()
                                continuation.resume()
                            case .failed(let error):
                                hasResumed = true
                                self.isConnected = false
                                continuation.resume(throwing: UnixSocketError.connectionFailed(error.localizedDescription))
                            case .cancelled:
                                hasResumed = true
                                self.isConnected = false
                                continuation.resume(throwing: UnixSocketError.connectionCancelled)
                            case .waiting(let error):
                                // For Unix sockets, waiting typically means no listener - treat as failure
                                hasResumed = true
                                self.isConnected = false
                                let errorMessage = error.localizedDescription
                                continuation.resume(throwing: UnixSocketError.connectionFailed(errorMessage))
                            default:
                                // Handle other states like .setup, .preparing
                                break
                            }
                        }
                        
                        connection.start(queue: self.queue)
                    }
                }
            }
            
            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.connectionTimeout * 1_000_000_000))
                throw UnixSocketError.connectionFailed("Connection timeout after \(self.connectionTimeout) seconds")
            }
            
            // Wait for first to complete
            try await group.next()
            group.cancelAll()
        }
    }
    
    /// Disconnect from the Unix socket
    public func disconnect() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.isConnected = false
            self?.messageHandlers.removeAll()
        }
    }
    
    /// Send data over the socket with size validation
    public func send(_ data: Data) async throws {
        guard isConnected, let connection = connection else {
            throw UnixSocketError.notConnected
        }
        
        // Security: Validate message size
        guard data.count <= maxMessageSize else {
            throw UnixSocketError.messageToLarge(data.count, maxMessageSize)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            // Prefix message with length for framing
            let lengthData = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
            let messageData = lengthData + data
            
            connection.send(content: messageData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: UnixSocketError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }
    
    /// Add a message handler for incoming data
    public func addMessageHandler(_ handler: @escaping (Data) -> Void) {
        queue.async { [weak self] in
            self?.messageHandlers.append(handler)
        }
    }
    
    /// Remove all message handlers
    public func removeAllMessageHandlers() {
        queue.async { [weak self] in
            self?.messageHandlers.removeAll()
        }
    }
    
    private func startReceiving() {
        receiveLength()
    }
    
    private func receiveLength() {
        guard let connection = connection, isConnected else { return }
        
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error receiving length: \(error)")
                return
            }
            
            guard let data = data, data.count == 4 else {
                print("Invalid length data received")
                self.receiveLength() // Continue receiving
                return
            }
            
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.receiveMessage(length: Int(length))
        }
    }
    
    private func receiveMessage(length: Int) {
        guard let connection = connection, isConnected else { return }
        
        // Security: Validate incoming message size
        guard length <= maxMessageSize else {
            print("Security warning: Incoming message size \(length) exceeds limit \(maxMessageSize)")
            // Skip this message and continue receiving
            receiveLength()
            return
        }
        
        // Security: Validate reasonable minimum size
        guard length > 0 else {
            print("Security warning: Invalid message length \(length)")
            receiveLength()
            return
        }
        
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error receiving message: \(error)")
                self.receiveLength() // Continue receiving
                return
            }
            
            if let data = data, data.count == length {
                // Security: Basic validation that data is valid UTF-8 JSON-like structure
                if self.isValidMessageData(data) {
                    // Notify all handlers
                    for handler in self.messageHandlers {
                        handler(data)
                    }
                } else {
                    print("Security warning: Received malformed message data")
                }
            }
            
            // Continue receiving next message
            self.receiveLength()
        }
    }
    
    /// Basic validation that message data appears to be valid JSON
    internal func isValidMessageData(_ data: Data) -> Bool {
        // Check if it's valid UTF-8
        guard let string = String(data: data, encoding: .utf8) else {
            return false
        }
        
        // Check for null bytes (security issue)
        guard !string.contains("\0") else {
            return false
        }
        
        // Basic JSON structure check
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
    }
}

/// Errors that can occur during Unix socket operations
public enum UnixSocketError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionCancelled
    case notConnected
    case sendFailed(String)
    case receiveFailed(String)
    case messageToLarge(Int, Int) // actual size, max size
    case malformedMessage(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .connectionCancelled:
            return "Connection was cancelled"
        case .notConnected:
            return "Not connected to socket"
        case .sendFailed(let message):
            return "Send failed: \(message)"
        case .receiveFailed(let message):
            return "Receive failed: \(message)"
        case .messageToLarge(let actualSize, let maxSize):
            return "Message too large: \(actualSize) bytes exceeds limit of \(maxSize) bytes"
        case .malformedMessage(let description):
            return "Malformed message: \(description)"
        }
    }
}