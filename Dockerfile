# volvo-exporter, for the flux volvo-exporter Deployment: static binary on
# scratch with the CA bundle, running as 65532 to match the manifests'
# securityContext. Tokens live on the PVC the Deployment mounts at /data.

FROM docker.io/library/golang:1.25-bookworm@sha256:ea341baa9bd5ba6784f6d7161ace70544349a6242d54d34a0fbfd2c4d51c9d58 AS build

WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /volvo-exporter ./cmd/volvo-exporter

FROM scratch

COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /volvo-exporter /volvo-exporter

USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/volvo-exporter"]
