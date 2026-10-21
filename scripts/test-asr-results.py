#!/usr/bin/env python3
"""Isolated ASR timing contract test; does not load models or read media."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("asr", Path(__file__).with_name("asr_server.py"))
asr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asr)

class TimingContractTests(unittest.TestCase):
    def test_text_without_alignment_never_fabricates_timing(self):
        asr.HAS_MLX = True
        asr.find_model_path = lambda repo, **kw: Path("/fake") if "ASR" in repo else None
        asr.get_loaded_model = lambda path: SimpleNamespace(generate=lambda *a, **kw: SimpleNamespace(text="Retained transcript", language="English"))
        result = asr.run_local_transcription("/unused")
        self.assertEqual(result["text"], "Retained transcript")
        self.assertEqual(result["segments"], [])
        self.assertEqual(result["alignment_status"], "unavailable")

if __name__ == "__main__": unittest.main()
