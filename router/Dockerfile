FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/tailscale/tailscale:stable

RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    iproute2 \
    iptables \
    nftables \
    tzdata \
    && update-ca-certificates

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
