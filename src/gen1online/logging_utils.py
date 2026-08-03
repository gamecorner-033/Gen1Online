"""Logging bootstrap shared by the server and migration entry points.

Writes to stderr, which docker captures as the container's stdout log
(``docker compose logs``). Level is driven by the ``LOG_LEVEL`` env var.
"""

import logging
import sys

from gen1online.config import LOG_LEVEL

_FORMAT = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"


def setup_logging():
    logging.basicConfig(
        level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
        format=_FORMAT,
        stream=sys.stderr,
        force=True,
    )
    return logging.getLogger("gen1online")
