#!/bin/bash
set -eu
cd "$(dirname "$0")"
DEV=/Applications/Xcode.app/Contents/Developer
SWIFTC=$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
SDK=$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
FW=$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks
LIB=$DEV/Platforms/MacOSX.platform/Developer/usr/lib
OUT=/tmp/stbundle/SpeechTextTests.xctest
rm -rf /tmp/stbundle && mkdir -p "$OUT/Contents/MacOS"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SpeechTextTests</string>
<key>CFBundleIdentifier</key><string>com.speechtext.tests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
SRC=(SpeechText/SpeechTextTests/PureLogicTests.swift SpeechText/SpeechTextTests/AudioPipelineTests.swift
     SpeechText/SpeechTextTests/LocalModelsTests.swift)
for f in Settings STTProvider AudioBufferWriter DebugLog LLMProvider PromptPresets \
         TextRefinementService StreamingSTTProvider RecordingConfiguration \
         TranscriptSpan TranscriptMerge InsertionLedger DeliveryTier FinalizePass TranscriptCleanup \
         FocusContext SystemCapabilities LocalModelCatalog OllamaProvider; do
  SRC+=("SpeechText/SpeechText/$f.swift")
done
"$SWIFTC" -emit-library -o "$OUT/Contents/MacOS/SpeechTextTests" \
  -module-name SpeechTextTests -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -F "$FW" -I "$LIB" -L "$LIB" -Xlinker -bundle \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  "${SRC[@]}"
DYLD_FRAMEWORK_PATH="$FW" DYLD_LIBRARY_PATH="$LIB" "$DEV/usr/bin/xctest" "$OUT"
