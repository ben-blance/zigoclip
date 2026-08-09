// Package discovery finds other Zigoclip instances on the local
// network via UDP broadcast, so the user never has to type an IP.
package discovery

import (
	"fmt"
	"log"
	"net"
	"time"
)

const announceInterval = 2 * time.Second
const discoveryPrefix = "CLIPBOARD_DISCOVERY "

// OnPeerFound is invoked with a peer's TCP address ("host:port")
// whenever a discovery broadcast from another device is seen. Matches
// network.Server.Connect, so it can be passed straight in.
type OnPeerFound func(address string)

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

		if !isDiscoveryMessage(message) {
			continue
		}

		if containsDeviceID(message, d.deviceID) {
			continue // don't connect to ourselves
		}

		peer := fmt.Sprintf("%s:%d", remote.IP.String(), d.tcpPort)

		d.onPeerFound(peer)
	}
}

func (d *Discovery) announce(conn *net.UDPConn) {
	for {
		time.Sleep(announceInterval)

		message := fmt.Sprintf("CLIPBOARD_DISCOVERY %s %d\n", d.deviceID, d.tcpPort)

		targets := append(subnetBroadcastAddrs(), net.IPv4bcast)

		for _, ip := range targets {
			broadcastAddr := &net.UDPAddr{IP: ip, Port: d.udpPort}

			if _, err := conn.WriteToUDP([]byte(message), broadcastAddr); err != nil {
				log.Printf("UDP discovery broadcast to %s failed: %v", ip, err)
			}
		}
	}
}

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

func isDiscoveryMessage(message string) bool {
	return len(message) >= len(discoveryPrefix) &&
		message[:len(discoveryPrefix)] == discoveryPrefix
}

func containsDeviceID(message string, id string) bool {
	return len(message) > len(discoveryPrefix)+len(id) &&
		message[len(discoveryPrefix):len(discoveryPrefix)+len(id)] == id
}