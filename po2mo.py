#!/usr/bin/env python3
"""
po2mo.py - Script to compile PO (.po) translation files into binary MO (.mo) format.

Usage:
  python3 po2mo.py [<file.po> | <directory>]

If a .po file path is given, it compiles that file to a .mo file (replacing extension).
If a directory or no argument is given, it recursively finds and compiles all .po files.
"""

import sys
import os
import glob
import struct
import re
import shutil
import subprocess

def compile_po_with_msgfmt(po_path, mo_path):
    """Attempt to compile using GNU msgfmt tool."""
    msgfmt = shutil.which("msgfmt")
    if msgfmt:
        res = subprocess.run([msgfmt, "--no-hash", "-o", mo_path, po_path], capture_output=True, text=True)
        if res.returncode == 0:
            return True
    return False

def parse_po_file(po_path):
    """Pure Python PO parser fallback."""
    translations = {}
    with open(po_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Match msgid and msgstr pairs
    pattern = re.compile(
        r'(?:msgctxt\s+(?P<ctxt>(?:".*?"\s*)+)\s*)?'
        r'msgid\s+(?P<id>(?:".*?"\s*)+)\s*'
        r'msgstr\s+(?P<str>(?:".*?"\s*)+)',
        re.DOTALL
    )

    def unescape(s):
        if not s:
            return ""
        lines = re.findall(r'"(.*)"', s)
        res = "".join(lines)
        res = res.replace('\\n', '\n') \
                 .replace('\\t', '\t') \
                 .replace('\\r', '\r') \
                 .replace('\\"', '"') \
                 .replace('\\\\', '\\')
        return res

    for match in pattern.finditer(content):
        ctxt = unescape(match.group('ctxt'))
        msgid = unescape(match.group('id'))
        msgstr = unescape(match.group('str'))

        if ctxt:
            key = f"{ctxt}\x04{msgid}"
        else:
            key = msgid

        if key or msgstr:
            translations[key] = msgstr

    return translations

def compile_po_python(po_path, mo_path):
    """Pure Python MO generator fallback."""
    translations = parse_po_file(po_path)
    keys = sorted(translations.keys())

    num_strings = len(keys)
    orig_table_offset = 28
    trans_table_offset = orig_table_offset + num_strings * 8

    orig_bytes = []
    trans_bytes = []

    orig_indices = []
    trans_indices = []

    current_orig_offset = trans_table_offset + num_strings * 8

    for k in keys:
        b_k = k.encode('utf-8')
        orig_indices.append((len(b_k), current_orig_offset))
        orig_bytes.append(b_k + b'\x00')
        current_orig_offset += len(b_k) + 1

    current_trans_offset = current_orig_offset
    for k in keys:
        v = translations[k]
        b_v = v.encode('utf-8')
        trans_indices.append((len(b_v), current_trans_offset))
        trans_bytes.append(b_v + b'\x00')
        current_trans_offset += len(b_v) + 1

    header = struct.pack(
        '<IiiiiII',
        0x950412de,  # Magic number
        0,           # Version
        num_strings,
        orig_table_offset,
        trans_table_offset,
        0,           # Hash table size
        0            # Hash table offset
    )

    orig_table = b''.join([struct.pack('<II', length, offset) for length, offset in orig_indices])
    trans_table = b''.join([struct.pack('<II', length, offset) for length, offset in trans_indices])

    body_orig = b''.join(orig_bytes)
    body_trans = b''.join(trans_bytes)

    mo_data = header + orig_table + trans_table + body_orig + body_trans

    with open(mo_path, 'wb') as f:
        f.write(mo_data)

    return True

def convert_file(po_path):
    if not os.path.exists(po_path):
        print(f"Error: File not found: {po_path}")
        return False

    mo_path = os.path.splitext(po_path)[0] + ".mo"
    print(f"Compiling '{po_path}' -> '{mo_path}'...")

    if compile_po_with_msgfmt(po_path, mo_path):
        print(f"  [OK] Compiled using msgfmt.")
        return True
    else:
        print(f"  [Info] msgfmt unavailable or failed, using Python fallback...")
        try:
            compile_po_python(po_path, mo_path)
            print(f"  [OK] Compiled using Python binary builder.")
            return True
        except Exception as e:
            print(f"  [ERROR] Failed to compile {po_path}: {e}")
            return False

def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "."

    if os.path.isfile(target):
        if target.endswith(".po"):
            success = convert_file(target)
            sys.exit(0 if success else 1)
        else:
            print("Error: Target file is not a .po file.")
            sys.exit(1)
    elif os.path.isdir(target):
        po_files = glob.glob(os.path.join(target, "**", "*.po"), recursive=True)
        if not po_files:
            print(f"No .po files found in directory '{target}'.")
            sys.exit(0)

        print(f"Found {len(po_files)} .po file(s) in '{target}'.")
        compiled_count = 0
        for po_file in po_files:
            if convert_file(po_file):
                compiled_count += 1
        print(f"Done. Successfully compiled {compiled_count}/{len(po_files)} file(s).")
    else:
        print(f"Error: Invalid target path: '{target}'")
        sys.exit(1)

if __name__ == "__main__":
    main()
