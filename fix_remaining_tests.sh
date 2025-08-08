#!/bin/bash

# Fix remaining compilation errors in test files

# Remove all ChannelManifest references and replace with ModelManifest
for file in Tests/SwiftJanusTests/*.swift; do
    echo "Fixing $file"
    
    # Replace ChannelManifest definitions with simpler manifest creation
    sed -i '' -E 's/let channelManifest = ChannelManifest\([^)]*\)/\/\/ Channel manifest removed/g' "$file"
    
    # Replace channels: parameter with models:
    sed -i '' -E 's/channels: \["[^"]+": channelManifest\]/models: ["testModel": ModelManifest(type: .object, properties: [:])]/g' "$file"
    
    # Fix any remaining channelId parameters in JanusClient constructors
    sed -i '' -E 's/,[ ]*channelId:[ ]*"[^"]+"//' "$file"
    sed -i '' -E 's/channelId:[ ]*"[^"]+",[ ]*//' "$file"
done

echo "Fixes applied"