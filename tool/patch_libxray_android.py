#!/usr/bin/env python3
"""Apply the pinned IQ Tunnel Android TUN-FD and stats APIs to libXray."""

from __future__ import annotations

import sys
from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    if new in source:
        return source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Unexpected upstream {label}; found {count} anchors.")
    return source.replace(old, new, 1)


def patch_android_wrapper(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"libXray Android wrapper not found: {path}")
    source = path.read_text(encoding="utf-8")

    source = replace_once(
        source,
        '\t"errors"\n',
        '\t"errors"\n\t"os"\n\t"strconv"\n',
        "android wrapper imports",
    )
    source = replace_once(
        source,
        '\t"github.com/xtls/libxray/dns"\n',
        '\t"github.com/xtls/libxray/dns"\n\t"github.com/xtls/libxray/xray"\n',
        "android wrapper package imports",
    )

    tun_bridge = """// SetTunFd configures the Android TUN descriptor consumed by Xray's Android
// TUN implementation. The environment value is read in this Go process.
func SetTunFd(fd int64) error {
\tif fd < 0 {
\t\treturn errors.New("invalid Android TUN file descriptor")
\t}
\treturn os.Setenv("xray.tun.fd", strconv.FormatInt(fd, 10))
}

// ResetTunFd removes the Android TUN descriptor after the managed instance
// has stopped and the VPN file descriptor has been closed.
func ResetTunFd() error {
\treturn os.Unsetenv("xray.tun.fd")
}

"""
    stats_bridge = """// GetTrafficStats returns the current managed Xray TUN byte counters as JSON.
func GetTrafficStats() string {
\treturn xray.GetTrafficStats()
}

"""
    source = replace_once(
        source,
        "// SetDNS installs an Android VPN-aware process resolver.",
        tun_bridge + "// SetDNS installs an Android VPN-aware process resolver.",
        "Android TUN-FD API",
    )
    source = replace_once(
        source,
        "// ProcessFinder -> implemented by apps to resolve UID from connection details.",
        stats_bridge + "// ProcessFinder -> implemented by apps to resolve UID from connection details.",
        "Android traffic-stats API",
    )

    required = (
        "func SetTunFd(fd int64) error {",
        "func ResetTunFd() error {",
        "func GetTrafficStats() string {",
        'os.Setenv("xray.tun.fd", strconv.FormatInt(fd, 10))',
        'os.Unsetenv("xray.tun.fd")',
        "return xray.GetTrafficStats()",
    )
    missing = [item for item in required if item not in source]
    if missing:
        raise SystemExit("Android wrapper patch verification failed.")
    path.write_text(source, encoding="utf-8")
    print("Patched libXray Android wrapper: TUN FD and traffic stats.")


def patch_xray_runtime(path: Path) -> None:
    if not path.is_file():
        raise SystemExit(f"libXray managed Xray runtime not found: {path}")
    source = path.read_text(encoding="utf-8")

    source = replace_once(
        source,
        'import (\n\t"errors"\n',
        'import (\n\t"encoding/json"\n\t"errors"\n',
        "managed Xray standard imports",
    )
    source = replace_once(
        source,
        '\t"github.com/xtls/xray-core/core"\n',
        '\t"github.com/xtls/xray-core/core"\n\tfeature_stats "github.com/xtls/xray-core/features/stats"\n',
        "managed Xray feature imports",
    )

    getter = """type trafficStatsSnapshot struct {
\tAvailable     bool  `json:"available"`
\tUploadTotal   int64 `json:"uploadTotal"`
\tDownloadTotal int64 `json:"downloadTotal"`
}

// GetTrafficStats reads only Xray's in-process counters. It does not open an
// HTTP metrics or pprof listener and never returns profile or server details.
func GetTrafficStats() string {
\tresult := trafficStatsSnapshot{}
\tcoreServerMu.Lock()
\tdefer coreServerMu.Unlock()

\tif coreServer != nil && coreServer.IsRunning() {
\t\tif manager, ok := coreServer.GetFeature(feature_stats.ManagerType()).(feature_stats.Manager); ok && manager != nil {
\t\t\tuplink := manager.GetCounter("inbound>>>iqt-tun>>>traffic>>>uplink")
\t\t\tdownlink := manager.GetCounter("inbound>>>iqt-tun>>>traffic>>>downlink")
\t\t\tif uplink != nil && downlink != nil {
\t\t\t\tresult.Available = true
\t\t\t\tresult.UploadTotal = uplink.Value()
\t\t\t\tresult.DownloadTotal = downlink.Value()
\t\t\t}
\t\t}
\t}

\tdata, err := json.Marshal(result)
\tif err != nil {
\t\treturn `{"available":false,"uploadTotal":0,"downloadTotal":0}`
\t}
\treturn string(data)
}

"""
    source = replace_once(
        source,
        "// Xray's version",
        getter + "// Xray's version",
        "managed Xray traffic-stats getter",
    )

    required = (
        "type trafficStatsSnapshot struct {",
        "func GetTrafficStats() string {",
        "feature_stats.ManagerType()",
        'inbound>>>iqt-tun>>>traffic>>>uplink',
        'inbound>>>iqt-tun>>>traffic>>>downlink',
    )
    missing = [item for item in required if item not in source]
    if missing:
        raise SystemExit("Managed Xray stats patch verification failed.")
    path.write_text(source, encoding="utf-8")
    print("Patched managed Xray runtime with in-process traffic counters.")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_libxray_android.py PATH_TO_LIBXRAY_SOURCE_ROOT")
    root = Path(sys.argv[1])
    patch_android_wrapper(root / "android_wrapper.go")
    patch_xray_runtime(root / "xray" / "xray.go")


if __name__ == "__main__":
    main()

