/*
 * ACAB Mesh-Detect - Meshtastic uplink.
 *
 * The XIAO ESP32-S3 detects; a wired Heltec V3 running Meshtastic transmits.
 * Two transports:
 *
 *   MESH_TEXT  - plaintext line over UART. Works with the Heltec Serial Module in
 *                TEXTMSG mode, but Meshtastic then only broadcasts on the PRIMARY
 *                channel (the "public channel" limitation).
 *
 *   MESH_PROTO - a ToRadio protobuf frame with MeshPacket.channel set, so
 *                detections go out on a channel index you pick. Needs the Heltec
 *                Serial Module in PROTO mode with that channel set up. Use this to
 *                transmit on a specific channel.
 *
 * Every message names the unit: "ALPR camera detected", "Flock Raven detected",
 * "Body camera detected", "Drone detected" (labels come from acabTypeLabel in
 * lib/acab_core/detection.h).
 */
#ifndef ACAB_MESH_LINK_H
#define ACAB_MESH_LINK_H

#include "detection.h"

enum MeshTransport { MESH_TEXT = 0, MESH_PROTO = 1 };

struct MeshLinkConfig {
    MeshTransport transport;
    uint8_t       channelIndex;    // Meshtastic channel index (0 = primary)
    uint32_t      uartBaud;        // match the Heltec Serial Module baud
    int           uartRxPin;       // XIAO RX  <- Heltec TX
    int           uartTxPin;       // XIAO TX  -> Heltec RX
    bool          includeGPS;      // append lat,lon when we have it
    uint32_t      minIntervalMs;   // min gap between mesh sends (LoRa duty cycle)
};

MeshLinkConfig meshLinkDefaults();
void meshLinkBegin(const MeshLinkConfig& cfg);

// Choose the channel at runtime (PROTO transport only).
void meshLinkSetChannel(uint8_t channelIndex);
uint8_t meshLinkChannel();

// Scanner sink helper: format + send a labelled detection.
void meshLinkSend(const AcabDetection& d, bool isNew);

// Send a raw text line over the mesh (configured transport + channel). Used by
// detections and by the boot self-test ping.
void meshLinkSendText(const char* text);

#endif // ACAB_MESH_LINK_H
