# Runtime for modules/log-keeper. The script itself is mounted from a ConfigMap, so this image
# only provides the tools it calls: sh, stat, ln (busybox), inotifywait and GNU find.
#
# Build and push to your registry, then set log_keeper.image to the pushed reference, ideally
# by digest:
#   docker build -t <account>.dkr.ecr.<region>.amazonaws.com/log-keeper:1.0.0 .
#   docker push  <account>.dkr.ecr.<region>.amazonaws.com/log-keeper:1.0.0
FROM alpine:3.23.7

RUN apk add --no-cache inotify-tools findutils

# The DaemonSet runs this as root with every capability dropped; see modules/log-keeper.
ENTRYPOINT ["/bin/sh"]
