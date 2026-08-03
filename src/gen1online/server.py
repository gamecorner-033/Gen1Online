"""Server entry point: logging setup, banner and uvicorn bootstrap.

The HTTP transport lives in :mod:`gen1online.api`; this module only wires
configuration, logging and the ASGI server together.
"""

import logging

import uvicorn

from gen1online import config
from gen1online.api import create_app
from gen1online.logging_utils import setup_logging

logger = logging.getLogger(__name__)


def run_server():
    setup_logging()
    logger.info(f"Log level: {config.LOG_LEVEL}")
    logger.info(f"Admin API: {'ENABLED' if config.ADMIN_TOKEN else 'DISABLED (set ADMIN_TOKEN to enable)'}")
    logger.info(f"Gen1Online Fast High-Performance Server (Port {config.PORT})")
    logger.info("Live Network Challenges: ENABLED (PVP & Link Trade)")
    logger.info("Guaranteed Challenge Delivery: ENABLED")
    logger.info("Multi-Room Lockstep Battle System: ENABLED")
    logger.info("In-Memory Position Sync: ENABLED (<1ms latency)")

    # log_config=None keeps our logging_utils handler (uvicorn must not clobber it).
    uvicorn.run(create_app(), host=config.HOST, port=config.PORT, log_config=None, access_log=False)


if __name__ == "__main__":
    run_server()
