import torch
from mypackage import TinyModel


def test_forward():
    m = TinyModel()
    x = torch.randn(1, 4)
    y = m(x)
    assert y.shape == (1, 2)


def test_export_roundtrip():
    m = TinyModel()
    x = torch.randn(1, 4)
    exported = torch.export.export(m, (x,))
    y = exported.module()(x)
    assert y.shape == (1, 2)
