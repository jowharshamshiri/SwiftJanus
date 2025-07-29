import Foundation
import Network
import SwiftUnixSockAPI

// Basic Swift server without complex async/await patterns
func main() {
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
            i += 1  // Skip next argument since we consumed it
        } else if argument.hasPrefix("--spec=") {
            let parts = argument.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                specPath = String(parts[1])
            }
        } else if argument == "--spec" && i + 1 < arguments.count {
            specPath = arguments[i + 1]
            i += 1  // Skip next argument since we consumed it
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
    
    print("Creating simple Unix socket server...")
    fflush(stdout)
    
    // Create a simple Unix socket server using BSD sockets
    let serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverSocket != -1 else {
        print("ERROR: Failed to create socket")
        exit(1)
    }
    
    var serverAddr = sockaddr_un()
    serverAddr.sun_family = sa_family_t(AF_UNIX)
    
    guard socketPath.count < MemoryLayout.size(ofValue: serverAddr.sun_path) else {
        print("ERROR: Socket path too long")
        exit(1)
    }
    
    _ = withUnsafeMutableBytes(of: &serverAddr.sun_path) { ptr in
        socketPath.withCString { cString in
            strcpy(ptr.bindMemory(to: CChar.self).baseAddress, cString)
        }
    }
    
    let addrSize = MemoryLayout<sockaddr_un>.size
    let bindResult = withUnsafePointer(to: &serverAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(serverSocket, sockPtr, socklen_t(addrSize))
        }
    }
    
    guard bindResult == 0 else {
        print("ERROR: Failed to bind socket")
        close(serverSocket)
        exit(1)
    }
    
    guard listen(serverSocket, 5) == 0 else {
        print("ERROR: Failed to listen on socket")
        close(serverSocket)
        exit(1)
    }
    
    print("Swift server listening on \(socketPath). Press Ctrl+C to stop.")
    fflush(stdout)
    
    // Simple accept loop
    while true {
        let clientSocket = accept(serverSocket, nil, nil)
        if clientSocket != -1 {
            handleClient(clientSocket)
        }
    }
}

func handleClient(_ clientSocket: Int32) {
    defer { close(clientSocket) }
    
    var buffer = Data(count: 8192)
    let bytesRead = buffer.withUnsafeMutableBytes { ptr in
        recv(clientSocket, ptr.baseAddress, 8192, 0)
    }
    
    if bytesRead > 0 {
        let data = buffer.prefix(bytesRead)
        
        // Try to parse the message with length prefix
        if bytesRead >= 4 {
            let lengthBytes = data.prefix(4)
            let messageLength = lengthBytes.withUnsafeBytes { bytes in
                bytes.load(as: UInt32.self).bigEndian
            }
            
            if messageLength > 0 && messageLength <= bytesRead - 4 {
                let messageData = data.dropFirst(4).prefix(Int(messageLength))
                
                // Try to parse as JSON command
                if let command = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
                   let commandName = command["command"] as? String,
                   let commandId = command["id"] as? String {
                    
                    print("Received command: \(commandName)")
                    
                    // Create response
                    var response: [String: Any] = [
                        "commandId": commandId,
                        "channelId": "test",
                        "success": true,
                        "timestamp": ISO8601DateFormatter().string(from: Date())
                    ]
                    
                    if commandName == "ping" {
                        response["result"] = [
                            "pong": true,
                            "timestamp": ISO8601DateFormatter().string(from: Date())
                        ]
                    } else if commandName == "echo" {
                        if let args = command["args"] as? [String: Any],
                           let message = args["message"] as? String {
                            response["result"] = ["echo": message]
                        } else {
                            response["result"] = ["echo": "No message provided"]
                        }
                    }
                    
                    // Send response
                    if let responseData = try? JSONSerialization.data(withJSONObject: response) {
                        let responseLength = UInt32(responseData.count).bigEndian
                        
                        // Send length prefix
                        withUnsafeBytes(of: responseLength) { bytes in
                            send(clientSocket, bytes.baseAddress, 4, 0)
                        }
                        
                        // Send response data
                        responseData.withUnsafeBytes { bytes in
                            send(clientSocket, bytes.baseAddress, responseData.count, 0)
                        }
                    }
                }
            }
        }
    }
}

// Run the main function
main()