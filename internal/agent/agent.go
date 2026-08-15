// Package agent wires together ipc (Zig), network (TCP), discovery
// (UDP), and sync (loop prevention) into one running clipboard agent.
package agent

import (
	"fmt"
	"log"
	"time"

	"zigoclip/internal/discovery"
	"zigoclip/internal/imagecodec"
	"zigoclip/internal/ipc"
	"zigoclip/internal/network"
	"zigoclip/internal/protocol"
	syncpkg "zigoclip/internal/sync"
)

const (
	udpPort = 42425
	tcpPort = 42424
)

type Agent struct {
	deviceID string

	zig       *ipc.Zig
	net       *network.Server
	discovery *discovery.Discovery
	tracker   *syncpkg.Tracker
}

// New starts the Zig clipboard subprocess and assembles an Agent ready
// to Run. Networking doesn't start until Run is called.
func New(name string) (*Agent, error) {
	deviceID := fmt.Sprintf("%s-%d", name, time.Now().UnixNano())

	zig, err := ipc.Start()
	if err != nil {
		return nil, err
	}

	a := &Agent{
		deviceID: deviceID,
		zig:      zig,
		tracker:  syncpkg.NewTracker(),
	}

	a.net = network.NewServer(tcpPort, a.handleRemoteMessage)
	a.discovery = discovery.New(udpPort, tcpPort, deviceID, a.considerPeer)

	return a, nil
}

// Run starts the TCP server, UDP discovery, and Zig watcher, then
// blocks forever.
func (a *Agent) Run() {
	log.Printf("=================================")
	log.Printf("Clipboard Agent")
	log.Printf("Device: %s", a.deviceID)
	log.Printf("TCP:    %d", tcpPort)
	log.Printf("UDP:    %d", udpPort)
	log.Printf("=================================")

	go a.net.Listen()
	go a.discovery.Run()
	go a.zig.Watch(a.handleLocalChange)

	select {}
}

// considerPeer decides whether to dial a discovered peer. Both devices
// see each other's discovery broadcasts, so without a tie-break both
// would dial out and we'd end up with two TCP connections per pair.
// Only the lexicographically smaller device ID dials; the other side
// just waits to accept that connection.
func (a *Agent) considerPeer(peerID, address string) {
	if a.deviceID > peerID {
		return
	}

	a.net.Connect(address)
}

// handleLocalChange fires when Zig reports the local Windows clipboard
// changed. format/data are what Zig read straight off the clipboard:
// raw text, or a raw CF_DIB blob for images. It tags the change with
// a fresh event ID, marks that ID seen (so an echo from a peer is
// later ignored), and broadcasts it.
func (a *Agent) handleLocalChange(format string, data []byte) {
	payload := data

	if format == protocol.FormatImage {
		log.Printf("Clipboard changed: image (%d bytes DIB)", len(data))

		img, err := imagecodec.DecodeDIB(data)
		if err != nil {
			log.Printf("Failed to decode clipboard image: %v", err)
			return
		}

		png, err := imagecodec.EncodePNG(img)
		if err != nil {
			log.Printf("Failed to PNG-encode clipboard image: %v", err)
			return
		}

		log.Printf("Encoded to %d bytes PNG for transfer", len(png))

		payload = png
	} else {
		log.Printf("Clipboard changed: %q", string(data))
	}

	eventID := fmt.Sprintf("%s-%d", a.deviceID, time.Now().UnixNano())

	a.tracker.MarkSeen(eventID)

	a.net.Broadcast(protocol.New(a.deviceID, eventID, format, payload))
}

// handleRemoteMessage fires when a peer sends us a clipboard update
// over TCP. Image payloads arrive as PNG and are converted back to a
// raw CF_DIB blob before being handed to Zig.
func (a *Agent) handleRemoteMessage(msg protocol.Message) {
	if a.tracker.MarkSeen(msg.EventID) {
		log.Printf("Ignoring already-seen event %s", msg.EventID)
		return
	}

	if msg.Type != protocol.TypeClipboardUpdate {
		return
	}

	payload := msg.Payload

	if msg.ClipboardFormat == protocol.FormatImage {
		img, err := imagecodec.DecodePNG(payload)
		if err != nil {
			log.Printf("Failed to decode PNG from peer: %v", err)
			return
		}

		dib, err := imagecodec.EncodeDIB(img)
		if err != nil {
			log.Printf("Failed to encode image for clipboard: %v", err)
			return
		}

		payload = dib
	}

	if err := a.zig.SetClipboard(msg.ClipboardFormat, payload); err != nil {
		log.Printf("Failed to set clipboard: %v", err)
	}

	// We do NOT broadcast this again — the event ID is already marked
	// seen, so this update stops here instead of bouncing back out.
}