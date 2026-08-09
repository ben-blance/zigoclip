package protocol

// Message is the wire format for every clipboard synchronization event.
type Message struct {
	Version         int    `json:"version"`
	Type            string `json:"type"`
	DeviceID        string `json:"device_id"`
	EventID         string `json:"event_id"`
	ClipboardFormat string `json:"clipboard_format"`
	Payload         string `json:"payload"`
}

const (
	CurrentVersion      = 1
	TypeClipboardUpdate = "clipboard_update"
	FormatText          = "text"
)

// New builds a V1 clipboard_update message.
func New(deviceID, eventID, payload string) Message {
	return Message{
		Version:         CurrentVersion,
		Type:            TypeClipboardUpdate,
		DeviceID:        deviceID,
		EventID:         eventID,
		ClipboardFormat: FormatText,
		Payload:         payload,
	}
}