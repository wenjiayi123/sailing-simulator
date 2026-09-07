"""Keep privacy checks strict while preserving frozen continuation code."""
from pathlib import Path
import unittest

from tools.public_privacy_scan import _contains_forbidden_topic, LOCAL_ACCOUNT_RE


class PublicPrivacyScanTests(unittest.TestCase):
    def test_only_exact_continuation_source_lines_are_allowed(self):
        word = "res" + "ume"
        line = "var " + word + " := auto_switch"
        self.assertFalse(_contains_forbidden_topic(Path("policy.gd"), line))
        self.assertTrue(_contains_forbidden_topic(Path("notes.md"), line))
        self.assertTrue(_contains_forbidden_topic(Path("policy.gd"), line + " # personal document"))

    def test_frozen_training_comment_is_narrowly_recognized(self):
        line = "# constant 1000 on a " + "res" + "umed model silently skips replay warmup."
        self.assertFalse(_contains_forbidden_topic(Path("frozen.py"), line))
        self.assertTrue(_contains_forbidden_topic(Path("notes.md"), line))
        self.assertTrue(_contains_forbidden_topic(Path("frozen.py"), "# my " + "res" + "ume"))

    def test_private_paths_are_still_rejected(self):
        value = "/" + "Users" + "/example/private"
        self.assertIsNotNone(LOCAL_ACCOUNT_RE.search(value))
        line = "var " + "res" + "ume := auto_switch # " + value
        self.assertTrue(_contains_forbidden_topic(Path("policy.gd"), line))
        self.assertIsNotNone(LOCAL_ACCOUNT_RE.search(line))
