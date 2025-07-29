import Foundation
import SwiftUnixSockAPI

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
        
        print("Starting Swift Unix Socket API Server on: \(socketPath)")
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
            
            // Create UnixSockAPIClient for server mode
            let client = try await UnixSockAPIClient(
                socketPath: socketPath,
                channelId: "test",
                apiSpec: apiSpec,
                config: .default
            )
            
            // Register command handlers using the library
            try await client.registerCommandHandler("ping") { command, context in
                print("Received ping command: \(command.id)")
                return [
                    "pong": AnyCodable(true),
                    "timestamp": AnyCodable(ISO8601DateFormatter().string(from: Date()))
                ]
            }
            
            try await client.registerCommandHandler("echo") { command, context in
                print("Received echo command: \(command.id)")
                if let args = command.args,
                   let message = args["message"]?.value as? String {
                    return ["echo": AnyCodable(message)]
                } else {
                    return ["echo": AnyCodable("No message provided")]
                }
            }
            
            print("Command handlers registered")
            print("Swift server listening on \(socketPath). Press Ctrl+C to stop.")
            fflush(stdout)
            
            // Start listening using the library
            try await client.startListening()
            
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