ZIG=zig
GO=go

ZIG_SRC=clipboard/clipboard.zig
ZIG_BIN=clipboard.exe

GO_SRC=./cmd/zigoclip
GO_BIN=zigoclip.exe

TRAY_SRC=gui/tray.zig
TRAY_BIN=tray.exe

.PHONY: all build zig go tray clean run-a run-b run

ifeq ($(OS),Windows_NT)
SHELL := cmd.exe
RM_CMD = del /Q
else
RM_CMD = rm -f
endif

all: build

build: zig go tray

# Emitted into the repo root (not clipboard/) so it lands next to
# zigoclip.exe — ipc.Start() launches it via the relative path
# ".\clipboard.exe" from the working directory the Go binary runs in.
zig:
	$(ZIG) build-exe $(ZIG_SRC) -lc -femit-bin=$(ZIG_BIN)

go:
	$(GO) build -o $(GO_BIN) $(GO_SRC)

# --subsystem windows builds a GUI-subsystem exe (no console window
# flash on launch) — Zig's own flag, not GCC's -mwindows. Needs extra
# Win32 libs beyond -lc for tray/menu (user32, shell32), registry
# (advapi32), and icon (gdi32) APIs.
tray:
	$(ZIG) build-exe $(TRAY_SRC) -lc -luser32 -lshell32 -ladvapi32 -lgdi32 --subsystem windows -femit-bin=$(TRAY_BIN)

clean:
	@if exist "$(ZIG_BIN)" del /Q "$(ZIG_BIN)"
	@if exist "$(GO_BIN)" del /Q "$(GO_BIN)"
	@if exist "$(TRAY_BIN)" del /Q "$(TRAY_BIN)"
	@if exist "clipboard.exe.obj" del /Q "clipboard.exe.obj"
	@if exist "clipboard.pdb" del /Q "clipboard.pdb"
	@if exist "tray.exe.obj" del /Q "tray.exe.obj"
	@if exist "tray.pdb" del /Q "tray.pdb"

# Launches the tray app, which in turn spawns zigoclip.exe (and it, in
# turn, clipboard.exe). This is the real entry point for actual use.
run: build
	.\$(TRAY_BIN)

# Direct agent testing without the tray, useful for dev/debugging
# since it prints logs straight to the console instead of running
# hidden. Two named instances so you can test sync on one machine.
run-a: build
	.\$(GO_BIN) -name client-a

run-b: build
	.\$(GO_BIN) -name client-b