FROM python:3.15-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chmod=644 registry.py .
COPY --chmod=755 templates/ ./templates/
RUN install -d -o 10001 -g 10001 -m 0700 /state && touch /state/.init && chown 10001:10001 /state/.init
USER 10001:10001
CMD ["gunicorn", "--preload", "--bind", "0.0.0.0:8000", "--workers", "2", "--threads", "4", "registry:create_app()"]
