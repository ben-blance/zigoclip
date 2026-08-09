// Package sync tracks which clipboard sync events have already been
// processed, so a message doesn't bounce forever between two peers
// (A -> B -> A -> B -> ...).
package sync

import stdsync "sync"

type Tracker struct {
	mu   stdsync.Mutex
	seen map[string]bool
}

func NewTracker() *Tracker {
	return &Tracker{seen: make(map[string]bool)}
}

// MarkSeen records eventID as processed and reports whether it had
// already been seen before this call.
func (t *Tracker) MarkSeen(eventID string) (alreadySeen bool) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if t.seen[eventID] {
		return true
	}

	t.seen[eventID] = true

	return false
}