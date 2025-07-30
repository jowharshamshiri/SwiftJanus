import Foundation
import SwiftJanus

func main() async {
        // Immediate output to verify the binary starts
        print("Swift server binary started successfully")
        fflush(stdout)
        
        // Parse command line arguments
        let arguments = CommandLine.arguments
        var socketPath = "/tmp/swift_test_server.sock"
        var specPath = "test-api-spec.json"
        
        print("Arguments: \(arguments)")
        
        // Handle both --key=value and --key value formats
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            
            if argument.hasPrefix("--socket-path=") {
                let parts = argument.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    socketPath = String(parts[1])
                }
            } else if argument == "--socket-path" && i + 1 < arguments.count {
                socketPath = arguments[i + 1]
                i += 1
            } else if argument.hasPrefix("--spec=") {
                let parts = argument.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    specPath = String(parts[1])
                }
            } else if argument == "--spec" && i + 1 < arguments.count {
                specPath = arguments[i + 1]
                i += 1
            }
            
            i += 1
        }
        
        print("Starting Swift Janus Server on: \(socketPath)")
        print("Loading spec from: \(specPath)")
        fflush(stdout)
        
        // Remove existing socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Check spec file exists
        guard FileManager.default.fileExists(atPath: specPath) else {
            print("ERROR: Spec file not found at: \(specPath)")
            exit(1)
        }
        
        do {
            // Load API specification using the library
            let parser = APISpecificationParser()
            let specData = try Data(contentsOf: URL(fileURLWithPath: specPath))
            let apiSpec = try parser.parseJSON(specData)
            
            print("API specification loaded successfully")
            print("Channels: \(apiSpec.channels.keys.joined(separator: ", "))")
            fflush(stdout)
            
            // Create SOCK_DGRAM server using high-level API
            let server = UnixDatagramServer()
            
            // Register command handlers (defaults already included, these override them)
            server.registerHandler("ping") { command in
                print("Custom ping handler: \(command.id)")
                return .success([
                    "pong": AnyCodable(true),
                    "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date())),
                    "server": AnyCodable("Swift")
                ])
            }
            
            server.registerHandler("get_info") { command in
                print("Custom get_info handler: \(command.id)")
                return .success([
                    "server": AnyCodable("Swift Janus"),
                    "version": AnyCodable("1.0.0"),
                    "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date())),
                    "socket_path": AnyCodable(socketPath)
                ])
            }
            
            print("Command handlers registered")
            print("Swift server listening on \(socketPath). Press Ctrl+C to stop.")
            fflush(stdout)
            
            // Start listening using the high-level server API
            try await server.startListening(socketPath)
            
            // Keep the server running
            try await Task.sleep(nanoseconds: UInt64.max)
            
        } catch {
            print("ERROR: Failed to start server: \(error)")
            exit(1)
        }
}

// Run the async main function
Task {
    await main()
}

// Keep the program running
RunLoop.main.run()