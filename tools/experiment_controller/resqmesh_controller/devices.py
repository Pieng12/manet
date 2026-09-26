from __future__ import annotations

import json
import subprocess
import threading
import time
from abc import ABC, abstractmethod
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class DeviceError(RuntimeError):
    pass


class NodeTransport(ABC):
    node_id: str
    role: str
    transport: str

    @abstractmethod
    def command(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        raise NotImplementedError

    @abstractmethod
    def collect_events(
        self,
        session_id: str | None = None,
        trial_id: str | None = None,
    ) -> list[dict[str, Any]]:
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


def discover_adb(adb: str = "adb") -> list[dict[str, str]]:
    lines = _run([adb, "devices", "-l"]).splitlines()[1:]
    devices: list[dict[str, str]] = []
    for line in lines:
        fields = line.split()
        if len(fields) < 2:
            continue
        record = {"serial": fields[0], "status": fields[1]}
        for value in fields[2:]:
            if ":" in value:
                key, item = value.split(":", 1)
                record[key] = item
        devices.append(record)
    return devices


def discover_serial() -> list[dict[str, Any]]:
    try:
        from serial.tools import list_ports
    except ImportError as error:
        raise DeviceError("pyserial is required for ESP32 discovery") from error
    devices: list[dict[str, Any]] = []
    for port in list_ports.comports():
        description = port.description or ""
        bluetooth = "standard serial over bluetooth link" in description.lower()
        candidate = (
            not bluetooth
            and port.vid == 0x303A
            and port.pid == 0x1001
        )
        devices.append(
            {
                "port": port.device,
                "description": description,
                "vid": f"{port.vid:04X}" if port.vid is not None else None,
                "pid": f"{port.pid:04X}" if port.pid is not None else None,
                "serial_number": port.serial_number,
                "hardware_id": port.hwid,
                "esp32c3_candidate": candidate,
                "excluded_bluetooth_serial": bluetooth,
            }
        )
    return devices


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
    transport: str = field(default="adb", init=False)

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
                if (
                    "ok" in candidate
                    and (not command_id or candidate.get("command_id") == command_id)
                ):
                    return candidate
            time.sleep(0.2)
        raise DeviceError(f"no Android response for {name} ({command_id})")

    def collect_events(
        self,
        session_id: str | None = None,
        trial_id: str | None = None,
    ) -> list[dict[str, Any]]:
        logs = _run([self.adb, "-s", self.serial, "logcat", "-d", "-v", "raw"])
        events = [item for item in _extract_json_lines(logs) if item.get("event_type")]
        return [
            item
            for item in events
            if (session_id is None or item.get("session_id") == session_id)
            and (trial_id is None or item.get("trial_id") == trial_id)
        ]

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
    transport: str = field(default="serial", init=False)
    _serial: Any = field(default=None, init=False, repr=False)
    _events: list[dict[str, Any]] = field(default_factory=list, init=False, repr=False)
    _responses: deque[dict[str, Any]] = field(default_factory=deque, init=False, repr=False)
    _condition: threading.Condition = field(default_factory=threading.Condition, init=False, repr=False)
    _write_lock: threading.Lock = field(default_factory=threading.Lock, init=False, repr=False)
    _stop_reader: threading.Event = field(default_factory=threading.Event, init=False, repr=False)
    _reader: threading.Thread | None = field(default=None, init=False, repr=False)

    def _connection(self) -> Any:
        if self._serial is None:
            try:
                import serial
            except ImportError as error:
                raise DeviceError("pyserial is required for ESP32 commands") from error
            self._serial = serial.Serial(self.port, self.baudrate, timeout=self.timeout)
            time.sleep(0.5)
            self._stop_reader.clear()
            self._reader = threading.Thread(
                target=self._reader_loop,
                args=(self._serial,),
                name=f"resqmesh-{self.node_id}",
                daemon=True,
            )
            self._reader.start()
        return self._serial

    def _reader_loop(self, connection: Any) -> None:
        while not self._stop_reader.is_set():
            raw = connection.readline()
            if not raw:
                continue
            try:
                value = json.loads(raw.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                continue
            if not isinstance(value, dict):
                continue
            with self._condition:
                if value.get("kind") == "event" or value.get("event_type"):
                    self._events.append(value)
                else:
                    self._responses.append(value)
                self._condition.notify_all()

    def command(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        payload = {"command": name, **arguments}
        connection = self._connection()
        with self._write_lock:
            connection.write((json.dumps(payload, separators=(",", ":")) + "\n").encode())
            connection.flush()
        command_id = arguments.get("command_id")
        deadline = time.monotonic() + 8
        with self._condition:
            while time.monotonic() < deadline:
                for value in list(self._responses):
                    if not command_id or value.get("command_id") == command_id:
                        self._responses.remove(value)
                        return value
                self._condition.wait(timeout=max(0.0, deadline - time.monotonic()))
        raise DeviceError(f"no serial response for {name} ({command_id}) on {self.port}")

    def collect_events(
        self,
        session_id: str | None = None,
        trial_id: str | None = None,
    ) -> list[dict[str, Any]]:
        self._connection()
        with self._condition:
            events, self._events = self._events, []
        return [
            item
            for item in events
            if (session_id is None or item.get("session_id") == session_id)
            and (trial_id is None or item.get("trial_id") == trial_id)
        ]

    def close(self) -> None:
        if self._serial is not None:
            self._stop_reader.set()
            if self._reader is not None:
                self._reader.join(timeout=max(1.0, self.timeout * 3))
            self._serial.close()
            self._serial = None
            self._reader = None


def write_jsonl(path: Path, events: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as output:
        for event in events:
            output.write(json.dumps(event, sort_keys=True) + "\n")
