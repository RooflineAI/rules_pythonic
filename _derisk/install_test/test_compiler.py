"""Test that exercises the full roof_py import chain."""

import pytest
import torch
import numpy as np

from attic.compiler import compile


def test_compile_basic():
    result = compile("test.mlir")
    assert "torch=" in result
    assert "numpy=" in result


def test_torch_available():
    assert torch.tensor([1, 2, 3]).sum().item() == 6


def test_numpy_available():
    assert np.array([1, 2, 3]).sum() == 6


def test_import_metadata():
    import importlib.metadata

    assert importlib.metadata.version("torch") is not None
    assert importlib.metadata.version("numpy") is not None


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
