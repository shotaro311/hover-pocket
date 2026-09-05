import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from verify_macos_app_configuration import validate


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.info = {
            "GIDClientID": "123-fixture.apps.googleusercontent.com",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["com.googleusercontent.apps.123-fixture"]}],
            "NSLocationUsageDescription": "Use weather location on request",
        }
        self.entitlements = {"com.apple.security.personal-information.location": True}

    def test_complete_configuration(self):
        validate(self.info, self.entitlements)

    def test_missing_or_invalid_client(self):
        for client in [None, "", "invalid"]:
            with self.subTest(client=client), self.assertRaises(ValueError):
                validate(dict(self.info, GIDClientID=client), self.entitlements)

    def test_wrong_callback(self):
        info = copy.deepcopy(self.info)
        info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] = ["other"]
        with self.assertRaises(ValueError):
            validate(info, self.entitlements)

    def test_missing_signed_location_entitlement(self):
        with self.assertRaises(ValueError):
            validate(self.info, {})

    def test_missing_location_purpose(self):
        with self.assertRaises(ValueError):
            validate(dict(self.info, NSLocationUsageDescription=""), self.entitlements)


if __name__ == "__main__":
    unittest.main()
