FROM python:3.14.7-alpine3.24@sha256:05b2b8b732ecd268fee8727a369f936f022d1321b59befd13c30ede22769dcdc

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY exporter.py /app/exporter.py

USER 65532:65532

EXPOSE 8000

CMD ["python", "/app/exporter.py"]
