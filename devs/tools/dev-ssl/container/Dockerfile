# Official Crate image + dev keystore. Prefer Dockerfile.dist (local HTTP/3 build).
#
#   ./cli.sh generate
#   podman build -f container/Dockerfile --build-arg KEYSTORE=tmp/keystore.p12 -t crate-http3-dev .
#
# Host :443 is published by cli.sh container run (--publish-port 443 --sudo).

FROM docker.io/crate:latest

ARG KEYSTORE=keystore.p12
COPY ${KEYSTORE} /config/keystore.p12

EXPOSE 4200/tcp
EXPOSE 4200/udp

CMD ["crate", \
  "-Cdiscovery.type=single-node", \
  "-Cnetwork.host=0.0.0.0", \
  "-Chttp.port=4200", \
  "-Chttp.quic.enabled=true", \
  "-Cssl.http.enabled=true", \
  "-Cssl.keystore_filepath=/config/keystore.p12", \
  "-Cssl.keystore_password=keystorePassword", \
  "-Cssl.keystore_key_password=keystorePassword", \
  "-Cauth.host_based.config.10.user=crate", \
  "-Cauth.host_based.config.10.address=0.0.0.0/0", \
  "-Cauth.host_based.config.10.method=trust"]
