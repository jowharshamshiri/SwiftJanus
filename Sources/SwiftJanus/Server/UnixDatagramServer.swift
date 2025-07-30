import Foundation

/// Command handler function type for SOCK_DGRAM server
public typealias DatagramCommandHandler = (SocketCommand) -> Result<[String: AnyCodable], JanusError>

/// High-level SOCK_DGRAM Unix socket server
/// Extracted from SwiftJanusDgram main binary and made reusable
public class UnixDatagramServer {
    private var handlers: [String: DatagramCommandHandler] = [:]
    private var isRunning = false
    
    public init() {
        // Register default commands that match other implementations
        registerDefaultHandlers()
    }
    
    /// Register a command handler
    public func registerHandler(_ command: String, handler: @escaping DatagramCommandHandler) {
        handlers[command] = handler
    }
    
    /// Start listening on the specified socket path using SOCK_DGRAM
    public func startListening(_ socketPath: String) async throws {
        isRunning = true
        
        print("Starting SOCK_DGRAM server on: \(socketPath)")
        
        // Remove existing socket
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create SOCK_DGRAM socket
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD != -1 else {
            throw JanusError.socketCreationFailed("Failed to create socket")
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCString = socketPath.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCString.count) { pathPtr in
                pathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.assign(from: buffer.baseAddress!, count: buffer.count)
                }
            }
        }
        
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw JanusError.bindFailed("Failed to bind socket")  
        }
        
        defer {
            Darwin.close(socketFD)
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        
        print("Ready to receive datagrams")
        
        // Receive datagrams (extracted from main binary)
        while isRunning {
            var buffer = Data(count: 64 * 1024)
            let bufferSize = buffer.count
            let bytesReceived = buffer.withUnsafeMutableBytes { bufferPtr in
                Darwin.recv(socketFD, bufferPtr.baseAddress, bufferSize, 0)
            }
            
            guard bytesReceived > 0 else {
                continue
            }
            
            let receivedData = buffer.prefix(bytesReceived)
            await processReceivedDatagram(receivedData)
        }
    }
    
    /// Stop the server
    public func stop() {
        isRunning = false
    }
    
    // MARK: - Private Implementation (extracted from main binary)
    
    private func processReceivedDatagram(_ data: Data) async {
        do {
            let cmd = try JSONDecoder().decode(SocketCommand.self, from: data)
            print("Received datagram: \(cmd.command) (ID: \(cmd.id))")
            
            // Send response via reply_to if specified
            if let replyTo = cmd.replyTo {
                await sendResponse(cmd.id, cmd.channelId, cmd.command, cmd.args, replyTo)
            }
        } catch {
            print("Failed to parse datagram: \(error)")
        }
    }
    
    private func sendResponse(_ commandId: String, _ channelId: String, _ command: String, _ args: [String: AnyCodable]?, _ replyTo: String) async {
        var success = true
        var result: [String: AnyCodable] = [:]
        
        // Check if we have a custom handler
        if let handler = handlers[command] {
            let socketCommand = SocketCommand(
                id: commandId,
                channelId: channelId,
                command: command,
                replyTo: replyTo,
                args: args,
                timeout: nil,
                timestamp: Date().timeIntervalSince1970
            )
            
            let handlerResult = handler(socketCommand)
            switch handlerResult {
            case .success(let data):
                result = data
            case .failure(let error):
                success = false
                result["error"] = AnyCodable(error.localizedDescription)
            }
        } else {
            // Use default handlers (extracted from main binary)
            switch command {
            case "ping":
                result["pong"] = AnyCodable(true)
                result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
            case "echo":
                if let message = args?["message"] {
                    result["echo"] = message
                } else {
                    result["echo"] = AnyCodable("Hello from Swift SOCK_DGRAM server!")
                }
            case "get_info":
                result["server"] = AnyCodable("Swift Janus")
                result["version"] = AnyCodable("1.0.0")
                result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
            case "validate":
                // Test JSON validation
                if let message = args?["message"]?.value as? String {
                    do {
                        _ = try JSONSerialization.jsonObject(with: message.data(using: .utf8) ?? Data())
                        result["valid"] = AnyCodable(true)
                        result["message"] = AnyCodable("Valid JSON")
                    } catch {
                        result["valid"] = AnyCodable(false)
                        result["error"] = AnyCodable("Invalid JSON: \(error)")
                    }
                } else {
                    result["valid"] = AnyCodable(false)
                    result["error"] = AnyCodable("No message provided for validation")
                }
            case "slow_process":
                // Simulate a slow process that might timeout
                Thread.sleep(forTimeInterval: 2.0) // 2 second delay
                result["processed"] = AnyCodable(true)
                result["delay"] = AnyCodable("2000ms")
                if let message = args?["message"] {
                    result["message"] = message
                }
            default:
                success = false
                result["error"] = AnyCodable("Unknown command: \(command)")
            }
        }
        
        let response = SocketResponse(
            commandId: commandId,
            channelId: channelId,
            success: success,
            result: result.isEmpty ? nil : result,
            error: success ? nil : SocketError(code: "COMMAND_ERROR", message: result["error"]?.value as? String ?? "Unknown error", details: nil),
            timestamp: Date().timeIntervalSince1970
        )
        
        do {
            let responseData = try JSONEncoder().encode(response)
            
            // Send response datagram to reply_to socket (extracted from main binary)
            let replySocketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
            guard replySocketFD != -1 else { return }
            defer { Darwin.close(replySocketFD) }
            
            var replyAddr = sockaddr_un()
            replyAddr.sun_family = sa_family_t(AF_UNIX)
            let replyPathCString = replyTo.cString(using: .utf8)!
            _ = withUnsafeMutablePointer(to: &replyAddr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: replyPathCString.count) { pathPtr in
                    replyPathCString.withUnsafeBufferPointer { buffer in
                        pathPtr.assign(from: buffer.baseAddress!, count: buffer.count)
                    }
                }
            }
            
            let sendResult = responseData.withUnsafeBytes { dataPtr in
                withUnsafePointer(to: &replyAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.sendto(replySocketFD, dataPtr.baseAddress, responseData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            
            // Check for send errors, especially message too long (matching main binary)
            if sendResult == -1 {
                let error = errno
                if error == EMSGSIZE {
                    print("ERROR: Response message too long for SOCK_DGRAM buffer limits")
                    print("Consider reducing response size or splitting data")
                } else {
                    print("ERROR: Failed to send response: errno \(error)")
                }
            }
            
        } catch {
            print("Error encoding response: \(error)")
        }
    }
    
    private func registerDefaultHandlers() {
        // Default handlers match the main binary implementation
        // These can be overridden by calling registerHandler
    }
}