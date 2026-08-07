FROM python:3.11-slim

WORKDIR /app

COPY gts_server.py /app/
COPY gts_database.json /app/

EXPOSE 7779

ENV PORT=7779

CMD ["python3", "-u", "gts_server.py"]
