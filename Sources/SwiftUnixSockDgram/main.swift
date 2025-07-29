import Foundation
import ArgumentParser
import SwiftUnixSockAPI

struct StandardError: TextOutputStream {
    func write(_ string: String) {
        fputs(string, stderr)
    }
}

var standardError = StandardError()

@main
struct UnixSockDgram: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Unified SOCK_DGRAM Unix Socket Process"
    )
    
    @Option(name: .long, help: "Unix socket path")
    var socket: String = "/tmp/swift-unixsock.sock"
    
    @Flag(name: .long, help: "Listen for datagrams on socket")
    var listen: Bool = false
    
    @Option(name: [.customLong("send-to")], help: "Send datagram to socket path")
    var sendTo: String?
    
    @Option(name: .long, help: "Command to send")
    var command: String = "ping"
    
    @Option(name: .long, help: "Message to send")
    var message: String = "hello"
    
    func run() async throws {
        if listen {
            try listenForDatagrams()
        } else if let target = sendTo {
            try await sendDatagram(to: target)
        } else {
            print("Usage: either --listen or --send-to required")
            UnixSockDgram.exit(withError: ExitCode.validationFailure)
        }
    }
    
    func listenForDatagrams() throws {
        print("Listening for SOCK_DGRAM on: \(socket)")
        
        // Remove existing socket
        try? FileManager.default.removeItem(atPath: socket)
        
        // Create SOCK_DGRAM socket
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD != -1 else {
            throw UnixSockApiError.socketCreationFailed("Failed to create socket")
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
            throw UnixSockApiError.bindFailed("Failed to bind socket")
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
            
            guard let cmd = try? JSONDecoder().decode(SocketCommand.self, from: buffer) else {
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
            let client = try UnixDatagramClient(socketPath: target)
            
            // Create response socket path
            let responseSocket = "/tmp/swift-response-\(ProcessInfo.processInfo.processIdentifier).sock"
            
            let args: [String: AnyCodable] = ["message": AnyCodable(message)]
            
            let cmd = SocketCommand(
                id: generateId(),
                channelId: "test",
                command: command,
                replyTo: responseSocket,
                args: args.isEmpty ? nil : args,
                timeout: 5.0,
                timestamp: Date().timeIntervalSince1970
            )
            
            let cmdData = try JSONEncoder().encode(cmd)
            
            // Send datagram and wait for response
            let responseData = try await client.sendDatagram(cmdData, responseSocketPath: responseSocket)
            
            let response = try JSONDecoder().decode(SocketResponse.self, from: responseData)
            print("Response: Success=\(response.success), Result=\(response.result ?? [:])")
            
        } catch UnixSockApiError.connectionTestFailed(let message) {
            print("Connection failed: \(message)", to: &standardError)
            throw ExitCode.failure
        } catch UnixSockApiError.timeout(let message) {
            print("Timeout: \(message)", to: &standardError)
            throw ExitCode.failure
        } catch {
            print("Error: \(error)", to: &standardError)
            throw ExitCode.failure
        }
    }
    
    func sendResponse(commandId: String, channelId: String, command: String, args: [String: AnyCodable]?, replyTo: String) {
        var result: [String: AnyCodable] = [:]
        var success = true
        
        switch command {
        case "ping":
            result["pong"] = AnyCodable(true)
            result["echo"] = AnyCodable(args)
        case "echo":
            if let message = args?["message"] {
                result["message"] = message
            }
        case "get_info":
            result["implementation"] = AnyCodable("Swift")
            result["version"] = AnyCodable("1.0.0")
            result["protocol"] = AnyCodable("SOCK_DGRAM")
        default:
            success = false
            result["error"] = AnyCodable("Unknown command: \(command)")
        }
        
        let response = SocketResponse(
            commandId: commandId,
            channelId: channelId,
            success: success,
            result: result.isEmpty ? nil : result,
            error: success ? nil : SocketError(code: "UNKNOWN_COMMAND", message: "Unknown command", details: nil),
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
            
            responseData.withUnsafeBytes { dataPtr in
                withUnsafePointer(to: &replyAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.sendto(replySocketFD, dataPtr.baseAddress, responseData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
        } catch {
            print("Failed to send response: \(error)")
        }
    }
}

func generateId() -> String {
    return String(Date().timeIntervalSince1970 * 1_000_000)
}