import Foundation

/// Low-level Unix domain datagram socket client (SOCK_DGRAM)
/// Connectionless implementation for cross-language compatibility
public class CoreJanusClient {
    private let socketPath: String
    private let maxMessageSize: Int
    private let datagramTimeout: TimeInterval
    
    // Maximum Unix socket path length (108 on most systems, but leave room for null terminator)
    private static let maxSocketPathLength = 107
    
    /// Helper method to safely set up Unix socket address
    private func setupSocketAddress(_ path: String) throws -> sockaddr_un {
        guard path.count <= Self.maxSocketPathLength else {
            throw JSONRPCError.create(code: .socketError, details: "Socket path too long: \(path.count) characters (max: \(Self.maxSocketPathLength))")
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCString = path.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCString.count) { pathPtr in
                pathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.initialize(from: buffer.baseAddress!, count: buffer.count - 1) // Exclude null terminator
                }
            }
        }
        return addr
    }
    
    public init(socketPath: String, maxMessageSize: Int = 65536, datagramTimeout: TimeInterval = 5.0) {
        self.socketPath = socketPath
        self.maxMessageSize = maxMessageSize
        self.datagramTimeout = datagramTimeout
    }
    
    /// Send datagram and receive response (connectionless communication)
    public func sendDatagram(_ data: Data, responseSocketPath: String) async throws -> Data {
        // Validate message size
        guard data.count <= maxMessageSize else {
            throw JSONRPCError.create(code: .messageFramingError, details: "Message too large: \(data.count) bytes (limit: \(maxMessageSize) bytes)")
        }
        
        // Create response socket for receiving replies
        let responseSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard responseSocketFD != -1 else {
            throw JSONRPCError.create(code: .socketError, details: "Failed to create response socket")
        }
        
        defer { close(responseSocketFD) }
        
        // Bind response socket
        var responseAddr = try setupSocketAddress(responseSocketPath)
        
        let responseAddrSize = MemoryLayout<sockaddr_un>.size
        let bindResult = withUnsafePointer(to: &responseAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(responseSocketFD, sockaddrPtr, socklen_t(responseAddrSize))
            }
        }
        
        guard bindResult == 0 else {
            throw JSONRPCError.create(code: .socketError, details: "Failed to bind response socket")
        }
        
        // Clean up response socket file on completion
        defer {
            unlink(responseSocketPath)
        }
        
        // Create client socket for sending
        let clientSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocketFD != -1 else {
            throw JSONRPCError.create(code: .socketError, details: "Failed to create client socket")
        }
        
        defer { close(clientSocketFD) }
        
        // Send datagram to server
        var serverAddr = try setupSocketAddress(socketPath)
        
        let serverAddrSize = MemoryLayout<sockaddr_un>.size
        let sendResult = data.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientSocketFD, dataPtr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(serverAddrSize))
                }
            }
        }
        
        guard sendResult != -1 else {
            let errorCode = errno
            if errorCode == ENOENT || errorCode == ECONNREFUSED {
                throw JSONRPCError.create(code: .serverError, details: "No such file or directory (target socket does not exist)")
            } else {
                throw JSONRPCError.create(code: .socketError, details: "Failed to send datagram: errno \(errorCode)")
            }
        }
        
        // Receive response with timeout
        return try await withTimeout(datagramTimeout) {
            return try await self.receiveResponse(responseSocketFD)
        }
    }
    
    /// Send datagram without expecting response (fire-and-forget)
    public func sendDatagramNoResponse(_ data: Data) async throws {
        // Validate message size
        guard data.count <= maxMessageSize else {
            throw JSONRPCError.create(code: .messageFramingError, details: "Message too large: \(data.count) bytes (limit: \(maxMessageSize) bytes)")
        }
        
        // Create client socket for sending
        let clientSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocketFD != -1 else {
            throw JSONRPCError.create(code: .socketError, details: "Failed to create client socket")
        }
        
        defer { close(clientSocketFD) }
        
        // Send datagram to server
        var serverAddr = try setupSocketAddress(socketPath)
        
        let serverAddrSize = MemoryLayout<sockaddr_un>.size
        let sendResult = data.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientSocketFD, dataPtr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(serverAddrSize))
                }
            }
        }
        
        guard sendResult != -1 else {
            let errorCode = errno
            if errorCode == ENOENT || errorCode == ECONNREFUSED {
                throw JSONRPCError.create(code: .serverError, details: "No such file or directory (target socket does not exist)")
            } else {
                throw JSONRPCError.create(code: .socketError, details: "Failed to send datagram: errno \(errorCode)")
            }
        }
    }
    
    /// Test connectivity to server socket
    public func testConnection() async throws {
        let testData = "test".data(using: .utf8)!
        
        // Create client socket for testing
        let clientSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocketFD != -1 else {
            throw JSONRPCError.create(code: .socketError, details: "Failed to create test socket")
        }
        
        defer { close(clientSocketFD) }
        
        // Try to send test datagram
        var serverAddr = try setupSocketAddress(socketPath)
        
        let serverAddrSize = MemoryLayout<sockaddr_un>.size
        let sendResult = testData.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientSocketFD, dataPtr.baseAddress, testData.count, 0, sockaddrPtr, socklen_t(serverAddrSize))
                }
            }
        }
        
        guard sendResult != -1 else {
            throw JSONRPCError.create(code: .serverError, details: "Test datagram send failed")
        }
    }
    
    /// Generate unique response socket path
    public func generateResponseSocketPath() -> String {
        let timestamp = Date().timeIntervalSince1970
        let pid = ProcessInfo.processInfo.processIdentifier
        return "/tmp/swift_janus_client_\(pid)_\(Int(timestamp * 1000000)).sock"
    }
    
    // MARK: - Private Methods
    
    private func receiveResponse(_ socketFD: Int32) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: self.maxMessageSize)
                let receivedBytes = recv(socketFD, &buffer, self.maxMessageSize, 0)
                
                if receivedBytes == -1 {
                    continuation.resume(throwing: JSONRPCError.create(code: .socketError, details: "Failed to receive response"))
                } else if receivedBytes == 0 {
                    continuation.resume(throwing: JSONRPCError.create(code: .socketError, details: "Socket closed"))
                } else {
                    let data = Data(buffer.prefix(receivedBytes))
                    continuation.resume(returning: data)
                }
            }
        }
    }
    
    private func withTimeout<T>(_ timeout: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw JSONRPCError.create(code: .handlerTimeout, details: "Operation timed out after \(timeout) seconds")
            }
            
            guard let result = try await group.next() else {
                throw JSONRPCError.create(code: .internalError, details: "Task group failed")
            }
            
            group.cancelAll()
            return result
        }
    }
    
    // MARK: - Public Properties
    
    public var socketPathValue: String {
        return socketPath
    }
    
    public var maxMessageSizeValue: Int {
        return maxMessageSize
    }
}