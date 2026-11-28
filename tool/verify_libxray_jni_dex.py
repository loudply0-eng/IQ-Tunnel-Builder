#!/usr/bin/env python3
"""Fail a release build if R8 removes the gomobile Seq.getRef JNI helper."""

from __future__ import annotations

import argparse
import re
import struct
import sys
import zipfile
from pathlib import Path


def read_u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise ValueError(f"Dex uint32 offset is out of bounds: {offset}")
    return struct.unpack_from("<I", data, offset)[0]


def read_uleb128(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(5):
        if offset >= len(data):
            raise ValueError("Unexpected end of DEX while reading ULEB128")
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise ValueError("Invalid ULEB128 value in DEX")


def dex_go_seq_methods(data: bytes) -> set[str] | None:
    if len(data) < 112 or not data.startswith(b"dex\\n"):
        raise ValueError("APK contains an invalid or unsupported DEX file")

    string_count, string_offset = read_u32(data, 56), read_u32(data, 60)
    type_count, type_offset = read_u32(data, 64), read_u32(data, 68)
    method_count, method_offset = read_u32(data, 88), read_u32(data, 92)
    class_count, class_offset = read_u32(data, 96), read_u32(data, 100)

    for count, offset, width, label in (
        (string_count, string_offset, 4, "string_ids"),
        (type_count, type_offset, 4, "type_ids"),
        (method_count, method_offset, 8, "method_ids"),
        (class_count, class_offset, 32, "class_defs"),
    ):
        if offset + count * width > len(data):
            raise ValueError(f"DEX {label} table extends beyond the file")

    strings: list[str] = []
    for index in range(string_count):
        string_data_offset = read_u32(data, string_offset + index * 4)
        _, cursor = read_uleb128(data, string_data_offset)
        terminator = data.find(b"\\x00", cursor)
        if terminator < 0:
            raise ValueError("Unterminated string_data_item in DEX")
        # DEX uses Modified UTF-8. All identifiers and descriptors we compare
        # here are ASCII; replacement keeps unrelated strings harmless.
        strings.append(data[cursor:terminator].decode("utf-8", errors="replace"))

    type_descriptors: list[str] = []
    for index in range(type_count):
        descriptor_index = read_u32(data, type_offset + index * 4)
        if descriptor_index >= len(strings):
            raise ValueError("DEX type descriptor references an invalid string")
        type_descriptors.append(strings[descriptor_index])

    method_names: list[str] = []
    for index in range(method_count):
        _, _, name_index = struct.unpack_from("<HHI", data, method_offset + index * 8)
        if name_index >= len(strings):
            raise ValueError("DEX method references an invalid name string")
        method_names.append(strings[name_index])

    for index in range(class_count):
        class_def_offset = class_offset + index * 32
        class_index = read_u32(data, class_def_offset)
        if class_index >= len(type_descriptors):
            raise ValueError("DEX class definition references an invalid type")
        if type_descriptors[class_index] != "Lgo/Seq;":
            continue

        class_data_offset = read_u32(data, class_def_offset + 24)
        if class_data_offset == 0:
            return set()

        cursor = class_data_offset
        static_fields, cursor = read_uleb128(data, cursor)
        instance_fields, cursor = read_uleb128(data, cursor)
        direct_methods, cursor = read_uleb128(data, cursor)
        virtual_methods, cursor = read_uleb128(data, cursor)

        # Skip encoded fields (field_idx_diff, access_flags).
        for field_count in (static_fields, instance_fields):
            field_index = 0
            for _ in range(field_count):
                delta, cursor = read_uleb128(data, cursor)
                _, cursor = read_uleb128(data, cursor)
                field_index += delta

        found: set[str] = set()
        for method_group_count in (direct_methods, virtual_methods):
            method_index = 0
            for _ in range(method_group_count):
                delta, cursor = read_uleb128(data, cursor)
                _, cursor = read_uleb128(data, cursor)  # access_flags
                _, cursor = read_uleb128(data, cursor)  # code_off
                method_index += delta
                if method_index >= len(method_names):
                    raise ValueError("DEX encoded method index is out of bounds")
                found.add(method_names[method_index])
        return found

    return None


def verify_apk(apk_path: Path) -> None:
    if not apk_path.is_file() or not zipfile.is_zipfile(apk_path):
        raise SystemExit(f"Release APK is missing or invalid: {apk_path}")

    dex_entries: list[str]
    try:
        with zipfile.ZipFile(apk_path) as apk:
            dex_entries = sorted(
                name for name in apk.namelist()
                if re.fullmatch(r"classes(?:[2-9][0-9]*)?\\.dex", name)
                or name == "classes.dex"
            )
            if not dex_entries:
                raise SystemExit("Release APK contains no DEX bytecode")

            for entry in dex_entries:
                methods = dex_go_seq_methods(apk.read(entry))
                if methods is None:
                    continue
                if "getRef" not in methods:
                    raise SystemExit(
                        "R8 JNI verification failed: go.Seq.getRef is absent from "
                        f"{entry}. The gomobile native runtime will abort during "
                        "Java_go_Seq_init."
                    )
                print(f"Verified go.Seq.getRef survives R8 in {entry}")
                return
    except (OSError, zipfile.BadZipFile, ValueError, struct.error) as error:
        raise SystemExit(f"Could not verify gomobile JNI methods: {error}") from error

    raise SystemExit("R8 JNI verification failed: class go.Seq is absent from the APK")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path, help="Release APK to inspect")
    args = parser.parse_args()
    verify_apk(args.apk)


if __name__ == "__main__":
    main()
