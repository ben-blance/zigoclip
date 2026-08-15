package protocol

// Message is the wire format for every clipboard synchronization event.
type Message struct {
	Version         int    `json:"version"`
	Type            string `json:"type"`
	DeviceID        string `json:"device_id"`
	EventID         string `json:"event_id"`
	ClipboardFormat string `json:"clipboard_format"`
	PayloadSize     int    `json:"payload_size"`
	Payload         []byte `json:"-"`
}

const (
	CurrentVersion      = 1
	TypeClipboardUpdate = "clipboard_update"
	FormatText          = "text"
	FormatImage         = "image"
	MaxPayloadSize = 64 * 1024 * 1024 // 64MB
)

// New builds a V1 clipboard_update message. PayloadSize is derived
// from len(payload) so the two can never drift apart.
func New(deviceID, eventID, format string, payload []byte) Message {
	return Message{
		Version:         CurrentVersion,
		Type:            TypeClipboardUpdate,
		DeviceID:        deviceID,
		EventID:         eventID,
		ClipboardFormat: format,
		PayloadSize:     len(payload),
		Payload:         payload,
	}
}