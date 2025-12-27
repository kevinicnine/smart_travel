FROM dart:stable

WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

COPY . .
RUN dart pub get --offline

EXPOSE 8080
ENV PORT=8080

CMD ["dart", "run", "bin/server.dart"]
