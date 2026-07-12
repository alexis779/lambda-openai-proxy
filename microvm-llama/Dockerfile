# Application container for Lambda MicroVMs (built on ARM64 by the service).
# Uses official llama.cpp Ubuntu arm64 release binaries to keep image builds fast.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      python3 \
      libgomp1 \
      libcurl4 \
    && rm -rf /var/lib/apt/lists/*

ARG LLAMA_CPP_REF=b9977
ARG LLAMA_ASSET=llama-${LLAMA_CPP_REF}-bin-ubuntu-arm64.tar.gz

WORKDIR /opt/llama.cpp
RUN curl -fsSL "https://github.com/ggerganov/llama.cpp/releases/download/${LLAMA_CPP_REF}/${LLAMA_ASSET}" \
      -o /tmp/llama.tar.gz \
    && tar -xzf /tmp/llama.tar.gz -C /opt/llama.cpp \
    && rm /tmp/llama.tar.gz \
    && BIN="$(find /opt/llama.cpp -type f -name llama-server | head -n 1)" \
    && test -n "${BIN}" \
    && ln -sf "${BIN}" /opt/llama.cpp/llama-server \
    && chmod +x /opt/llama.cpp/llama-server \
    && /opt/llama.cpp/llama-server --version || true

COPY hooks_server.py /opt/hooks_server.py
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh /opt/hooks_server.py

ENV LLAMA_BIN=/opt/llama.cpp/llama-server \
    LLAMA_HF_REPO=openbmb/MiniCPM5-1B-GGUF:Q4_K_M \
    LLAMA_THREADS=16 \
    LLAMA_CTX_SIZE=2048 \
    HOOKS_PORT=8090 \
    LLAMA_PORT=8080 \
    LLAMA_HEALTH_URL=http://127.0.0.1:8080/health

EXPOSE 8080 8090

CMD ["/opt/entrypoint.sh"]
