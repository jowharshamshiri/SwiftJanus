import Foundation
import SwiftUnixSockAPI

@main
struct SwiftUnixSockAPIClient {
    static func main() async throws {
        // Parse command line arguments
        let arguments = CommandLine.arguments
        var socketPath = "/tmp/swift_test_server.sock"
        var specPath = "test-api-spec.json"
        
        // Parse command line arguments
        for i in 0..<arguments.count - 1 {
            if arguments[i] == "--socket-path" {
                socketPath = arguments[i + 1]
            } else if arguments[i] == "--spec" {
                specPath = arguments[i + 1]
            }
        }
        
        print("Connecting Swift client to: \(socketPath)")
        
        // Load API specification from file
        let specData = try Data(contentsOf: URL(fileURLWithPath: specPath))
        let parser = APISpecificationParser()
        let apiSpec = try parser.parseJSON(specData)
        
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