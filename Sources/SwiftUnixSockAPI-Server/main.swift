import Foundation
import SwiftUnixSockAPI

@main
struct SwiftUnixSockAPIServer {
    static func main() async throws {
        // Parse command line arguments
        let arguments = CommandLine.arguments
        var socketPath = "/tmp/swift_test_server.sock"
        
        // Look for --socket-path argument
        for i in 0..<arguments.count - 1 {
            if arguments[i] == "--socket-path" {
                socketPath = arguments[i + 1]
                break
            }
        }
        
        print("Starting Swift Unix Socket API Server on: \(socketPath)")
        
        // Remove existing socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create API specification
        let pingCommand = CommandSpec(
            description: "Simple ping command",
            args: nil,
            response: ResponseSpec(
                type: .object,
                properties: [
                    "pong": ArgumentSpec(type: .boolean, description: "Ping response"),
                    "timestamp": ArgumentSpec(type: .string, description: "Response timestamp")
                ]
            )
        )
        
        let echoCommand = CommandSpec(
            description: "Echo back input",
            args: [
                "message": ArgumentSpec(type: .string, required: true, description: "Message to echo")
            ],
            response: ResponseSpec(
                type: .object, 
                properties: [
                    "echo": ArgumentSpec(type: .string, description: "Echoed message")
                ]
            )
        )
        
        let testChannel = ChannelSpec(
            description: "Test channel",
            commands: [
                "ping": pingCommand,
                "echo": echoCommand
            ]
        )
        
        let apiSpec = APISpecification(
            version: "1.0.0",
            channels: ["test": testChannel]
        )
        
        // Create client configuration
        let config = UnixSockAPIClientConfig.default
        
        // Create and start client
        let client = try UnixSockAPIClient(
            socketPath: socketPath,
            channelId: "test",
            apiSpec: apiSpec,
            config: config
        )
        
        // Register ping handler
        try client.registerCommandHandler("ping") { (command, args) in
            return [
                "pong": AnyCodable(true),
                "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date()))
            ]
        }
        
        // Register echo handler
        try client.registerCommandHandler("echo") { (command, args) in
            let message = args?["message"]?.value as? String ?? "No message provided"
            return [
                "echo": AnyCodable(message)
            ]
        }
        
        // Start listening
        try await client.startListening()
        
        print("Swift server listening. Press Ctrl+C to stop.")
        
        // Wait indefinitely
        try await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
    }
}