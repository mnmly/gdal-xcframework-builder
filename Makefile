GDAL_VERSION ?=

.PHONY: xcframework release clean distclean check-version verify-ios

xcframework: check-version
	./build.sh $(GDAL_VERSION)

# Also build iOS slices (gdal + proj xcframeworks).
xcframework-ios: check-version
	BUILD_IOS=1 ./build.sh $(GDAL_VERSION)

release: check-version
	RELEASE=1 ./build.sh $(GDAL_VERSION)

release-ios: check-version
	BUILD_IOS=1 RELEASE=1 ./build.sh $(GDAL_VERSION)

# Build the verify/ios-sample app against output/{gdal,proj}.xcframework
# and run its tests on the first available iPhone simulator. Requires
# Xcode + a booted/available iOS simulator. Compile-only for device.
verify-ios:
	cd verify/ios-sample && \
	    xcodebuild -scheme IOSSample \
	        -destination 'generic/platform=iOS' \
	        -derivedDataPath .build build
	cd verify/ios-sample && \
	    SIM=$$(xcrun simctl list devices available | grep -E '^ +iPhone' \
	            | head -1 | sed 's/ *(.*//' | sed 's/^ *//') && \
	    xcodebuild -scheme IOSSample \
	        -destination "platform=iOS Simulator,name=$$SIM" \
	        -derivedDataPath .build test

# Compare the current macOS slice against the captured baseline.
# Used after the iOS work to confirm the macOS pipeline didn't regress.
verify-macos-baseline:
	./scripts/diff-frameworks.sh \
	    verify/baseline/gdal.xcframework/macos-arm64/gdal.framework \
	    output/gdal.xcframework/macos-arm64/gdal.framework

check-version:
	@if [ -z "$(GDAL_VERSION)" ]; then \
		echo "Usage: make GDAL_VERSION=3.12.4 [xcframework|xcframework-ios|release|release-ios|verify-ios]"; \
		exit 1; \
	fi

clean:
	rm -rf work

distclean: clean
	rm -rf output
	rm -rf verify/ios-sample/.build
