# Audio, networking, and performance

## Networking

The configuration model supports internet/NAT, bridged virtual Wi-Fi, isolated, and offline modes plus proxy, traffic-capture, and host-access policy. The vphone adapter currently maps NAT, bridged, and no-network modes to its CLI. Proxy injection and packet capture remain capability-dependent and are stored explicitly rather than silently simulated.

## Audio research

Every VM has an audio-test policy covering output, input, route, 48 kHz sampling, interruption simulation, and background-audio validation. The current vphone engine does not yet claim full audio simulation. Acceptance must separately test media playback, volume, routing, background audio, lock-screen/media controls, interruptions, and any feasible headphone/Bluetooth behavior.

## Performance

The dashboard reports real host CPU and resident-memory counters for processes holding the VM disk. The API also has fields for disk throughput, GPU, FPS, and audio sample rate. Unsupported counters are shown as unavailable, not fabricated. A future engine adapter may populate them from native instrumentation.
