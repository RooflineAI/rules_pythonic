"""Search service for main workspace."""

from core import CoreModel


class SearchQuery(CoreModel):
    """Search query model."""
    query: str
    max_results: int = 10
