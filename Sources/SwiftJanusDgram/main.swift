import Foundation
import ArgumentParser
import SwiftJanus

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
            // These commands need a "message" argument - add default if not present
            if enhancedArgs["message"] == nil {
                enhancedArgs["message"] = AnyCodable("test message")
            }
        }
        // spec and ping commands don't need message arguments
        
        // Validate command against Manifest if provided
        // Built-in commands bypass Manifest validation
        if let manifest = manifest, !builtInCommands.contains(command) {
            // Check if command exists in the channel
            if let channel = manifest.channels[channelId],
               let _ = channel.commands[command] {
                // Command exists, validate arguments
                do {
                    let commandSpec = channel.commands[command]!
                    if let specArgs = commandSpec.args {
                        try validateCommandArgs(args: enhancedArgs, againstSpec: specArgs)
                    }
                } catch {
                    success = false
                    errorObj = JSONRPCError.create(
                        code: .validationFailed,
                        details: "Command validation failed: \(error.localizedDescription)"
                    )
                }
            } else {
                // Command not found in Manifest
                success = false
                errorObj = JSONRPCError.create(
                    code: .methodNotFound,
                    details: "Command '\(command)' not found in channel '\(channelId)'"
                )
            }
        }
        
        // Only process command if validation passed (matches Go logic exactly)
        if success {
            switch command {
        case "ping":
            result["pong"] = AnyCodable(true)
            result["echo"] = AnyCodable(enhancedArgs)
        case "echo":
            if let message = enhancedArgs["message"] {
                result["message"] = message
            }
        case "get_info":
            result["implementation"] = AnyCodable("Swift")
            result["version"] = AnyCodable("1.0.0")
            result["protocol"] = AnyCodable("SOCK_DGRAM")
        case "validate":
            // Validate JSON payload
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
                result["error"] = AnyCodable("No message provided for validation")
            }
        case "slow_process":
            // Simulate a slow process that might timeout
            Thread.sleep(forTimeInterval: 2.0) // 2 second delay
            result["processed"] = AnyCodable(true)
            result["delay"] = AnyCodable("2000ms")
            if let message = enhancedArgs["message"] {
                result["message"] = message
            }
        case "spec":
            // Return loaded Manifest
            if let manifest = manifest {
                // Directly encode the Manifest - AnyCodable will handle Codable types
                result["specification"] = AnyCodable(manifest)
            } else {
                success = false
                result["error"] = AnyCodable("No Manifest loaded. Use --spec argument to load specification file")
            }
            default:
                success = false
                result["error"] = AnyCodable("Unknown command: \(command)")
            }
        }
        
        // Note: ResponseValidator integration would require Manifest loading
        // For now, responses are sent without validation in this standalone binary
        
        let response = JanusResponse(
            commandId: commandId,
            channelId: channelId,
            success: success,
            result: result.isEmpty ? nil : AnyCodable(result),
            error: errorObj ?? (success ? nil : JSONRPCError.create(code: .methodNotFound, details: "Unknown command")),
            timestamp: Date().timeIntervalSince1970
        )
        
        do {
            let responseData = try JSONEncoder().encode(response)
            
            // Send response datagram to reply_to socket
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
            
            // Check for send errors, especially message too long
            if sendResult == -1 {
                let errorCode = errno
                if errorCode == EMSGSIZE {
                    print("Error: Response payload too large for SOCK_DGRAM (size: \(responseData.count) bytes): Unix domain datagram sockets have system-imposed size limits, typically around 64KB. Consider reducing payload size or using chunked messages")
                } else {
                    print("Failed to send response: errno \(errorCode)")
                }
            }
        } catch {
            print("Failed to send response: \(error)")
        }
    }
    
    /// Validate command arguments against Manifest (matches Go implementation)
    private func validateCommandArgs(args: [String: AnyCodable]?, againstSpec specArgs: [String: ArgumentSpec]) throws {
        // Check for required arguments
        for (argName, argSpec) in specArgs {
            if argSpec.required && (args?[argName] == nil) {
                throw JSONRPCError.create(code: .invalidParams, details: "Required argument '\(argName)' is missing")
            }
        }
        
        // Validate argument types and values
        if let args = args {
            for (argName, argValue) in args {
                if let argSpec = specArgs[argName] {
                    try validateArgumentValue(name: argName, value: argValue, spec: argSpec)
                }
                // Note: Extra arguments not in spec are allowed for flexibility
            }
        }
    }
    
    /// Validate individual argument value against its specification
    private func validateArgumentValue(name: String, value: AnyCodable, spec: ArgumentSpec) throws {
        // Type validation based on spec
        switch spec.type {
        case .string:
            guard value.value is String else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be a string")
            }
        case .number:
            guard value.value is Double || value.value is Float || value.value is Int else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be a number")
            }
        case .integer:
            guard value.value is Int else {
                throw JSONRPCError.create(code: .invalidParams, details: "Argument '\(name)' must be an integer")
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
