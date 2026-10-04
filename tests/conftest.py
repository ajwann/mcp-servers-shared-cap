"""Load the two functions under test; both are main.py, so neither can be imported by name."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
CAP_ACCOUNT = "mcp-shared-spendcap@example-project.iam.gserviceaccount.com"

os.environ.update(
    SPEND_CAP_PROJECT="example-project",
    RESET_PROJECT="example-project",
    RESET_BILLING_ACCOUNT="000000-000000-000000",
    RESET_CAP_SA=CAP_ACCOUNT,
)


def _load(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="session")
def cap() -> ModuleType:
    return _load("spend_cap", REPO_ROOT / "function" / "main.py")


@pytest.fixture(scope="session")
def reset() -> ModuleType:
    return _load("spend_cap_reset", REPO_ROOT / "reset" / "main.py")
