// Package network owns TCP peer connections: accepting inbound
// connections, dialing outbound ones, and broadcasting messages to
// every connected peer.
package network

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"

	"zigoclip/internal/protocol"
)

const dialTimeout = 2 * time.Second

// OnMessage is invoked for every message received from a peer, with
// msg.Payload already fully read.
type OnMessage func(msg protocol.Message)

type Server struct {
	port      int
	onMessage OnMessage

	mu          sync.Mutex
	connections map[net.Conn]bool
}

func NewServer(port int, onMessage OnMessage) *Server {
	return &Server{
		port:        port,
		onMessage:   onMessage,
		connections: make(map[net.Conn]bool),
	}
}

// Listen accepts inbound peer connections. Blocks — call with `go`.
func (s *Server) Listen() {
	addr := fmt.Sprintf(":%d", s.port)

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

		s.addConnection(conn)
		go s.handleConnection(conn)
	}
}

// Connect dials a peer by "host:port", skipping if already connected.
// Matches discovery.OnPeerFound, so it can be passed straight in.
func (s *Server) Connect(address string) {
	s.mu.Lock()
	for conn := range s.connections {
		if conn.RemoteAddr().String() == address {
			s.mu.Unlock()
			return
		}
	}
	s.mu.Unlock()

	conn, err := net.DialTimeout("tcp", address, dialTimeout)
	if err != nil {
		return
	}

	log.Printf("Connected to peer %s", address)

	s.addConnection(conn)
	go s.handleConnection(conn)
}

// Broadcast sends msg to every connected peer: a JSON header line
// (everything except Payload) immediately followed by the raw
// payload bytes. No base64 — large binary payloads (images) go out
// as-is.
func (s *Server) Broadcast(msg protocol.Message) {
	msg.PayloadSize = len(msg.Payload)

	header, err := json.Marshal(msg)
	if err != nil {
		log.Printf("JSON error: %v", err)
		return
	}

	header = append(header, '\n')

	s.mu.Lock()
	defer s.mu.Unlock()

	for conn := range s.connections {
		if _, err := conn.Write(header); err != nil {
			log.Printf("Failed to send to %s: %v", conn.RemoteAddr(), err)
			continue
		}

		if _, err := conn.Write(msg.Payload); err != nil {
			log.Printf("Failed to send payload to %s: %v", conn.RemoteAddr(), err)
		}
	}
}

func (s *Server) handleConnection(conn net.Conn) {
	defer func() {
		s.removeConnection(conn)
		conn.Close()
	}()

	reader := bufio.NewReader(conn)

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			return
		}

		var msg protocol.Message

		if err := json.Unmarshal(line, &msg); err != nil {
			// The stream is now desynced — we don't know where the
			// next header starts — so we can't just continue.
			log.Printf("Invalid message header, dropping connection: %v", err)
			return
		}

		if msg.PayloadSize < 0 || msg.PayloadSize > protocol.MaxPayloadSize {
			log.Printf("Rejecting message with payload_size=%d", msg.PayloadSize)
			return
		}

		payload := make([]byte, msg.PayloadSize)

		if _, err := io.ReadFull(reader, payload); err != nil {
			log.Printf("Failed to read payload: %v", err)
			return
		}

		msg.Payload = payload

		log.Printf(
			"Received event=%s origin=%s format=%s bytes=%d",
			msg.EventID, msg.DeviceID, msg.ClipboardFormat, len(payload),
		)

		s.onMessage(msg)
	}
}

func (s *Server) addConnection(conn net.Conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.connections[conn] = true
}

func (s *Server) removeConnection(conn net.Conn) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.connections, conn)
}