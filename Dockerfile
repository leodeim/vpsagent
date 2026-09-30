FROM golang:1.25-alpine AS builder
WORKDIR /src/vpsagent
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /vpsagent ./cmd/vpsagent

FROM alpine:latest
RUN apk add --no-cache procps docker-cli
COPY --from=builder /vpsagent /app/vpsagent
WORKDIR /app
ENTRYPOINT ["/app/vpsagent"]
