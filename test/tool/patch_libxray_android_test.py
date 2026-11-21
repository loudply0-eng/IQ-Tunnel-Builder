import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "tool" / "patch_libxray_android.py"
SPEC = importlib.util.spec_from_file_location("patch_libxray_android", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class PatchLibXrayAndroidTests(unittest.TestCase):
    def test_patches_android_wrapper_and_runtime_idempotently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "xray").mkdir()
            wrapper = root / "android_wrapper.go"
            wrapper.write_text(
                'package libXray\nimport (\n\t"errors"\n'
                '\tc "github.com/xtls/libxray/controller"\n'
                '\t"github.com/xtls/libxray/dns"\n)\n'
                'type DialerController interface { ProtectFd(int) bool }\n'
                '// SetDNS installs an Android VPN-aware process resolver.\n'
                '// ProcessFinder -> implemented by apps to resolve UID from connection details.\n',
                encoding="utf-8",
            )
            runtime = root / "xray" / "xray.go"
            runtime.write_text(
                'package xray\nimport (\n\t"errors"\n'
                '\t"runtime/debug"\n\t"strings"\n\t"sync"\n'
                '\t"github.com/xtls/libxray/memory"\n'
                '\t"github.com/xtls/xray-core/core"\n'
                '\t_ "github.com/xtls/xray-core/main/distro/all"\n)\n'
                'var (\n coreServerMu sync.Mutex\n coreServer *core.Instance\n)\n'
                '// Xray\'s version\n',
                encoding="utf-8",
            )

            MODULE.patch_android_wrapper(wrapper)
            MODULE.patch_xray_runtime(runtime)
            wrapper_first = wrapper.read_text(encoding="utf-8")
            runtime_first = runtime.read_text(encoding="utf-8")

            MODULE.patch_android_wrapper(wrapper)
            MODULE.patch_xray_runtime(runtime)

            self.assertEqual(wrapper_first, wrapper.read_text(encoding="utf-8"))
            self.assertEqual(runtime_first, runtime.read_text(encoding="utf-8"))
            self.assertIn("func GetTrafficStats() string", wrapper_first)
            self.assertIn("func GetTrafficStats() string", runtime_first)
            self.assertIn("feature_stats.ManagerType()", runtime_first)


if __name__ == "__main__":
    unittest.main()
