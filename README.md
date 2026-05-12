# IoT-Mesh

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

`IoT-Mesh` is a deployment scaffold for building an IoT wireless mesh testbed. It prepares Linux nodes to join the same Wi-Fi ad-hoc network, attaches that radio interface to a BATMAN-adv mesh, assigns each node a deterministic mesh IP address, and continuously selects the best available mesh gateway based on BATMAN transmission quality metrics.

The project is intended as a foundation for experiments with mesh networking, IoT coordination, intent-based networking (IBN), and higher-level control loops such as LLM-assisted network management.

This is a test-oriented project. Some choices, such as deterministic IP assignment from hostnames, assume a small controlled network where node names are planned and IP collisions are not expected.

## What It Provides

- Automated host setup through `deploy.sh`.
- A `bat0` mesh interface used for node-to-node communication.
- Deterministic IPv4 address based on the node hostname.
- Dynamic gateway selection using BATMAN gateway quality data.
- Docker to deploy applications.


## Project Layout

```text
.
+-- deploy.sh
`-- app
    +-- startup.sh
    +-- set_ip.sh
    +-- set_gw.sh
    `-- services
        +-- iot-mesh.service
        +-- iot-mesh-set-ip.service
        `-- iot-mesh-set-gw.service
```

## How It Works

### 1. Deployment

`deploy.sh` installs the required packages, enables the `batman-adv` kernel module, disables services that can interfere with direct wireless control, and clones this repository into `/opt/iot-mesh`.


```bash
sudo ./deploy.sh client
```

### 2. Mesh Startup

The `iot-mesh.service` unit runs `app/startup.sh start`.

During startup, the script:

1. Brings `wlan0` down.
2. Changes `wlan0` to IBSS/ad-hoc mode.
3. Adds `wlan0` to BATMAN-adv.
4. Brings `bat0` up.
5. Joins the shared IBSS network.
6. Adds NAT and forwarding rules between `bat0` and `eth0`.
7. Enables BATMAN gateway client mode.

The current IBSS parameters are defined directly in `startup.sh`:

```bash
iw wlan0 ibss join gYCLHxHlFVyj 5180
```

All nodes must use compatible wireless hardware, the same mesh parameters, and a network environment where this channel/frequency is valid. This project is tested and compatible with the following hardwares:


- Raspberry Pi 3 
- Raspberry Pi 5

### 3. Mesh IP Assignment

The `iot-mesh-set-ip.service` unit runs `app/set_ip.sh`.

This script reads the numeric suffix from the system hostname and uses it as the last octet of the mesh IP address. The assigned address allows nodes to communicate with each other at Layer 3 over the `bat0` mesh interface:

```text
hostname: node07
mesh IP: 10.99.100.7/24
```

**Note**: Hostnames must end with a number between the intended node range. If the hostname does not end with a number, IP assignment fails. This simple addressing model is intended for small testbeds where node identifiers are coordinated manually and duplicate IP addresses are avoided by design.

### 4. Gateway Selection

The `iot-mesh-set-gw.service` unit runs `app/set_gw.sh`.

This script continuously monitors BATMAN gateway data and updates the default route through `bat0`. It reads gateway quality from `batctl gwl`, maps gateway MAC addresses to reachable IP addresses using BATMAN and neighbor data, then selects the best candidate.

Gateway switching is controlled by a few safeguards:

- Gateways must meet a minimum transmission quality threshold.
- A new gateway must provide a meaningful quality improvement.
- A cooldown period prevents excessive route changes.

The default route is applied with:

```bash
ip route replace default via <gateway-ip> dev bat0
```

For a node to be advertised as a gateway in the BATMAN-adv mesh, it must explicitly enable gateway server mode:

```bash
batctl gw_mode server
```

## Service Order

The systemd units are designed to run in sequence:

1. `iot-mesh.service` creates the wireless mesh and `bat0`.
2. `iot-mesh-set-ip.service` assigns the node IP on `bat0`.
3. `iot-mesh-set-gw.service` selects and maintains the best default gateway.

## Operational Assumptions

This project assumes:

- A Linux system
- Root access for deployment and runtime networking changes.
- A wireless interface named `wlan0`.
- An upstream interface named `eth0` when internet forwarding is needed.
- BATMAN-adv support in the running kernel.
- Node hostnames ending in numeric identifiers.
- All mesh nodes using the same IBSS name and frequency.

## Notes

The repository currently focuses on the network bootstrap layer. It does not yet include the higher-level LLM or IBN control components mentioned in the project idea, but it provides the mesh substrate those experiments can run on.
