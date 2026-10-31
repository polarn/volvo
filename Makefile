DESTDIR ?= $(HOME)/.local/bin

.PHONY: build clean install

build:
	go build -o ./build/volvo-ctl ./cmd/volvo-ctl

install: build
	@mkdir -p $(DESTDIR)
	rm -f $(DESTDIR)/volvo-ctl
	cp ./build/volvo-ctl $(DESTDIR)/

clean:
	rm -rf ./build
