from __future__ import annotations

import json
import subprocess
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class DeviceError(RuntimeError):
    pass


class NodeTransport(ABC):
    node_id: str
    role: str

    @abstractmethod
    def command(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError

    @abstractmethod
    def collect_events(self) -> list[dict[str, Any]]:
        raise NotImplementedError

    def close(self) -> None:
        return None


def _run(command: list[str], timeout: float = 15) -> str:
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise DeviceError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}")
    return result.stdout


def discover_adb(adb: str = "adb") -> list[str]:
    lines = _run([adb, "devices"]).splitlines()[1:]
    return [line.split()[0] for line in lines if line.strip().endswith("\tdevice")]


def discover_serial() -> list[str]:
    try:
        from serial.tools import list_ports
    except ImportError as error:
        raise DeviceError("pyserial is required for ESP32 discovery") from error
    return [port.device for port in list_ports.comports()]


def _extract_json_lines(text: str) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    for line in text.splitlines():
        start = line.find("{")
        if start < 0:
            continue
        try:
            value = json.loads(line[start:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            values.append(value)
    return values


@dataclass
class AdbNode(NodeTransport):
    node_id: str
    role: str
    serial: str
    adb: str = "adb"
    package: str = "id.ac.usu.resqmesh"
    receiver: str = "id.ac.usu.resqmesh.ResearchCommandReceiver"

    def command(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        command_id = str(arguments.get("command_id", ""))
        base = [
            self.adb,
            "-s",
            self.serial,
            "shell",
            "am",
            "broadcast",
            "-a",
            f"{self.package}.RESEARCH_COMMAND",
            "-n",
            f"{self.package}/{self.receiver}",
            "--es",
            "command",
            name,
        ]
        for key, value in arguments.items():
            if isinstance(value, bool):
                base.extend(["--ez", key, str(value).lower()])
            elif isinstance(value, int):
                base.extend(["--ei", key, str(value)])
            elif isinstance(value, float):
                base.extend(["--ef", key, str(value)])
            elif isinstance(value, list):
                base.extend(["--esa", key, ",".join(str(item) for item in value)])
            elif value is not None:
                base.extend(["--es", key, str(value)])
        _run(base)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            logs = _run(
                [self.adb, "-s", self.serial, "logcat", "-d", "-s", "ResQMeshCommand:I"],
            )
            candidates = _extract_json_lines(logs)
            for candidate in reversed(candidates):
                if not command_id or candidate.get("command_id") == command_id:
                    return candidate
            time.sleep(0.2)
        raise DeviceError(f"no Android response for {name} ({command_id})")

    def collect_events(self) -> list[dict[str, Any]]:
        logs = _run([self.adb, "-s", self.serial, "logcat", "-d"])
        return [item for item in _extract_json_lines(logs) if item.get("event_type")]

    def host_clock_offset_ms(self) -> float:
        before = time.time_ns() / 1_000_000
        raw = _run([self.adb, "-s", self.serial, "shell", "date", "+%s%3N"]).strip()
        after = time.time_ns() / 1_000_000
        device_ms = int(raw)
        return ((before + after) / 2) - device_ms


@dataclass
class SerialNode(NodeTransport):
    node_id: str
    role: str
    port: str
    baudrate: int = 115200
    timeout: float = 0.2
    _serial: Any = field(default=None, init=False, repr=False)
    _events: list[dict[str, Any]] = field(default_factory=list, init=False, repr=False)

    def _connection(self) -> Any:
        if self._serial is None:
            try:
                import serial
            except ImportError as error:
                raise DeviceError("pyserial is required for ESP32 commands") from error
            self._serial = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
            time.sleep(0.5)
        return self._serial

    def _read_value(self, deadline: float) -> dict[str, Any] | None:
        connection = self._connection()
        while time.monotonic() < deadline:
            raw = connection.readline()
            if not raw:
                continue
            try:
                value = json.loads(raw.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                continue
            if value.get("kind") == "event":
                self._events.append(value)
            else:
                return value
        return None

    def command(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        payload = {"command": name, **arguments}
        connection = self._connection()
        connection.write((json.dumps(payload, separators=(",", ":")) + "\n").encode())
        connection.flush()
        command_id = arguments.get("command_id")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            value = self._read_value(deadline)
            if value is None:
                break
            if not command_id or value.get("command_id") == command_id:
                return value
        raise DeviceError(f"no serial response for {name} ({command_id}) on {self.port}")

    def collect_events(self) -> list[dict[str, Any]]:
        deadline = time.monotonic() + 0.4
        while time.monotonic() < deadline:
            value = self._read_value(deadline)
            if value is None:
                break
        events, self._events = self._events, []
        return events

    def close(self) -> None:
        if self._serial is not None:
            self._serial.close()
            self._serial = None


def write_jsonl(path: Path, events: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as output:
        for event in events:
            output.write(json.dumps(event, sort_keys=True) + "\n")
