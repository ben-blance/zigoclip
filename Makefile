ZIG=zig
GO=go

ZIG_SRC=clipboard/clipboard.zig
ZIG_BIN=clipboard.exe

GO_SRC=./cmd/zigoclip
GO_BIN=zigoclip.exe

.PHONY: all build zig go clean run-a run-b

ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
RM_CMD = del /Q
else
RM_CMD = rm -f
endif

all: build

build: zig go

# Emitted into the repo root (not clipboard/) so it lands next to
# zigoclip.exe — ipc.Start() launches it via the relative path
# ".\clipboard.exe" from the working directory the Go binary runs in.
zig:
	$(ZIG) build-exe $(ZIG_SRC) -lc -femit-bin=$(ZIG_BIN)

go:
	$(GO) build -o $(GO_BIN) $(GO_SRC)

clean:
	@if exist "$(ZIG_BIN)" del /Q "$(ZIG_BIN)"
	@if exist "$(GO_BIN)" del /Q "$(GO_BIN)"
	@if exist "clipboard.exe.obj" del /Q "clipboard.exe.obj"
	@if exist "clipboard.pdb" del /Q "clipboard.pdb"

run-a: build
	.\$(GO_BIN) -name client-a

run-b: build
	.\$(GO_BIN) -name client-b