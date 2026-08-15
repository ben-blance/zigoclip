// Package ipc manages the Zig clipboard subprocess and speaks its
// framing over stdin/stdout: a small text header line
// ("CLIPBOARD <format> <size>" or "SET <format> <size>") followed by
// exactly <size> raw bytes. No base64 — Go's default line-scanning
// caps out at 64KB and images regularly exceed that, and encoding
// would cost ~33% for nothing. Nothing here knows about TCP, UDP,
// peers, or event IDs — its world is just the local clipboard.
package ipc

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"zigoclip/internal/protocol"
)

// Zig wraps the running clipboard.exe process.
type Zig struct {
	in  io.WriteCloser
	out *bufio.Reader
}

// OnClipboardChange is invoked with the clipboard format
// (protocol.FormatText or protocol.FormatImage) and raw payload bytes
// whenever the Zig process reports the local clipboard changed.
type OnClipboardChange func(format string, data []byte)

// Start launches clipboard.exe (expected alongside the Go binary) and
// wires up its stdin/stdout pipes.
func Start() (*Zig, error) {
	cmd := exec.Command(".\\clipboard.exe")

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}

	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return nil, err
	}

	log.Println("Started Zig clipboard process")

	return &Zig{in: stdin, out: bufio.NewReader(stdout)}, nil
}

// Watch reads clipboard.exe's stdout, invoking onChange for every
// clipboard update. Blocks until the pipe closes — call with `go`.
func (z *Zig) Watch(onChange OnClipboardChange) {
	for {
		line, err := z.out.ReadString('\n')
		if err != nil {
			return
		}

		line = strings.TrimRight(line, "\r\n")

		if line == "READY" {
			log.Println("Zig clipboard handler ready")
			continue
		}

		format, size, ok := parseHeader(line, "CLIPBOARD")
		if !ok {
			continue
		}

		if size < 0 || size > protocol.MaxPayloadSize {
			log.Printf("Rejecting clipboard payload of size %d", size)
			return
		}

		data := make([]byte, size)

		if _, err := io.ReadFull(z.out, data); err != nil {
			log.Printf("Failed to read clipboard payload: %v", err)
			return
		}

		onChange(format, data)
	}
}

// SetClipboard tells the Zig process to write data to the local
// Windows clipboard as the given format (protocol.FormatText or
// protocol.FormatImage).
func (z *Zig) SetClipboard(format string, data []byte) error {
	if _, err := fmt.Fprintf(z.in, "SET %s %d\n", format, len(data)); err != nil {
		return err
	}

	_, err := z.in.Write(data)

	return err
}

// parseHeader parses a "<prefix> <format> <size>" line.
func parseHeader(line, prefix string) (format string, size int, ok bool) {
	fields := strings.Fields(line)

	if len(fields) != 3 || fields[0] != prefix {
		return "", 0, false
	}

	n, err := strconv.Atoi(fields[2])
	if err != nil || n < 0 {
		return "", 0, false
	}

	return fields[1], n, true
}