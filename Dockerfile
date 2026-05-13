# Use an official ggml-org/llama.cpp image as the base image
FROM ghcr.io/ggml-org/llama.cpp:server-cuda

ENV PYTHONUNBUFFERED=1

# Set up the working directory
WORKDIR /

RUN apt-get update --yes --quiet && DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet --no-install-recommends \
    software-properties-common \
    gpg-agent \
    build-essential apt-utils \
    && apt-get install --reinstall ca-certificates \
    && add-apt-repository --yes ppa:deadsnakes/ppa && apt update --yes --quiet \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet --no-install-recommends \
    python3.11 \
    python3.11-dev \
    python3.11-distutils \
    python3.11-lib2to3 \
    python3.11-gdbm \
    python3.11-tk \
    bash \
    curl && \
    ln -s /usr/bin/python3.11 /usr/bin/python && \
    curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /work

# Add ./src as /work
ADD ./src /work

# Install runpod and its dependencies
RUN pip install -r ./requirements.txt && chmod +x /work/start.sh

# Download LoRA adapter (11MB) into the image
RUN echo "Installing huggingface_hub..." && \
    python3.11 -m pip install --no-cache-dir huggingface_hub && \
    echo "Creating lora directory..." && \
    mkdir -p /work/lora && \
    echo "Downloading LoRA adapter..." && \
    python3.11 -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='flux777/tesseract-spark-official', filename='tesseract-spark-official-adapter.gguf', local_dir='/work/lora'); print('✓ LoRA adapter baked into image')"

# Set the entrypoint
ENTRYPOINT ["/bin/sh", "-c", "/work/start.sh"]
