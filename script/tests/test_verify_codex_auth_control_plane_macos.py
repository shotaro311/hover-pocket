import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import verify_codex_auth_control_plane_macos as verifier


class GenerationContractTests(unittest.TestCase):
    def test_checked_in_contract_is_accepted(self):
        _, schema, output = verifier.load_generation_contract()
        self.assertEqual(schema["$id"], json.loads(output)["$schema"])

    def test_modified_contract_is_rejected(self):
        source_root = pathlib.Path(verifier.__file__).resolve().parents[1]
        paths = [verifier.GENERATION_SCHEMA_RELATIVE_PATH, verifier.GENERATION_FIXTURE_RELATIVE_PATH]
        for modified in paths:
            with self.subTest(path=modified), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                for relative in paths:
                    target = root / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    data = (source_root / relative).read_bytes()
                    target.write_bytes(data + b"\n" if relative == modified else data)
                with patch.object(verifier, "__file__", str(root / "script" / "verifier.py")):
                    with self.assertRaisesRegex(verifier.VerificationError, "integrity validation"):
                        verifier.load_generation_contract()


if __name__ == "__main__":
    unittest.main()
