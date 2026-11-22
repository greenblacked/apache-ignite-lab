FROM python:3.15.2-alpine3.24@sha256:0f9552bb28711333da16915ec146f5e6bb44a7fdac9ced15dc17c2e0206346dd

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY exporter.py /app/exporter.py

USER 65532:65532

EXPOSE 8000

CMD ["python", "/app/exporter.py"]
