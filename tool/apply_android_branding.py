#!/usr/bin/env python3
"""Apply identical IQ Tunnel Android launcher branding to CI and release builds."""
from pathlib import Path
import re

root = Path("android/app/src/main")
manifest = root / "AndroidManifest.xml"
if not manifest.exists():
    raise SystemExit("Android scaffold is missing; generate it before applying branding.")

# Use a resource reference so the same product label is used by every build type.
values = root / "res/values"
values.mkdir(parents=True, exist_ok=True)
strings = values / "strings.xml"
if strings.exists():
    content = strings.read_text(encoding="utf-8")
    if re.search(r'<string\s+name="app_name">.*?</string>', content, re.S):
        content = re.sub(r'<string\s+name="app_name">.*?</string>',
                         '<string name="app_name">IQ Tunnel</string>', content, count=1, flags=re.S)
    else:
        content = content.replace("</resources>", '    <string name="app_name">IQ Tunnel</string>\n</resources>')
else:
    content = '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="app_name">IQ Tunnel</string>\n</resources>\n'
strings.write_text(content, encoding="utf-8")

xml = manifest.read_text(encoding="utf-8")
xml = re.sub(r'android:label="[^"]+"', 'android:label="@string/app_name"', xml, count=1)
# Profile encryption keys are protected by Android Keystore. Exclude app data from
# cloud/device auto-backup so restored ciphertext cannot be stranded without its key.
if re.search(r'<application\b[^>]*>', xml):
    xml = re.sub(
        r'<application\b([^>]*)>',
        lambda match: '<application' + re.sub(r'\s+android:allowBackup="[^"]+"', '', match.group(1)) + ' android:allowBackup="false">',
        xml,
        count=1,
    )
manifest.write_text(xml, encoding="utf-8")

drawable = root / "res/drawable"
drawable.mkdir(parents=True, exist_ok=True)
foreground = drawable / "ic_launcher_foreground.xml"
foreground.write_text('''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <group android:scaleX="0.68" android:scaleY="0.68" android:pivotX="54" android:pivotY="54">
    <path android:fillColor="#00000000" android:strokeColor="#FFFFC247" android:strokeWidth="3.4" android:strokeLineJoin="round"
        android:pathData="M54,8 C68,17 81,19 94,21 L91,62 C88,80 71,94 54,101 C37,94 20,80 17,62 L14,21 C27,19 40,17 54,8 Z"/>
    <path android:fillColor="#00000000" android:strokeColor="#FF00D9E8" android:strokeWidth="2.5" android:strokeLineCap="round"
        android:pathData="M34,39 C36,25 72,25 74,39 M43,39 C45,31 63,31 65,39"/>
    <path android:fillColor="#FFFFD778" android:pathData="M29,43 L36,43 L36,68 L29,68 Z"/>
    <path android:fillColor="#00000000" android:strokeColor="#FFFFD778" android:strokeWidth="6.5" android:strokeLineCap="round"
        android:pathData="M52,43 C44,43 41,48 41,55 C41,63 45,68 53,68 C61,68 65,63 65,55 C65,48 61,43 52,43 Z M58,62 L67,70"/>
    <path android:fillColor="#00000000" android:strokeColor="#FFFFD778" android:strokeWidth="6.5" android:strokeLineCap="square"
        android:pathData="M72,45 L88,45 M80,45 L80,68"/>
    <path android:fillColor="#00000000" android:strokeColor="#FF00D9E8" android:strokeWidth="2.4" android:strokeLineCap="round"
        android:pathData="M43,79 C48,82 60,82 65,79"/>
    </group>
</vector>
''', encoding="utf-8")

colors = values / "colors.xml"
color_content = colors.read_text(encoding="utf-8") if colors.exists() else '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n</resources>\n'
if re.search(r'<color\s+name="ic_launcher_background">.*?</color>', color_content, re.S):
    color_content = re.sub(r'<color\s+name="ic_launcher_background">.*?</color>',
                           '<color name="ic_launcher_background">#090B10</color>', color_content, count=1, flags=re.S)
else:
    color_content = color_content.replace("</resources>", '    <color name="ic_launcher_background">#090B10</color>\n</resources>')
colors.write_text(color_content, encoding="utf-8")

# Pre-Android 8 launcher icon: the same shield and IQT mark on a solid dark square.
legacy = root / "res/mipmap-anydpi"
legacy.mkdir(parents=True, exist_ok=True)
legacy_icon = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#FF090B10" android:pathData="M0,0h108v108h-108z"/>
    <path android:fillColor="#00000000" android:strokeColor="#FFFFC247" android:strokeWidth="3.4"
        android:pathData="M54,8 C68,17 81,19 94,21 L91,62 C88,80 71,94 54,101 C37,94 20,80 17,62 L14,21 C27,19 40,17 54,8 Z"/>
    <path android:fillColor="#00000000" android:strokeColor="#FF00D9E8" android:strokeWidth="2.5"
        android:pathData="M34,39 C36,25 72,25 74,39 M43,39 C45,31 63,31 65,39"/>
    <path android:fillColor="#FFFFD778" android:pathData="M29,43 L36,43 L36,68 L29,68 Z"/>
    <path android:fillColor="#00000000" android:strokeColor="#FFFFD778" android:strokeWidth="6.5"
        android:pathData="M52,43 C44,43 41,48 41,55 C41,63 45,68 53,68 C61,68 65,63 65,55 C65,48 61,43 52,43 Z M58,62 L67,70"/>
    <path android:fillColor="#00000000" android:strokeColor="#FFFFD778" android:strokeWidth="6.5"
        android:pathData="M72,45 L88,45 M80,45 L80,68"/>
    <path android:fillColor="#00000000" android:strokeColor="#FF00D9E8" android:strokeWidth="2.4"
        android:pathData="M43,79 C48,82 60,82 65,79"/>
</vector>
'''
(legacy / "ic_launcher.xml").write_text(legacy_icon, encoding="utf-8")
(legacy / "ic_launcher_round.xml").write_text(legacy_icon, encoding="utf-8")

adaptive = root / "res/mipmap-anydpi-v26"
adaptive.mkdir(parents=True, exist_ok=True)
icon = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
'''
(adaptive / "ic_launcher.xml").write_text(icon, encoding="utf-8")
(adaptive / "ic_launcher_round.xml").write_text(icon, encoding="utf-8")

print("Applied IQ Tunnel app label, clean shield launcher icon and adaptive icon.")
