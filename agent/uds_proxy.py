#!/usr/bin/env python3
"""TCP -> Unix-socket forwarder that runs INSIDE the sealed agent container.

The vLLM container has no network, so it listens on a socket file instead of a TCP port.
Agents (ours, or any OpenAI-compatible one) expect http://host:port/v1. This forwarder
listens on 127.0.0.1:<port> (the container's own loopback; nothing outside can reach it)
and copies every byte to and from the socket file, so the agent simply uses
    http://127.0.0.1:<port>/v1

    python3 uds_proxy.py <socket-path> <port>

Standard library only, Python 3.7+. Many connections at once (asyncio).
"""
import asyncio
import sys


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: uds_proxy.py <socket-path> <port>")
    sock, port = sys.argv[1], int(sys.argv[2])

    async def handle(client_r, client_w):
        try:
            model_r, model_w = await asyncio.open_unix_connection(sock)
        except OSError as e:
            print(f"uds_proxy: cannot reach {sock}: {e}", file=sys.stderr, flush=True)
            client_w.close()
            return
        await asyncio.gather(pipe(client_r, model_w), pipe(model_r, client_w))

    async def serve():
        server = await asyncio.start_server(handle, "127.0.0.1", port)
        print(f"uds_proxy: 127.0.0.1:{port} -> {sock}", file=sys.stderr, flush=True)
        async with server:
            await server.serve_forever()

    asyncio.run(serve())


if __name__ == "__main__":
    main()
