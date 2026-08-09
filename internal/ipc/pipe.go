// Package ipc manages the Zig clipboard subprocess and speaks its
// line-based protocol over stdin/stdout. Nothing here knows about
// TCP, UDP, peers, or event IDs — its world is just the local
// clipboard.
package ipc

import (
	"bufio"
	"encoding/base64"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
)

// Zig wraps the running clipboard.exe process.
type Zig struct {
	in  io.WriteCloser
	out io.ReadCloser
}

// OnClipboardChange is invoked with decoded text whenever the Zig
// process reports the local Windows clipboard changed.
type OnClipboardChange func(text string)

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

	return &Zig{in: stdin, out: stdout}, nil
}

// Watch reads clipboard.exe's stdout, invoking onChange for every
// clipboard update line. Blocks until the pipe closes — call with `go`.
func (z *Zig) Watch(onChange OnClipboardChange) {
	scanner := bufio.NewScanner(z.out)

	const prefix = "CLIPBOARD "

	for scanner.Scan() {
		line := scanner.Text()

		if line == "READY" {
			log.Println("Zig clipboard handler ready")
			continue
		}

		if len(line) < len(prefix) || line[:len(prefix)] != prefix {
			continue
		}

		encoded := line[len(prefix):]

		data, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			log.Printf("Invalid clipboard data: %v", err)
			continue
		}

		onChange(string(data))
	}
}

// SetClipboard tells the Zig process to write text to the local
// Windows clipboard.
func (z *Zig) SetClipboard(text string) error {
	encoded := base64.StdEncoding.EncodeToString([]byte(text))

	_, err := fmt.Fprintf(z.in, "SET %s\n", encoded)

	return err
}