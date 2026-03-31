"""Pipeline service for legacy workspace - requires pydantic v1."""

from pydantic import BaseModel


class PipelineConfig(BaseModel):
    """Pipeline configuration using pydantic v1 style."""

    name: str
    batch_size: int = 100

    class Config:
        # pydantic v1 style config
        arbitrary_types_allowed = True
