#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "autoreview"
LOADER = SourceFileLoader("autoreview_downstream_test_target", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
AUTOREVIEW = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(AUTOREVIEW)


class DownstreamOverrideTests(unittest.TestCase):
    def reviewer_for(self, *args: str):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            sys, "argv", ["autoreview", *args]
        ):
            return AUTOREVIEW.reviewer_args(AUTOREVIEW.parse_args())[0]

    def test_model_and_reasoning_defaults(self) -> None:
        codex = self.reviewer_for()
        claude = self.reviewer_for("--engine", "claude")

        self.assertEqual((codex.model, codex.thinking), ("gpt-6.1-sol", "xhigh"))
        self.assertEqual((claude.model, claude.thinking), ("claude-opus-5-5", "xhigh"))

    def test_only_external_codex_base_url_uses_http_provider(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = Path(tempdir)
            repo = root / "repo"
            repo.mkdir()
            external_home = root / "host" / ".codex"
            external_home.mkdir(parents=True)
            (external_home / "config.toml").write_text(
                'openai_base_url = "https://codex-proxy.example/v1"\n',
                encoding="utf-8",
            )

            with mock.patch.dict(
                os.environ, {"CODEX_HOME": str(external_home)}, clear=True
            ):
                self.assertEqual(
                    AUTOREVIEW.codex_auth_config_flags(repo),
                    [
                        "-c",
                        'model_provider="autoreview_openai_http"',
                        "-c",
                        'model_providers.autoreview_openai_http.name="OpenAI"',
                        "-c",
                        'model_providers.autoreview_openai_http.base_url="https://codex-proxy.example/v1"',
                        "-c",
                        'model_providers.autoreview_openai_http.wire_api="responses"',
                        "-c",
                        "model_providers.autoreview_openai_http.requires_openai_auth=true",
                        "-c",
                        "model_providers.autoreview_openai_http.supports_websockets=false",
                        "-c",
                        "model_providers.autoreview_openai_http.supports_standalone_web_search=true",
                    ],
                )

            repo_home = repo / ".codex"
            repo_home.mkdir()
            (repo_home / "config.toml").write_text(
                'openai_base_url = "https://repo-controlled.invalid"\n',
                encoding="utf-8",
            )
            with mock.patch.dict(
                os.environ, {"CODEX_HOME": str(repo_home)}, clear=True
            ):
                self.assertEqual(AUTOREVIEW.codex_auth_config_flags(repo), [])


if __name__ == "__main__":
    unittest.main()
