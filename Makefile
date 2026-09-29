.PHONY: build test

build:
	go build -trimpath -o vpsagent ./cmd/vpsagent

test:
	go test ./...
