#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache .build/swift-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/swift-cache" -parse-as-library \
  Sources/SoundShelf/AppRestartController.swift Sources/SoundShelf/MicrophoneMuteController.swift Sources/SoundShelf/MediaModel.swift Sources/SoundShelf/AudioController.swift Sources/SoundShelf/MuteControllers.swift tests/Swift/MuteTests.swift tests/Swift/MediaModelTests.swift tests/Swift/AppRestartTests.swift tests/Swift/MicrophoneMuteTests.swift -o .build/media-model-tests
.build/media-model-tests
