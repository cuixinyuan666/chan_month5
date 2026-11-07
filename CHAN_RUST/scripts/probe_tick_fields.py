#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""检查 0x0fc6 分笔原始记录的全部字段：买卖方向分布、保留字段是否非 0。"""
import json
import socket
import struct
import zlib

HOSTS = ["101.35.121.35", "101.33.225.16", "119.97.185.59"]
INIT = bytes.fromhex("0c0218940001030003000d0001")
AUTH = bytes.fromhex(
    "0c031899000120002000db0f7464786c6576656c000000295cf740110000000000000000000000000005"
)


def recv_n(s, n):
    b = b""
    while len(b) < n:
        x = s.recv(n - len(b))
        if not x:
            break
        b += x
    return b


def call(s, pkg):
    s.sendall(pkg)
    head = recv_n(s, 16)
    z, u = struct.unpack("<HH", head[12:16])
    body = recv_n(s, z)
    if z != u and body:
        body = zlib.decompress(body)
    return body


def get_price(data, pos):
    b = data[pos]
    intdata = b & 0x3F
    sign = (b & 0x40) != 0
    if b & 0x80:
        shift = 6
        while True:
            pos += 1
            b = data[pos]
            intdata += (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                break
    pos += 1
    return (-intdata if sign else intdata), pos


def main():
    s = socket.create_connection((HOSTS[0], 7709), timeout=8)
    s.settimeout(15)
    call(s, INIT)
    call(s, AUTH)

    for code, mkt, date in (("000572", 0, 20240102), ("600519", 1, 20240102)):
        pkg = bytes.fromhex("0c013002020112001200c60f")
        pkg += struct.pack("<I", date) + struct.pack("<H", mkt) + code.encode()
        pkg += struct.pack("<HH", 0, 800)
        body = call(s, pkg)
        n = struct.unpack("<H", body[:2])[0]
        pos = 6
        last = 0
        side = {0: 0, 1: 0, 2: 0, 9: 0}
        reserved_nonzero = 0
        tick_zero = 0
        rows = []
        for _ in range(n):
            tm = struct.unpack("<H", body[pos : pos + 2])[0]
            pos += 2
            pr, pos = get_price(body, pos)
            vol, pos = get_price(body, pos)
            num, pos = get_price(body, pos)
            bs, pos = get_price(body, pos)
            rsv, pos = get_price(body, pos)
            last += pr
            side[bs if bs in side else 9] += 1
            if rsv != 0:
                reserved_nonzero += 1
            if num == 0:
                tick_zero += 1
            if len(rows) < 3:
                rows.append((tm // 60, tm % 60, last / 100, vol, num, bs, rsv))
        print(f"{code} {date}: rows={n} side={side} reserved_nonzero={reserved_nonzero} ticks_zero={tick_zero}")
        for r in rows:
            print("   ", r)
    s.close()


if __name__ == "__main__":
    main()
