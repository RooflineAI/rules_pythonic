"""Shared core library - no pydantic version constraint.

This package declares a dependency on 'pydantic' without a version pin,
so it can participate in resolutions that pin either v1 or v2.
"""

from pydantic import BaseModel


class SharedModel(BaseModel):
    """A model that works with any pydantic version."""
    id: str
    label: str = ""
