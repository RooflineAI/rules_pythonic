import tomli


def test_analysis_extra_importable():
    """tomli is only declared in [project.optional-dependencies].analysis.
    It's importable because extras=["test", "analysis"] was requested."""
    data = tomli.loads('[project]\nname = "foo"')
    assert data["project"]["name"] == "foo"
