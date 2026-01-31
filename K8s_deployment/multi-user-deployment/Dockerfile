FROM ubuntu:24.04


ARG DEBIAN_FRONTEND=noninteractive


# Base packages + NodeJS 20 + cleanup (fewer layers)
RUN apt-get update && apt-get install -y --no-install-recommends \
   build-essential libpam0g-dev git apt-transport-https libnss-extrausers \
   ca-certificates curl gnupg \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*


# Copy your local modified repo into the image
WORKDIR /opt/carta-controller
COPY carta-controller/ /opt/carta-controller/


# Install deps + build (adjust if your repo uses a build step)
RUN git submodule update --init --recursive \
 && npm install --dev \
 && npm install -g .


ENTRYPOINT ["/usr/bin/carta-controller"]

