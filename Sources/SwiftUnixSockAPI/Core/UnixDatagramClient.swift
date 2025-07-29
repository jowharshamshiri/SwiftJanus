import Foundation

/// Low-level Unix domain datagram socket client (SOCK_DGRAM)
/// Connectionless implementation for cross-language compatibility
public class UnixDatagramClient {
    private let socketPath: String
    private let maxMessageSize: Int
    private let datagramTimeout: TimeInterval
    
    public init(socketPath: String, maxMessageSize: Int = 65536, datagramTimeout: TimeInterval = 5.0) {
        self.socketPath = socketPath
        self.maxMessageSize = maxMessageSize
        self.datagramTimeout = datagramTimeout
    }
    
    /// Send datagram and receive response (connectionless communication)
    public func sendDatagram(_ data: Data, responseSocketPath: String) async throws -> Data {
        // Validate message size
        guard data.count <= maxMessageSize else {
            throw UnixSockApiError.messageTooLarge(data.count, maxMessageSize)
        }
        
        // Create response socket for receiving replies
        let responseSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard responseSocketFD != -1 else {
            throw UnixSockApiError.socketCreationFailed("Failed to create response socket")
        }
        
        defer { close(responseSocketFD) }
        
        // Bind response socket
        var responseAddr = sockaddr_un()
        responseAddr.sun_family = sa_family_t(AF_UNIX)
        let responsePathCString = responseSocketPath.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &responseAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: responsePathCString.count) { pathPtr in
                responsePathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.initialize(from: buffer.baseAddress!, count: min(buffer.count, 104))
                }
            }
        }
        
        let responseAddrSize = MemoryLayout<sockaddr_un>.size
        let bindResult = withUnsafePointer(to: &responseAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(responseSocketFD, sockaddrPtr, socklen_t(responseAddrSize))
            }
        }
        
        guard bindResult == 0 else {
            throw UnixSockApiError.bindFailed("Failed to bind response socket")
        }
        
        // Clean up response socket file on completion
        defer {
            unlink(responseSocketPath)
        }
        
        // Create client socket for sending
        let clientSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocketFD != -1 else {
            throw UnixSockApiError.socketCreationFailed("Failed to create client socket")
        }
        
        defer { close(clientSocketFD) }
        
        // Send datagram to server
        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        let serverPathCString = socketPath.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &serverAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: serverPathCString.count) { pathPtr in
                serverPathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.initialize(from: buffer.baseAddress!, count: min(buffer.count, 104))
                }
            }
        }
        
        let serverAddrSize = MemoryLayout<sockaddr_un>.size
        let sendResult = data.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientSocketFD, dataPtr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(serverAddrSize))
                }
            }
        }
        
        guard sendResult != -1 else {
            throw UnixSockApiError.sendFailed("Failed to send datagram")
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
            throw UnixSockApiError.messageTooLarge(data.count, maxMessageSize)
        }
        
        // Create client socket for sending
        let clientSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocketFD != -1 else {
            throw UnixSockApiError.socketCreationFailed("Failed to create client socket")
        }
        
        defer { close(clientSocketFD) }
        
        // Send datagram to server
        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        let serverPathCString = socketPath.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &serverAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: serverPathCString.count) { pathPtr in
                serverPathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.initialize(from: buffer.baseAddress!, count: min(buffer.count, 104))
                }
            }
        }
        
        let serverAddrSize = MemoryLayout<sockaddr_un>.size
        let sendResult = data.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientSocketFD, dataPtr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(serverAddrSize))
                }
            }
        }
        
        guard sendResult != -1 else {
            throw UnixSockApiError.sendFailed("Failed to send datagram")
        }
    }
    
    /// Test connectivity to server socket
    public func testConnection() async throws {
        let testData = "test".data(using: .utf8)!
        
        // Create client socket for testing
        let clientSocketFD = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard clientSocketFD != -1 else {
            throw UnixSockApiError.socketCreationFailed("Failed to create test socket")
        }
        
        defer { close(clientSocketFD) }
        
        // Try to send test datagram
        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        let serverPathCString = socketPath.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &serverAddr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: serverPathCString.count) { pathPtr in
                serverPathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.initialize(from: buffer.baseAddress!, count: min(buffer.count, 104))
                }
            }
        }
        
        let serverAddrSize = MemoryLayout<sockaddr_un>.size
        let sendResult = testData.withUnsafeBytes { dataPtr in
            withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(clientSocketFD, dataPtr.baseAddress, testData.count, 0, sockaddrPtr, socklen_t(serverAddrSize))
                }
            }
        }
        
        guard sendResult != -1 else {
            throw UnixSockApiError.connectionTestFailed("Test datagram send failed")
        }
    }
    
    /// Generate unique response socket path
    public func generateResponseSocketPath() -> String {
        let timestamp = Date().timeIntervalSince1970
        let pid = ProcessInfo.processInfo.processIdentifier
        return "/tmp/swift_datagram_client_\(pid)_\(Int(timestamp * 1000000)).sock"
    }
    
    // MARK: - Private Methods
    
    private func receiveResponse(_ socketFD: Int32) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: self.maxMessageSize)
                let receivedBytes = recv(socketFD, &buffer, self.maxMessageSize, 0)
                
                if receivedBytes == -1 {
                    continuation.resume(throwing: UnixSockApiError.receiveFailed("Failed to receive response"))
                } else if receivedBytes == 0 {
                    continuation.resume(throwing: UnixSockApiError.connectionClosed("Socket closed"))
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
                throw UnixSockApiError.timeout("Operation timed out after \\(timeout) seconds")
            }
            
            guard let result = try await group.next() else {
                throw UnixSockApiError.timeout("Task group failed")
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