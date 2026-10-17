"""Load a hyphen-named script under scripts/ as an importable module for tests."""
import importlib.util
import pathlib
import sys
import types


def load_script(module_name: str, path: pathlib.Path) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(module_name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module
