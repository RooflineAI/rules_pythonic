"""Core library for main workspace - requires pydantic v2."""

from pydantic import BaseModel


class CoreModel(BaseModel):
    """A simple model using pydantic v2 features."""

    name: str
    value: int = 0
