FROM dart:stable

WORKDIR /app
RUN apt-get update \
  && apt-get install -y python3 ca-certificates python3-certifi \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

EXPOSE 8080
ENV PORT=8080

CMD ["dart", "run", "bin/server.dart"]
