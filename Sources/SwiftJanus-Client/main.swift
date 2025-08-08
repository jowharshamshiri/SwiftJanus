import Foundation
import SwiftJanus

struct SwiftJanusClient {
    static func main() async throws {
        // Parse command line arguments
        let arguments = CommandLine.arguments
        var socketPath = "/tmp/swift_test_server.sock"
        var manifestPath = "test-manifest.json"
        
        // Parse command line arguments
        for i in 0..<arguments.count - 1 {
            if arguments[i] == "--socket-path" {
                socketPath = arguments[i + 1]
            } else if arguments[i] == "--manifest" {
                manifestPath = arguments[i + 1]
            }
        }
        
        print("Connecting Swift client to: \(socketPath)")
        
        // Manifest loading removed - manifest fetched dynamically from server
        
        // Create SOCK_DGRAM client
        let client = try await JanusClient(
            socketPath: socketPath,
            maxMessageSize: 65536,
            defaultTimeout: 30.0,
            datagramTimeout: 5.0,
            enableValidation: true
        )
        
        print("Testing ping request...")
        
        // Test ping request
        do {
            let response = try await client.sendRequest(
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
        
        print("Testing echo request...")
        
        // Test echo request
        do {
            let response = try await client.sendRequest(
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

Task {
    try await SwiftJanusClient.main()
}