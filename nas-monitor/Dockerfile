FROM python:3.11-alpine

RUN apk add --no-cache iputils

WORKDIR /app
COPY monitor.py .

CMD ["python", "-u", "monitor.py"]
