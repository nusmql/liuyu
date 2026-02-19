.PHONY: build release bundle test clean run

build:
	swift build

release:
	swift build -c release

bundle:
	./scripts/bundle.sh

test:
	swift test

clean:
	rm -rf .build build

run: bundle
	open build/Liuyu.app
