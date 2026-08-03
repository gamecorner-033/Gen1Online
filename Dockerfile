FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim

WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1

# Install dependencies and build the package first (better layer caching).
# gts_database.json (legacy seed data) is intentionally NOT shipped; migration
# is a one-time dev/ops tool run with `uv run gen1online-migrate`.
COPY pyproject.toml uv.lock README.md ./
COPY src/ ./src/
RUN uv sync --no-dev --frozen

EXPOSE 7779

ENV PORT=7779

CMD ["/app/.venv/bin/gen1online-server"]
