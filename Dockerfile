# Dockerfile
FROM golang:tip-alpine3.22 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /fiber-demo .

FROM alpine:latest
RUN apk add --no-cache ca-certificates
RUN apk add --no-cache curl # <-- This line is essential
COPY --from=builder /fiber-demo /fiber-demo
EXPOSE 3000
CMD ["/fiber-demo"]