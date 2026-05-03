"""Module entrypoint so `python -m simmersmith_shopping ...` works."""
from .cli import main


if __name__ == "__main__":
    raise SystemExit(main())
