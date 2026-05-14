#!/bin/bash

echo "=== START.SH ENTRYPOINT REACHED ===" >&2
echo "=== START.SH ENTRYPOINT REACHED ==="

# fail on error:
set -e -o pipefail

# This script starts the llama-server with the command line arguments
# specified in the environment variable LLAMA_SERVER_CMD_ARGS, ensuring
# that the server listens on port 3098. It also starts the handler.py
# script after the server is up and running.

cleanup() {
    echo "start.sh: Cleaning up..."
    pkill -P $$ # kill all child processes of the current script
    exit 0
}

CACHED_LLAMA_ARGS=""
CACHED_LORA_ARGS=""

find_cached_path() {
    CACHED_LLAMA_ARGS="-m $(python ./find_cached.py $LLAMA_CACHED_MODEL $LLAMA_CACHED_GGUF_PATH)"
}

find_cached_lora() {
    LORA_PATH=$(python ./find_cached.py $LLAMA_CACHED_LORA $LLAMA_CACHED_LORA_PATH)
    if [ "$LORA_PATH" != "None" ] && [ -f "$LORA_PATH" ]; then
        CACHED_LORA_ARGS="--lora $LORA_PATH"
    else
        echo "start.sh: WARNING: LoRA adapter not found in cache. Will download on first use..."
        # Download the LoRA adapter from HuggingFace
        python3 -c "
from huggingface_hub import hf_hub_download
import os
lora_path = hf_hub_download(
    repo_id='$LLAMA_CACHED_LORA',
    filename='$LLAMA_CACHED_LORA_PATH',
    cache_dir='/runpod-volume/huggingface-cache'
)
print(lora_path, end='')
" > /tmp/lora_path.txt
        LORA_PATH=$(cat /tmp/lora_path.txt)
        if [ -f "$LORA_PATH" ]; then
            CACHED_LORA_ARGS="--lora $LORA_PATH"
            echo "start.sh: Downloaded LoRA adapter to: $LORA_PATH"
        else
            echo "start.sh: ERROR: Failed to download LoRA adapter"
            CACHED_LORA_ARGS=""
        fi
    fi
}

# check if $LLAMA_CACHED_MODEL is set and not empty
if [ -n "$LLAMA_CACHED_MODEL" ]; then
    echo "start.sh: Caching is enabled. Finding cached model path..."
    find_cached_path

    echo "start.sh: Using cached model with arguments: $CACHED_LLAMA_ARGS"
else
    echo "start.sh: WARNING: Caching is disabled. Please visit the inference-worker README and docs to learn more."
fi

# Check for LoRA adapter (baked-in or cached)
BAKED_LORA="/work/lora/tesseract-spark-official-adapter.gguf"
if [ -f "$BAKED_LORA" ]; then
    echo "start.sh: Using baked-in LoRA adapter"
    CACHED_LORA_ARGS="--lora $BAKED_LORA"
    echo "start.sh: LoRA arguments: $CACHED_LORA_ARGS"
elif [ -n "$LLAMA_CACHED_LORA" ]; then
    echo "start.sh: LoRA caching is enabled. Finding cached LoRA adapter path..."
    find_cached_lora
    echo "start.sh: Using cached LoRA with arguments: $CACHED_LORA_ARGS"
fi

# check if $LLAMA_SERVER_CMD_ARGS is set
if [ -z "$LLAMA_SERVER_CMD_ARGS" ]; then
    echo "start.sh: Warning: LLAMA_SERVER_CMD_ARGS is not set. Defaulting to -hf unsloth/gemma-3-270m-it-GGUF:IQ2_XXS --ctx-size 512 -ngl 999"
    LLAMA_SERVER_CMD_ARGS="-hf unsloth/gemma-3-270m-it-GGUF:IQ2_XXS --ctx-size 512 -ngl 999"
fi

# check if the substring --port is in LLAMA_SERVER_CMD_ARGS and if yes, raise an error:
if [[ "$LLAMA_SERVER_CMD_ARGS" == *"--port"* ]]; then
    echo "start.sh: Error: You must not define --port in LLAMA_SERVER_CMD_ARGS, as port 3098 is required."
    exit 1
fi

# trap exit signals and call the cleanup function
trap cleanup SIGINT SIGTERM

# kill any existing llama-server processes
echo "start.sh: Stopping existing llama-server instances (if any)..."
{
    pkill llama-server 2>/dev/null
} || {
    echo "start.sh: No llama-server running"
}

# we have a string with all the command line arguments in the env var LLAMA_SERVER_CMD_ARGS;
# it contains a.e. "-hf modelname --ctx-size 4096 -ngl 999".

echo "start.sh: Running /app/llama-server $CACHED_LLAMA_ARGS $CACHED_LORA_ARGS $LLAMA_SERVER_CMD_ARGS --port 3098"

touch llama.server.log

# We need to pass these arguments to llama-server verbatim.
LD_LIBRARY_PATH=/app /app/llama-server $CACHED_LLAMA_ARGS $CACHED_LORA_ARGS $LLAMA_SERVER_CMD_ARGS --port 3098 2>&1 | tee llama.server.log &

LLAMA_SERVER_PID=$! # store the process ID (PID) of the background command

tries_so_far=0

check_server_is_running() {
    echo "start.sh: Checking if llama-server is done initializing..."

    if cat llama.server.log | grep -q "listening"; then
        return 0 # success
    else
        return 1 # failure
    fi

    tries_so_far=$((tries_so_far + 1))

    if [ $tries_so_far -ge 120 ]; then
        echo "start.sh: Error: llama-server did not start within 60 seconds."
        exit 1
    fi

    # check if the process is still running
    if ! kill -0 $LLAMA_SERVER_PID 2>/dev/null; then
        echo "start.sh: Error: llama-server process has exited unexpectedly."
        exit 1
    fi
}

echo "start.sh: Waiting for llama-server to start..."

# wait for the server to start
while ! check_server_is_running; do
    # we don't want to lose too much time, so we check very frequently
    sleep 0.5
done

echo "start.sh: llama-server is up and running, delegating to the handler script."

echo "start.sh: About to execute: python -u handler.py $1"
exec python -u handler.py $1
