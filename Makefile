GDAL_VERSION ?=

.PHONY: xcframework release clean distclean check-version

xcframework: check-version
	./build.sh $(GDAL_VERSION)

release: check-version
	RELEASE=1 ./build.sh $(GDAL_VERSION)

check-version:
	@if [ -z "$(GDAL_VERSION)" ]; then \
		echo "Usage: make GDAL_VERSION=3.12.4 [xcframework|release]"; \
		exit 1; \
	fi

clean:
	rm -rf work

distclean: clean
	rm -rf output
