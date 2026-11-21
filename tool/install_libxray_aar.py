#!/usr/bin/env python3
"""Install a generated libXray AAR into a Flutter Android library module."""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path, PurePosixPath


def safe_relative_path(name: str) -> Path:
    candidate = PurePosixPath(name)
    if candidate.is_absolute() or any(part in ("", ".", "..") for part in candidate.parts):
        raise SystemExit(f"Unsafe path in libXray AAR: {name}")
    return Path(*candidate.parts)


def install(aar_path: Path, android_module: Path) -> None:
    if not aar_path.is_file():
        raise SystemExit(f"libXray AAR not found: {aar_path}")
    if not zipfile.is_zipfile(aar_path):
        raise SystemExit("The generated libXray artifact is not a valid AAR ZIP.")

    libraries_dir = android_module / "libs"
    jni_root = android_module / "src" / "main" / "jniLibs"
    assets_root = android_module / "src" / "main" / "assets"
    res_root = android_module / "src" / "main" / "res"
    for directory in (libraries_dir, jni_root):
        directory.mkdir(parents=True, exist_ok=True)

    native_libraries: list[str] = []
    with zipfile.ZipFile(aar_path) as archive:
        names = archive.namelist()
        if "classes.jar" not in names:
            raise SystemExit("libXray AAR does not contain classes.jar.")

        # A Flutter plugin is itself built as an Android library AAR. Android
        # Gradle does not support embedding another local AAR as a transitive
        # local file dependency. Keep Java bindings as a JAR and native .so
        # libraries in the plugin's standard jniLibs source set instead.
        (libraries_dir / "libXray.jar").write_bytes(archive.read("classes.jar"))

        for name in names:
            if name.endswith("/"):
                continue
            if name.startswith("jni/") and name.endswith(".so"):
                relative = safe_relative_path(name.removeprefix("jni/"))
                target = jni_root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
                native_libraries.append(name)
            elif name.startswith("assets/"):
                relative = safe_relative_path(name.removeprefix("assets/"))
                target = assets_root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
            elif name.startswith("res/"):
                relative = safe_relative_path(name.removeprefix("res/"))
                target = res_root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))

    if not native_libraries:
        raise SystemExit("libXray AAR contains no Android native libraries.")
    if not any(name.startswith("jni/arm64-v8a/") for name in native_libraries):
        raise SystemExit("libXray AAR is missing the required arm64-v8a native library.")

    print("Installed libXray Java bindings and native libraries.")
    for item in sorted(native_libraries):
        print(f"  {item}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: install_libxray_aar.py PATH_TO_LIBXRAY_AAR ANDROID_PLUGIN_MODULE"
        )
    install(Path(sys.argv[1]), Path(sys.argv[2]))

