// Package discovery finds other Zigoclip instances on the local
// network via UDP broadcast, so the user never has to type an IP.
package discovery

import (
	"fmt"
	"log"
	"net"
	"strings"
	"time"
)

const announceInterval = 2 * time.Second
const discoveryPrefix = "CLIPBOARD_DISCOVERY "

// OnPeerFound is invoked with a discovered peer's device ID and TCP
// address ("host:port") whenever a discovery broadcast from another
// device is seen.
type OnPeerFound func(peerID, address string)

type Discovery struct {
	udpPort  int
	tcpPort  int
	deviceID string

	onPeerFound OnPeerFound
}

func New(udpPort, tcpPort int, deviceID string, onPeerFound OnPeerFound) *Discovery {
	return &Discovery{
		udpPort:     udpPort,
		tcpPort:     tcpPort,
		deviceID:    deviceID,
		onPeerFound: onPeerFound,
	}
}

// Run broadcasts our presence every 2s and listens for peers.
// Blocks — call with `go`.
func (d *Discovery) Run() {
	addr := net.UDPAddr{IP: net.IPv4zero, Port: d.udpPort}

	conn, err := net.ListenUDP("udp4", &addr)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()

	log.Printf("UDP discovery listening on %d", d.udpPort)

	go d.announce(conn)

	buffer := make([]byte, 2048)

	for {
		n, remote, err := conn.ReadFromUDP(buffer)
		if err != nil {
			log.Printf("UDP read error: %v", err)
			continue
		}

		message := string(buffer[:n])

		log.Printf("UDP discovery from %s: %s", remote.IP, message)

		peerID, ok := parseDeviceID(message)
		if !ok {
			continue
		}

		if peerID == d.deviceID {
			continue // don't connect to ourselves
		}

		peer := fmt.Sprintf("%s:%d", remote.IP.String(), d.tcpPort)

		d.onPeerFound(peerID, peer)
	}
}

func (d *Discovery) announce(conn *net.UDPConn) {
	for {
		time.Sleep(announceInterval)

		message := fmt.Sprintf("CLIPBOARD_DISCOVERY %s %d\n", d.deviceID, d.tcpPort)

		// Sending only to 255.255.255.255 lets the OS pick whichever
		// interface is in its routing table, which on a machine with
		// a WSL2/Hyper-V/VPN virtual adapter is often NOT the real
		// Wi-Fi NIC. So we send on every active interface's own
		// subnet broadcast address instead, plus the general address
		// as a fallback.
		targets := append(subnetBroadcastAddrs(), net.IPv4bcast)

		for _, ip := range targets {
			broadcastAddr := &net.UDPAddr{IP: ip, Port: d.udpPort}

			if _, err := conn.WriteToUDP([]byte(message), broadcastAddr); err != nil {
				log.Printf("UDP discovery broadcast to %s failed: %v", ip, err)
			}
		}
	}
}

// subnetBroadcastAddrs returns the directed broadcast address (e.g.
// 192.168.1.255) for every active, non-loopback IPv4 interface on this
// machine.
func subnetBroadcastAddrs() []net.IP {
	var addrs []net.IP

	ifaces, err := net.Interfaces()
	if err != nil {
		log.Printf("Failed to list network interfaces: %v", err)
		return addrs
	}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		ifaceAddrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, a := range ifaceAddrs {
			ipnet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}

			ip4 := ipnet.IP.To4()
			if ip4 == nil || len(ipnet.Mask) != net.IPv4len {
				continue
			}

			bcast := make(net.IP, net.IPv4len)

			for i := 0; i < net.IPv4len; i++ {
				bcast[i] = ip4[i] | ^ipnet.Mask[i]
			}

			addrs = append(addrs, bcast)
		}
	}

	return addrs
}

// parseDeviceID extracts the device ID from a "CLIPBOARD_DISCOVERY
// <id> <port>" message, reporting false if the message isn't ours.
func parseDeviceID(message string) (id string, ok bool) {
	if !strings.HasPrefix(message, discoveryPrefix) {
		return "", false
	}

	rest := strings.TrimPrefix(message, discoveryPrefix)

	id, _, found := strings.Cut(rest, " ")
	if !found {
		return "", false
	}

	return id, true
}