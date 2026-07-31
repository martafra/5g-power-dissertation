#!/usr/bin/env python3
from contextlib import suppress
import os
import json
from time import sleep
import threading
import websocket

def _on_open(ws: websocket.WebSocketApp):
    ws.send(json.dumps({"cmd": "metrics_subscribe"}))

def _on_message(_ws: websocket.WebSocketApp, message: str):
    with suppress(json.JSONDecodeError):
        metric = json.loads(message)
        if "cmd" not in metric:
            print(json.dumps(metric), flush=True)

def connect(url: str):
    ws_app = websocket.WebSocketApp(
        "ws://" + url,
        on_open=_on_open,
        on_message=_on_message,
    )
    while ws_app.run_forever():
        sleep(1)

if __name__ == "__main__":
    urls = os.environ["WS_URL"].split(",")
    threads = []
    for url in urls[:-1]:
        t = threading.Thread(target=connect, args=(url,), daemon=True)
        t.start()
        threads.append(t)
    # Run last URL in main thread
    connect(urls[-1])
