FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY router.py /app/router.py

ENV PYTHONUNBUFFERED=1

EXPOSE 8001

CMD ["uvicorn", "router:app", "--host", "0.0.0.0", "--port", "8001"]

