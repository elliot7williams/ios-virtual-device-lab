# Audio, networking, and performance

## Networking

The configuration model supports internet/NAT, bridged virtual Wi-Fi, isolated, and offline modes plus proxy, traffic-capture, and host-access policy. The vphone adapter maps NAT, bridged, and no-network modes to its CLI. Proxy injection and packet capture require an explicitly trusted `network-policy` plugin, which receives the requested JSON policy through `LAB_NETWORK_CONFIGURATION`.

## Audio research

Every VM has an audio-test policy covering output, input, route, 48 kHz sampling, interruption simulation, and background-audio validation. The companion vphone runtime reports that its Virtio device has real host-backed input/output streams; the lab uses that runtime evidence for the audio assertion. Acceptance must still separately test media playback, volume, routing, background audio, lock-screen/media controls, interruptions, and any feasible headphone/Bluetooth behavior.

## Performance

The dashboard reports real host CPU, resident memory, and read/write byte rates from `proc_pid_rusage` for processes holding the VM disk. The API also has fields for GPU, FPS, and audio sample rate. Unsupported counters are shown as unavailable, not fabricated. A future engine adapter may populate them from native instrumentation.
