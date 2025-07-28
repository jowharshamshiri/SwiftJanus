import Foundation
import SwiftUnixSockAPI

@main
struct SwiftUnixSockAPIClient {
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
        
        print("Connecting Swift client to: \(socketPath)")
        
        // Create API specification (matching server)
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
        
        // Create client
        let client = try UnixSockAPIClient(
            socketPath: socketPath,
            channelId: "test",
            apiSpec: apiSpec,
            config: config
        )
        
        print("Testing ping command...")
        
        // Test ping command
        do {
            let response = try await client.sendCommand(
                "ping",
                args: nil,
                timeout: 5.0
            )
            
            print("Ping response: \(response)")
            if response.success {
                print("✓ Ping test passed")
            } else {
                let errorMsg = response.error?.message ?? "Unknown error"
                print("✗ Ping test failed: \(errorMsg)")
                return
            }
        } catch {
            print("✗ Ping test error: \(error)")
            return
        }
        
        print("Testing echo command...")
        
        // Test echo command
        do {
            let response = try await client.sendCommand(
                "echo",
                args: ["message": AnyCodable("Hello from Swift client!")],
                timeout: 5.0
            )
            
            print("Echo response: \(response)")
            if response.success {
                print("✓ Echo test passed")
            } else {
                let errorMsg = response.error?.message ?? "Unknown error"
                print("✗ Echo test failed: \(errorMsg)")
                return
            }
        } catch {
            print("✗ Echo test error: \(error)")
            return
        }
        
        print("All Swift client tests completed successfully! 🎉")
    }
}