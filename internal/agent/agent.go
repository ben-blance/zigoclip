// Package agent wires together ipc (Zig), network (TCP), discovery
// (UDP), and sync (loop prevention) into one running clipboard agent.
package agent

import (
	"fmt"
	"log"
	"time"

	"zigoclip/internal/discovery"
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
	a.discovery = discovery.New(udpPort, tcpPort, deviceID, a.net.Connect)

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

// handleLocalChange fires when Zig reports the local Windows clipboard
// changed. It tags the change with a fresh event ID, marks that ID
// seen (so an echo from a peer is later ignored), and broadcasts it.
func (a *Agent) handleLocalChange(text string) {
	log.Printf("Clipboard changed: %q", text)

	eventID := fmt.Sprintf("%s-%d", a.deviceID, time.Now().UnixNano())

	a.tracker.MarkSeen(eventID)

	a.net.Broadcast(protocol.New(a.deviceID, eventID, text))
}

// handleRemoteMessage fires when a peer sends us a clipboard update
// over TCP.
func (a *Agent) handleRemoteMessage(msg protocol.Message) {
	if a.tracker.MarkSeen(msg.EventID) {
		log.Printf("Ignoring already-seen event %s", msg.EventID)
		return
	}

	if msg.Type != protocol.TypeClipboardUpdate {
		return
	}

	if err := a.zig.SetClipboard(msg.Payload); err != nil {
		log.Printf("Failed to set clipboard: %v", err)
	}

	// We do NOT broadcast this again — the event ID is already marked
	// seen, so this update stops here instead of bouncing back out.
}