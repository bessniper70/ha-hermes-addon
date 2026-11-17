ARG BUILD_VERSION=dev
ARG BUILD_ARCH=amd64
FROM nousresearch/hermes-agent:v0.23.2

ARG BUILD_VERSION
ARG BUILD_ARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl nginx \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/nginx

ARG TARGETARCH
RUN ARCH=$(echo ${TARGETARCH:-$(dpkg --print-architecture)} | sed 's|arm64|aarch64|;s|amd64|x86_64|') \
    && curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ARCH}" -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

LABEL \
  io.hass.version="${BUILD_VERSION}" \
  io.hass.type="app" \
  io.hass.arch="${BUILD_ARCH}"

ENV HERMES_HOME=/data

COPY ingress.conf /etc/nginx/nginx.conf
COPY landing.html /usr/share/nginx/html/index.html
COPY addon-run.sh /addon-run.sh
COPY run.sh /etc/cont-init.d/03-addon-config
COPY s6-rc.d/addon-ingress/ /etc/s6-overlay/s6-rc.d/addon-ingress/
COPY s6-rc.d/user/contents.d/addon-ingress /etc/s6-overlay/s6-rc.d/user/contents.d/addon-ingress
RUN chmod a+x /etc/cont-init.d/03-addon-config /addon-run.sh /usr/local/bin/ttyd

CMD ["gateway", "run"]
