# Multi-stage build for Redpanda Kubernetes Node Tuner
# This container runs rpk redpanda tune and rpk iotune on Kubernetes nodes

FROM docker.redpanda.com/redpandadata/redpanda:latest AS redpanda-base

# Final image - use minimal base
FROM ubuntu:22.04

# Install required dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    procps \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

# Copy rpk binary from Redpanda image
COPY --from=redpanda-base /usr/bin/rpk /usr/bin/rpk

# Install kubectl for Kubernetes API interactions
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl

# Create working directory
WORKDIR /opt/redpanda-tuner

# Copy tuning scripts
COPY tune-lib.sh /opt/redpanda-tuner/
COPY tune.sh /opt/redpanda-tuner/

# Make scripts executable
RUN chmod +x /opt/redpanda-tuner/*.sh

# Set environment variables
ENV PATH="/opt/redpanda-tuner:${PATH}"

# Run as root (required for privileged operations)
USER root

# Entry point is the main tuning script
ENTRYPOINT ["/opt/redpanda-tuner/tune.sh"]
