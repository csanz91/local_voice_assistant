import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("provision", ROOT / "tools/provision_device.py")
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


class ProvisioningTests(unittest.TestCase):
    def config(self, profiles):
        return {"schema": "sebastian.config.v1", "profiles": profiles}

    def profiles_sized(self, size):
        profiles = [{"name": "desk", "annotation": ""}]
        overhead = len(json.dumps(profiles, separators=(",", ":")).encode())
        profiles[0]["annotation"] = "x" * (size - overhead)
        return profiles

    def test_cli_and_loader_share_capacity(self):
        header = (ROOT / "firmware/main/profiles.h").read_text()
        capacity = int(re.search(r"#define SEBASTIAN_PROFILES_JSON_CAPACITY (\d+)", header)[1])
        self.assertEqual(provision.PROFILE_JSON_CAPACITY, capacity)

    def test_exact_utf8_storage_boundary(self):
        good = self.config(self.profiles_sized(1023))
        self.assertEqual(provision.prepare_config(good)["profiles"], good["profiles"])
        for size in (1024, 1025, 6000):
            with self.assertRaisesRegex(ValueError, "1023"):
                provision.prepare_config(self.config(self.profiles_sized(size)))
        with self.assertRaisesRegex(ValueError, "1023"):
            provision.prepare_config(self.config([{"name": "desk", "annotation": "é" * 510}]))

    def test_device_jwt_boundary(self):
        for count in (0, 129, 1024):
            cfg = {"schema": "sebastian.config.v1", "device": {"secret": "a" * count}}
            self.assertEqual(provision.prepare_config(cfg)["device"]["secret"], "a" * count)
        for secret in ("a" * 1025, "header\r\ninjection"):
            with self.assertRaises(ValueError):
                provision.prepare_config({"schema": "sebastian.config.v1", "device": {"secret": secret}})

    def test_omission_empty_and_non_array(self):
        base = {"schema": "sebastian.config.v1"}
        self.assertNotIn("profiles", provision.prepare_config(base))
        self.assertEqual(provision.prepare_config(self.config([]))["profiles"], [])
        for profiles in ({}, None, "[]"):
            with self.assertRaises(ValueError):
                provision.prepare_config(self.config(profiles))


if __name__ == "__main__":
    unittest.main()
