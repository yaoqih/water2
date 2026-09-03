FROM python:3.12-slim

WORKDIR /app

COPY services/water_api_collector/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY services/water_api_collector /app

CMD ["python", "-m", "water_api_collector"]
