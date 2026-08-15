
<div align="center">
  <img width="500" height="500" alt="1shot__5_-removebg-preview" src="https://github.com/user-attachments/assets/b6ce73a1-3e66-4e63-bcae-218d52c44c78" />
</div>

**A lightweight peer-to-peer clipboard synchronization tool for Windows, built with Go and Zig.**

Zigoclip allows two Windows devices connected to the same local network to automatically synchronize their clipboard.

Copy something on one device, and it becomes available on the other device automatically.

```text
┌──────────────────┐                    ┌──────────────────┐
│    Windows A     │                    │    Windows B     │
│                  │                    │                  │
│   Clipboard      │                    │   Clipboard      │
│       ▲          │                    │       ▲          │
│       │          │                    │       │          │
│      Zig         │                    │      Zig         │
│       ▲          │                    │       ▲          │
│       │ IPC      │                    │       │ IPC      │
│       ▼          │                    │       ▼          │
│      Go          │◄────── TCP ───────►│      Go          │
│                  │                    │                  │
└──────────────────┘                    └──────────────────┘
              ▲
              │
        UDP Discovery
```

> **Status:** 🚧 Active development
> **Current platform:** Windows

---

## ✨ Features

### Currently implemented

* 🖥️ Windows-only clipboard synchronization
* 📡 Automatic device discovery over UDP
* 🔗 Peer-to-peer TCP communication
* 📋 Automatic text clipboard synchronization
* ⚡ Event-driven Windows clipboard monitoring
* 🔄 Bidirectional synchronization
* 🔁 Duplicate connection prevention
* 🛑 Clipboard synchronization loop prevention
* 🧩 Go + Zig architecture
* 🏗️ Production-oriented project structure
* 🖼️ Image clipboard synchronization
* 📦 Efficient binary clipboard transfers

### Planned


* 🔌 Connection recovery and reconnection
* 🔐 Device pairing and authentication
* 🔒 Encryption
* 💻 Support for multiple devices (UNIX)
* 🪟 Windows background/tray application

---

# 🧠 How It Works

Zigoclip is split into two major parts:

### Zig

Zig is responsible for interacting directly with the Windows clipboard.

```text
Windows Clipboard
        │
        ▼
      Zig
        │
        │ IPC
        ▼
       Go
```

Zig handles:

* Reading clipboard data
* Writing clipboard data
* Detecting clipboard changes
* Windows-specific clipboard APIs

The clipboard watcher uses the Windows clipboard format listener mechanism rather than continuously polling the clipboard.

When a clipboard change occurs, Zig receives a Windows clipboard update event and processes it immediately.

### Go

Go handles everything related to the network and synchronization layer.

```text
              Go Agent
                 │
      ┌──────────┼──────────┐
      │          │          │
      ▼          ▼          ▼
 Discovery    Network     Sync
    UDP         TCP       Events
      │          │          │
      └──────────┼──────────┘
                 │
                IPC
                 │
                 ▼
                Zig
```

Go is responsible for:

* UDP device discovery
* TCP connections
* Clipboard event messages
* Event IDs
* Synchronization
* Loop prevention
* Communication with the Zig clipboard process

---

# 🌐 Network Architecture

Zigoclip does not require a central server.

Each device runs the same application and communicates directly with its peers.

```text
             Local Network

        UDP Discovery
       ┌───────────────┐
       │               │
       ▼               ▼

┌─────────────┐   TCP   ┌─────────────┐
│   Client A  │◄───────►│   Client B  │
│             │         │             │
│     Go      │         │     Go      │
│      │      │         │      │      │
│     Zig     │         │     Zig     │
│      │      │         │      │      │
│ Clipboard   │         │ Clipboard   │
└─────────────┘         └─────────────┘
```

### UDP

UDP is used only for **device discovery**.

When a Zigoclip instance starts, it broadcasts its presence on the local network.

The discovery message contains information such as:

```text
device_id
tcp_port
```

### TCP

TCP is used for actual clipboard synchronization.

Once two devices discover each other, they establish a persistent TCP connection.

---

# 🔗 Preventing Duplicate Connections

Both devices will discover each other.

Without any coordination, this could result in:

```text
A ─────────► B
A ◄───────── B
```

creating two TCP connections.

Zigoclip uses the device ID as a deterministic tie-breaker.

The device with the **lexicographically smaller device ID** initiates the connection.

For example:

```text
client-a < client-b
```

Therefore:

```text
client-a ─────────────► client-b
             TCP
```

The other device simply waits for the incoming connection.

This gives each peer pair a single TCP connection.

---

# 📋 Clipboard Synchronization

A local clipboard update follows this path:

```text
User presses Ctrl+C
        │
        ▼
Windows Clipboard
        │
        ▼
       Zig
        │
        │ IPC
        ▼
       Go
        │
        │ TCP
        ▼
    Remote Go
        │
        │ IPC
        ▼
    Remote Zig
        │
        ▼
Remote Clipboard
```

The reverse direction works identically.

---

# 🔁 Loop Prevention

Clipboard synchronization can easily create an infinite loop.

Without protection:

```text
A copies "Hello"
       │
       ▼
      B
       │
       ▼
B clipboard changes
       │
       ▼
      A
       │
       ▼
A clipboard changes
       │
       ▼
      B
       │
      ...
```

Zigoclip assigns every clipboard synchronization event a unique `event_id`.

When a device receives an event, it checks whether that event has already been processed.

```text
             Event
               │
               ▼
        Already processed?
          /           \
        YES            NO
         │              │
         ▼              ▼
       Ignore       Process event
                       │
                       ▼
                Update clipboard
```

Remote clipboard updates are therefore not retransmitted as new synchronization events.

---

# 📦 Message Protocol

Clipboard events are represented by a versioned message:

```text
Message
├── version
├── type
├── device_id
├── event_id
├── clipboard_format
└── payload
```

The current protocol is designed around clipboard formats rather than assuming that all clipboard data is text.

Currently:

```text
clipboard_format = text
```

The protocol will eventually support:

```text
clipboard_format = text
clipboard_format = image
```

This allows image synchronization to be added without redesigning the entire networking layer.

---

# 🛠️ Tech Stack

| Technology    | Purpose                                |
| ------------- | -------------------------------------- |
| **Go**        | Networking, discovery, synchronization |
| **Zig**       | Windows clipboard interaction          |
| **UDP**       | Local device discovery                 |
| **TCP**       | Clipboard data transfer                |
| **Win32 API** | Windows clipboard and event handling   |

---

## Requirements

Currently Zigoclip targets Windows.

You will need:

* Windows
* Go
* Zig
* MinGW Make

Check your installations:

```powershell
go version
zig version
mingw32-make --version
```

---

## Build

Clone the repository:

```powershell
git clone https://github.com/ben-blance/zigoclip.git
cd zigoclip
```

Build the project:

```powershell
mingw32-make
```

---

## Run

Start Zigoclip on the first device:

```powershell
mingw32-make run-a
```

Start it on the second device:

```powershell
mingw32-make run-b
```

Both devices should be connected to the same local network.

Once the devices discover each other, clipboard synchronization happens automatically.

---

# 🎯 Project Goal

Zigoclip is intended to be a small, fast, local-first clipboard synchronization system.

The long-term goal is simple:

```text
Copy on one device
        ↓
Automatically available
        ↓
on another device
```

No cloud service.

No central server.

No manual transfer.

Just devices on the same network communicating directly with each other.

---

## License

License information will be added as the project develops.
