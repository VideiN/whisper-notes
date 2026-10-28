"""CI에서 쓸 아이패드 시뮬레이터의 UDID를 고른다.

    xcrun simctl list devices available --json | python3 scripts/pick-simulator.py

가장 새 iOS 런타임에서 사용자 기기와 같은 iPad Pro를 먼저(이름순 마지막: 13형, 새 칩), 없으면 아무 아이패드나.
"""

import json
import sys


def runtime_version(runtime):
    # "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → (26, 5)
    return tuple(int(part) for part in runtime.rsplit(".iOS-", 1)[1].split("-"))


def pick(devices):
    runtimes = sorted((r for r in devices if ".iOS-" in r), key=runtime_version, reverse=True)
    for runtime in runtimes:
        ipads = [d for d in devices[runtime] if d["name"].startswith("iPad")]
        if not ipads:
            continue
        pro = [d for d in ipads if d["name"].startswith("iPad Pro")]
        return sorted(pro or ipads, key=lambda d: d["name"])[-1]
    return None


def main():
    device = pick(json.load(sys.stdin)["devices"])
    if device is None:
        sys.exit("no iPad simulator")
    print(f"{device['name']} ({device['udid']})", file=sys.stderr)
    print(device["udid"])


if __name__ == "__main__":
    main()
