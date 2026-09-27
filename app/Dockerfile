FROM python:3.13-alpine

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PYTHONUNBUFFERED=1 \
    PORT=8080

RUN adduser -D -u 10001 app
WORKDIR /app
COPY server.py .

USER 10001
EXPOSE 8080
CMD ["python", "server.py"]
