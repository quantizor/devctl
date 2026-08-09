PREFIX ?= $(HOME)/.local
# Resolved lazily, so only the signing targets pay for the keychain lookup, and
# `make test` never does. Falls back to "-" (ad-hoc) where no Developer ID
# identity exists, which is what a fresh clone and CI get. Override explicitly
# with SIGN_IDENTITY=... to pick a specific identity or to force ad-hoc.
SIGN_IDENTITY ?= $(shell scripts/signing-identity.sh)

.PHONY: build test app dmg install clean

build:
	swift build -c release

test:
	swift test

app: build
	scripts/make-app-bundle.sh "$(SIGN_IDENTITY)"

dmg: app
	scripts/make-dmg.sh "$(SIGN_IDENTITY)"

install: build app
	mkdir -p $(PREFIX)/bin
	install .build/release/devctl $(PREFIX)/bin/devctl
	install .build/release/devctld $(PREFIX)/bin/devctld
	ditto devctl.app /Applications/devctl.app
	$(PREFIX)/bin/devctl daemon install

clean:
	swift package clean
	rm -rf devctl.app dist
