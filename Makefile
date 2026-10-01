.PHONY: build test app install dmg icons hooks clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install:
	scripts/build-app.sh --install

dmg:
	scripts/build-app.sh --universal
	scripts/make-dmg.sh

icons:
	python3 scripts/gen-icons.py
	swift scripts/gen-app-icon.swift

hooks:
	git config core.hooksPath .githooks
	@echo "hooks on: .githooks"

clean:
	rm -rf .build build dist
