ZIG=zig
GO=go

ZIG_SRC=clipboard.zig
ZIG_BIN=clipboard.exe

GO_SRC=main.go
GO_BIN=main.exe

.PHONY: all build zig go clean run-a run-b

all: build

build: zig go

zig:
	$(ZIG) build-exe $(ZIG_SRC) -lc

go:
	$(GO) build -o $(GO_BIN) $(GO_SRC)

clean:
	-del /Q $(ZIG_BIN) 2>nul
	-del /Q $(GO_BIN) 2>nul
	-del /Q clipboard.exe.obj 2>nul
	-del /Q clipboard.pdb 2>nul

run-a: build
	.\$(GO_BIN) -name client-a

run-b: build
	.\$(GO_BIN) -name client-b