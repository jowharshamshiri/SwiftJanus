import Foundation
import ArgumentParser
import SwiftJanus

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct JanusDgram: AsyncParsableCommand {
    struct StandardError: TextOutputStream {
        func write(_ string: String) {
            fputs(string, stderr)
        }
    }
    
    static var standardError = StandardError()
    static let configuration = CommandConfiguration(
        abstract: "Unified SOCK_DGRAM Unix Socket Process"
    )
    
    @Option(name: .long, help: "Unix socket path")
    var socket: String = "/tmp/swift-janus.sock"
    
    @Flag(name: .long, help: "Listen for datagrams on socket")
    var listen: Bool = false
    
    @Option(name: [.customLong("send-to")], help: "Send datagram to socket path")
    var sendTo: String?
    
    @Option(name: .long, help: "Command to send")
    var command: String = "ping"
    
    @Option(name: .long, help: "Message to send")
    var message: String = "hello"
    
    @Option(name: .long, help: "Manifest file (required for validation)")
    var spec: String?
    
    // Manifest storage
    private var manifest: Manifest?
    
    /// Debug logging helper - only prints when debug flag is enabled
    private func debugLog(_ message: String) {
        if debug {
            print("DEBUG: \(message)")
        }
    }
    
    @Option(name: .long, help: "Channel ID for command routing")
    var channel: String = "test"
    
    @Flag(name: .long, help: "Enable debug logging")
    var debug: Bool = false
    
    mutating func run() async throws {
        debugLog("Starting run() function")
        
        // Load Manifest if provided
        if let specPath = spec {
            debugLog("Loading spec from \(specPath)")
            do {
                let specURL = URL(fileURLWithPath: specPath)
                let specData = try Data(contentsOf: specURL)
                let parser = ManifestParser()
                manifest = try parser.parseJSON(specData)
                print("✅ Loaded Manifest from: \(specPath)")
            } catch {
                print("❌ Failed to load Manifest from \(specPath): \(error)")
                throw ExitCode.failure
            }
        } else {
            debugLog("No spec provided")
        }
        
        if listen {
            debugLog("Starting listener")
            try listenForDatagrams()
        } else if let target = sendTo {
            debugLog("Sending to target: \(target)")
            try await sendDatagram(to: target)
        } else {
            print("Usage: either --listen or --send-to required")
            throw ExitCode.validationFailure
        }
        
        print("DEBUG: run() function completed")
    }
    
    func listenForDatagrams() throws {
        print("Listening for SOCK_DGRAM on: \(socket)")
        
        // Remove existing socket
        try? FileManager.default.removeItem(atPath: socket)
        
        // Create SOCK_DGRAM socket
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD != -1 else {
            throw JSONRPCError.create(code: .socketError, details: "Failed to create socket")
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCString = socket.cString(using: .utf8)!
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathCString.count) { pathPtr in
                pathCString.withUnsafeBufferPointer { buffer in
                    pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
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
            throw JSONRPCError.create(code: .socketError, details: "Failed to bind socket")
        }
        
        defer {
            Darwin.close(socketFD)
            try? FileManager.default.removeItem(atPath: socket)
        }
        
        print("Ready to receive datagrams")
        
        // Receive datagrams
        while true {
            var buffer = Data(count: 64 * 1024)
            let bufferSize = buffer.count
            let bytesReceived = buffer.withUnsafeMutableBytes { bufferPtr in
                Darwin.recv(socketFD, bufferPtr.baseAddress, bufferSize, 0)
            }
            
            guard bytesReceived > 0 else {
                continue
            }
            
            buffer = buffer.prefix(bytesReceived)
            
            guard let cmd = try? JSONDecoder().decode(JanusCommand.self, from: buffer) else {
                print("Failed to parse datagram")
                continue
            }
            
            print("Received datagram: \(cmd.command) (ID: \(cmd.id))")
            
            // Send response via reply_to if specified
            if let replyTo = cmd.replyTo {
                sendResponse(
                    commandId: cmd.id,
                    channelId: cmd.channelId,
                    command: cmd.command,
                    args: cmd.args,
                    replyTo: replyTo
                )
            }
        }
    }
    
    func sendDatagram(to target: String) async throws {
        print("Sending SOCK_DGRAM to: \(target)")
        
        do {
            debugLog("Creating JanusClient...")
            let client = try await JanusClient(socketPath: target, channelId: "swift-client")
            debugLog("JanusClient created successfully")
            
            let args: [String: AnyCodable] = ["message": AnyCodable(message)]
            
            // Send command using high-level API
            debugLog("Sending command: \(command)")
            let response = try await client.sendCommand(command, args: args, timeout: 5.0)
            print("Response: Success=\(response.success), Result=\(response.result?.value ?? [:])")
            
        } catch let error as JSONRPCError {
            print("JSONRPCError: \(error.errorDescription)", to: &Self.standardError)
            throw ExitCode.failure
        } catch {
            print("Generic error: \(error)", to: &Self.standardError)
            throw ExitCode.failure
        }
    }
    
    func sendResponse(commandId: String, channelId: String, command: String, args: [String: AnyCodable]?, replyTo: String) {
        var result: [String: AnyCodable] = [:]
        var success = true
        var errorObj: JSONRPCError?
        
        // Built-in commands are always allowed and hardcoded (matches Go implementation exactly)
        let builtInCommands: Set<String> = ["spec", "ping", "echo", "get_info", "validate", "slow_process"]
        
        // Add arguments based on command type (matches Go/Rust implementation)
        var enhancedArgs = args ?? [:]
        if ["echo", "get_info", "validate", "slow_process"].contains(command) {
            enhancedArgs["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
        }
        
        switch command {
        case "ping":
            result["status"] = AnyCodable("pong")
            result["echo"] = AnyCodable("Server is responding")
            result["timestamp"] = AnyCodable(Date().timeIntervalSince1970)
        case "echo":
            if let message = enhancedArgs["message"] {
                result["status"] = AnyCodable("success")
                result["data"] = message
                result["original_length"] = AnyCodable((message.value as? String)?.count ?? 0)
            } else {
                result["status"] = AnyCodable("error")
                result["error"] = AnyCodable("No message parameter provided")
            }
        case "get_info":
            result["implementation"] = AnyCodable("SwiftJanus")
            result["version"] = AnyCodable("1.0.0")
            result["platform"] = AnyCodable("macOS")
            result["socket_type"] = AnyCodable("SOCK_DGRAM")
        case "validate":
            if let message = enhancedArgs["message"],
               let messageString = message.value as? String {
                do {
                    let jsonData = try JSONSerialization.jsonObject(with: messageString.data(using: .utf8)!, options: [])
                    result["valid"] = AnyCodable(true)
                    result["data"] = AnyCodable("JSON parsed successfully")
                } catch {
                    result["valid"] = AnyCodable(false)
                    result["error"] = AnyCodable("Invalid JSON format")
                    result["reason"] = AnyCodable(error.localizedDescription)
                }
            } else {
                result["valid"] = AnyCodable(false)
                result["error"] = AnyCodable("No message parameter provided")
            }
        case "slow_process":
            // Simulate slow processing
            Thread.sleep(forTimeInterval: 2.0)
            result["status"] = AnyCodable("completed")
            result["processing_time"] = AnyCodable(2.0)
            result["message"] = AnyCodable("Slow process completed successfully")
        case "spec":
            if let manifest = manifest {
                do {
                    let jsonData = try JSONEncoder().encode(manifest)
                    let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
                    result["manifest"] = AnyCodable(jsonString)
                    result["status"] = AnyCodable("success")
                } catch {
                    success = false
                    errorObj = JSONRPCError.create(code: .internalError, details: "Failed to serialize manifest")
                }
            } else {
                result["manifest"] = AnyCodable("No manifest loaded")
                result["status"] = AnyCodable("no_manifest")
            }
        default:
            success = false
            errorObj = JSONRPCError.create(code: .methodNotFound, details: "Command '\(command)' not found")
        }
        
        let response = JanusResponse(
            commandId: commandId,
            channelId: channelId,
            success: success,
            result: success ? AnyCodable(result) : nil,
            error: errorObj,
            timestamp: Date().timeIntervalSince1970
        )
        
        // Send response via Unix datagram socket
        do {
            let responseData = try JSONEncoder().encode(response)
            
            // Create response socket
            let responseFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
            guard responseFD != -1 else {
                print("Failed to create response socket")
                return
            }
            defer { Darwin.close(responseFD) }
            
            // Set up reply address
            var replyAddr = sockaddr_un()
            replyAddr.sun_family = sa_family_t(AF_UNIX)
            let replyPathCString = replyTo.cString(using: .utf8)!
            _ = withUnsafeMutablePointer(to: &replyAddr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: replyPathCString.count) { pathPtr in
                    replyPathCString.withUnsafeBufferPointer { buffer in
                        pathPtr.update(from: buffer.baseAddress!, count: buffer.count)
                    }
                }
            }
            
            // Send response
            let sendResult = responseData.withUnsafeBytes { dataPtr in
                withUnsafePointer(to: &replyAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.sendto(responseFD, dataPtr.baseAddress, responseData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            
            if sendResult == -1 {
                print("Failed to send response to \(replyTo)")
            } else {
                print("Sent response to \(replyTo): success=\(success)")
            }
            
        } catch {
            print("Failed to encode response: \(error)")
        }
    }
    
    private func validateArgument(_ value: AnyCodable, against argSpec: ArgumentSpec, name: String) throws {
        // Type validation
        switch argSpec.type {
        case .string:
            guard value.value is String else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be a string")
            }
        case .integer:
            guard value.value is Int || value.value is Double else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be an integer")
            }
        case .number:
            guard value.value is Double || value.value is Int else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be a number")
            }
        case .boolean:
            guard value.value is Bool else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be a boolean")
            }
        case .array:
            guard value.value is Array<Any> else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be an array")
            }
        case .object:
            guard value.value is Dictionary<String, Any> else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be an object")
            }
        case .null:
            // Null values are always acceptable
            break
        case .reference:
            // Reference validation would require model registry - skip for now
            break
        }
    }
    
    private func generateId() -> String {
        return String(Date().timeIntervalSince1970 * 1_000_000)
    }
}