package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"
	"time"
)

const (
	udpPort = 42425
	tcpPort = 42424
)

type Message struct {
	Version         int    `json:"version"`
	Type            string `json:"type"`
	DeviceID        string `json:"device_id"`
	EventID         string `json:"event_id"`
	ClipboardFormat string `json:"clipboard_format"`
	Payload         string `json:"payload"`
}

type Agent struct {
	deviceID string

	mu          sync.Mutex
	connections map[net.Conn]bool

	seenEvents map[string]bool

	zigIn  io.WriteCloser
	zigOut io.ReadCloser
}

func main() {
	name := flag.String("name", "client", "device name")
	flag.Parse()

	deviceID := fmt.Sprintf("%s-%d", *name, time.Now().UnixNano())

	agent := &Agent{
		deviceID:    deviceID,
		connections: make(map[net.Conn]bool),
		seenEvents:  make(map[string]bool),
	}

	log.Printf("=================================")
	log.Printf("Clipboard Agent")
	log.Printf("Device: %s", deviceID)
	log.Printf("TCP:    %d", tcpPort)
	log.Printf("UDP:    %d", udpPort)
	log.Printf("=================================")

	if err := agent.startZig(); err != nil {
		log.Fatal(err)
	}

	go agent.startTCPServer()
	go agent.startUDPDiscovery()

	go agent.readFromZig()

	select {}
}

func (a *Agent) startZig() error {
	cmd := exec.Command(".\\clipboard.exe")

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}

	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return err
	}

	a.zigIn = stdin
	a.zigOut = stdout

	log.Println("Started Zig clipboard process")

	return nil
}

func (a *Agent) readFromZig() {
	scanner := bufio.NewScanner(a.zigOut)

	for scanner.Scan() {
		line := scanner.Text()

		if line == "READY" {
			log.Println("Zig clipboard handler ready")
			continue
		}

		if len(line) < len("CLIPBOARD ") {
			continue
		}

		if line[:len("CLIPBOARD ")] != "CLIPBOARD " {
			continue
		}

		encoded := line[len("CLIPBOARD "):]

		data, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			log.Printf("Invalid clipboard data: %v", err)
			continue
		}

		log.Printf("Clipboard changed: %q", string(data))

		eventID := fmt.Sprintf(
			"%s-%d",
			a.deviceID,
			time.Now().UnixNano(),
		)

		msg := Message{
			Version:         1,
			Type:            "clipboard_update",
			DeviceID:        a.deviceID,
			EventID:         eventID,
			ClipboardFormat: "text",
			Payload:         string(data),
		}

		a.broadcast(msg)
	}
}

func (a *Agent) startTCPServer() {
	addr := fmt.Sprintf(":%d", tcpPort)

	listener, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}

	log.Printf("TCP listening on %s", addr)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("TCP accept error: %v", err)
			continue
		}

		log.Printf("TCP connection from %s", conn.RemoteAddr())

		a.addConnection(conn)

		go a.handleConnection(conn)
	}
}

func (a *Agent) handleConnection(conn net.Conn) {
	defer func() {
		a.removeConnection(conn)
		conn.Close()
	}()

	scanner := bufio.NewScanner(conn)

	for scanner.Scan() {
		var msg Message

		if err := json.Unmarshal(scanner.Bytes(), &msg); err != nil {
			log.Printf("Invalid message: %v", err)
			continue
		}

		log.Printf(
			"Received event=%s origin=%s payload=%q",
			msg.EventID,
			msg.DeviceID,
			msg.Payload,
		)

		a.handleMessage(msg)
	}
}

func (a *Agent) handleMessage(msg Message) {
	// Loop prevention.
	a.mu.Lock()

	if a.seenEvents[msg.EventID] {
		a.mu.Unlock()

		log.Printf(
			"Ignoring already-seen event %s",
			msg.EventID,
		)

		return
	}

	a.seenEvents[msg.EventID] = true

	a.mu.Unlock()

	if msg.Type != "clipboard_update" {
		return
	}

	// Tell Zig to update the local clipboard.
	if err := a.setClipboard(msg.Payload); err != nil {
		log.Printf("Failed to set clipboard: %v", err)
		return
	}

	// IMPORTANT:
	//
	// We DO NOT broadcast this message again.
	//
	// Otherwise:
	//
	// A -> B -> A -> B -> A ...
	//
	// The event ID is already marked as seen.
}

func (a *Agent) setClipboard(text string) error {
	encoded := base64.StdEncoding.EncodeToString([]byte(text))

	_, err := fmt.Fprintf(
		a.zigIn,
		"SET %s\n",
		encoded,
	)

	return err
}

func (a *Agent) broadcast(msg Message) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("JSON error: %v", err)
		return
	}

	data = append(data, '\n')

	a.mu.Lock()
	defer a.mu.Unlock()

	for conn := range a.connections {
		if _, err := conn.Write(data); err != nil {
			log.Printf(
				"Failed to send to %s: %v",
				conn.RemoteAddr(),
				err,
			)
		}
	}
}

func (a *Agent) addConnection(conn net.Conn) {
	a.mu.Lock()
	defer a.mu.Unlock()

	a.connections[conn] = true
}

func (a *Agent) removeConnection(conn net.Conn) {
	a.mu.Lock()
	defer a.mu.Unlock()

	delete(a.connections, conn)
}

func (a *Agent) startUDPDiscovery() {
	addr := net.UDPAddr{
		IP:   net.IPv4zero,
		Port: udpPort,
	}

	conn, err := net.ListenUDP("udp4", &addr)
	if err != nil {
		log.Fatal(err)
	}

	defer conn.Close()

	log.Printf("UDP discovery listening on %d", udpPort)

	go func() {
		for {
			time.Sleep(2 * time.Second)

			message := fmt.Sprintf(
				"CLIPBOARD_DISCOVERY %s %d\n",
				a.deviceID,
				tcpPort,
			)

			broadcastAddr := &net.UDPAddr{
				IP:   net.IPv4bcast,
				Port: udpPort,
			}

			_, err := conn.WriteToUDP(
				[]byte(message),
				broadcastAddr,
			)

			if err != nil {
				log.Printf(
					"UDP discovery broadcast failed: %v",
					err,
				)
			}
		}
	}()

	buffer := make([]byte, 2048)

	for {
		n, remote, err := conn.ReadFromUDP(buffer)
		if err != nil {
			log.Printf("UDP read error: %v", err)
			continue
		}

		message := string(buffer[:n])

		log.Printf(
			"UDP discovery from %s: %s",
			remote.IP,
			message,
		)

		if len(message) < len("CLIPBOARD_DISCOVERY ") {
			continue
		}

		if message[:len("CLIPBOARD_DISCOVERY ")] !=
			"CLIPBOARD_DISCOVERY " {
			continue
		}

		// Don't connect to ourselves.
		if containsDeviceID(message, a.deviceID) {
			continue
		}

		// For the prototype we know the TCP port.
		peer := fmt.Sprintf(
			"%s:%d",
			remote.IP.String(),
			tcpPort,
		)

		go a.connectToPeer(peer)
	}
}

func containsDeviceID(message string, id string) bool {
	return len(message) > len(id) &&
		message[len("CLIPBOARD_DISCOVERY "):len("CLIPBOARD_DISCOVERY ")+len(id)] == id
}

func (a *Agent) connectToPeer(address string) {
	// Check if we're already connected.
	a.mu.Lock()

	for conn := range a.connections {
		if conn.RemoteAddr().String() == address {
			a.mu.Unlock()
			return
		}
	}

	a.mu.Unlock()

	conn, err := net.DialTimeout(
		"tcp",
		address,
		2*time.Second,
	)

	if err != nil {
		return
	}

	log.Printf("Connected to peer %s", address)

	a.addConnection(conn)

	go a.handleConnection(conn)
}