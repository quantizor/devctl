PREFIX ?= $(HOME)/.local
SIGN_IDENTITY ?= -

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
