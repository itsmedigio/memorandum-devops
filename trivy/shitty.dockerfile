# 1. Old image
FROM ubuntu:18.04

# 2. Secrets leak
ENV DB_PASSWORD="SuperSegreta123!"

RUN apt-get update && apt-get install -y \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# 3. Root user
CMD ["/bin/bash"]