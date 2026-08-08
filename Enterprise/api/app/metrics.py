# D1: minimal Prometheus text-exposition metrics with NO external dependencies.
# Counters/gauges/histograms are rendered by hand in the well-known exposition
# format so /metrics stays scrapable by stock Prometheus/Grafana.

import threading
from collections import OrderedDict

_LOCK = threading.Lock()
_REGISTRY: "OrderedDict[str, Metric]" = OrderedDict()

_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, float("inf"))


def _quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _fmt_num(v: float) -> str:
    if v == float("inf"):
        return "+Inf"
    if float(v).is_integer():
        return f"{int(v)}"
    if abs(v) >= 1e18 or (0 < abs(v) < 1e-6):
        return f"{v:.9g}"
    return f"{v:.6g}"


class Metric:
    """Base: registers in the global registry and builds label keys as
    rendered label strings (so a sample renders without re-escaping)."""

    def __init__(self, name: str, help: str, labelnames=()):
        if not name or any(c in name for c in "{}"):
            raise ValueError(f"bad metric name {name!r}")
        self._name = name
        self._help = help
        self.labelnames = tuple(labelnames)
        self._values = OrderedDict()
        self._lock = threading.Lock()
        with _LOCK:
            if name in _REGISTRY:
                raise ValueError(f"duplicate metric {name}")
            _REGISTRY[name] = self

    @property
    def name(self) -> str:
        return self._name

    def _label(self, labels) -> str:
        """Return the rendered label set, e.g. '{route="/ingest\",status="200"}'."""
        if not self.labelnames:
            return ""
        labels = labels or {}
        parts = []
        for ln in self.labelnames:
            v = labels.get(ln, "")
            if not isinstance(v, str):
                v = str(v)
            parts.append(f'{ln}={_quote(v)}')
        return "{" + ",".join(parts) + "}"

    def _labels_list(self):
        with self._lock:
            return list(self._values.items())


class Counter(Metric):
    _METRIC_TYPE = "counter"

    def inc(self, amount=1.0, labels=None):
        if not isinstance(amount, (int, float)) or amount < 0:
            raise ValueError(f"counter increment must be >= 0, got {amount!r}")
        k = self._label(labels)
        with self._lock:
            self._values[k] = self._values.get(k, 0.0) + amount

    def render(self):
        out = [f"# HELP {self._name} {self._help}", f"# TYPE {self._name} counter"]
        for k, v in self._labels_list():
            out.append(f"{self._name}{k} {_fmt_num(v)}")
        return "\n".join(out) + "\n"


class Gauge(Metric):
    _METRIC_TYPE = "gauge"

    def set(self, value: float, labels=None):
        k = self._label(labels)
        with self._lock:
            self._values[k] = float(value)

    def inc(self, amount=1.0, labels=None):
        k = self._label(labels)
        with self._lock:
            self._values[k] = self._values.get(k, 0.0) + amount

    def render(self):
        out = [f"# HELP {self._name} {self._help}", f"# TYPE {self._name} gauge"]
        for k, v in self._labels_list():
            out.append(f"{self._name}{k} {_fmt_num(v)}")
        return "\n".join(out) + "\n"


class Histogram(Metric):
    _METRIC_TYPE = "histogram"

    def __init__(self, name, help, labelnames=(), buckets=_BUCKETS):
        super().__init__(name, help, labelnames)
        self._buckets = tuple(sorted(buckets))
        self._values = OrderedDict()  # labelkey -> [counts..., sum]

    def observe(self, value: float, labels=None):
        if not isinstance(value, (int, float)) or value < 0:
            value = 0.0
        k = self._label(labels)
        with self._lock:
            entry = self._values.get(k)
            if entry is None:
                entry = [0] * len(self._buckets) + [0.0]
                self._values[k] = entry
            for i, ub in enumerate(self._buckets):
                if value <= ub:
                    entry[i] += 1
            entry[-1] += value

    def render(self):
        lines = [f"# HELP {self._name} {self._help}", f"# TYPE {self._name} histogram"]
        for k, entry in self._labels_list():
            inner = k.strip("{}")
            self._render_one(lines, inner, entry)
        return "\n".join(lines) + "\n"

    def _render_one(self, lines, inner: str, entry):
        bucket = self._buckets
        for i, ub in enumerate(bucket):
            le = 'le=' + _quote(_fmt_num(ub))
            labels = '{' + (inner + ',' + le if inner else le) + '}'
            lines.append(self._name + '_bucket' + labels + ' ' + _fmt_num(entry[i]))
        if inner:
            lines.append(self._name + '_sum{' + inner + '} ' + _fmt_num(entry[-1]))
            lines.append(self._name + '_count{' + inner + '} ' + str(int(entry[len(bucket) - 1])))
        else:
            lines.append(self._name + '_sum ' + _fmt_num(entry[-1]))
            lines.append(self._name + '_count ' + str(int(entry[len(bucket) - 1])))


def render_all() -> str:
    with _LOCK:
        names = list(_REGISTRY.keys())
    out = []
    for n in names:
        with _LOCK:
            m = _REGISTRY.get(n)
        if m is not None:
            out.append(m.render())
    return "".join(out)


# ---------------------------------------------------------------- app metrics
# Declared at import so every process has one instance; /metrics renders these.

# D1: HTTP traffic. http_requests counts every request by method/route/status;
# http_duration is a per-route histogram of request latency.
http_requests = Counter(
    "ittoolkit_http_requests_total",
    "Total HTTP requests by method, route, and status code",
    labelnames=("method", "route", "status"),
)
http_duration = Histogram(
    "ittoolkit_http_request_duration_seconds",
    "HTTP request latency in seconds by route",
    labelnames=("route",),
)

# D1: ingest path.
ingest_batches = Counter(
    "ittoolkit_ingest_batches_total",
    "Ingest batches handled, by outcome (accepted/rejected)",
    labelnames=("outcome",),
)
ingest_events = Counter(
    "ittoolkit_ingest_events_total",
    "Individual events persisted, by outcome (accepted/deduplicated/rejected)",
    labelnames=("outcome",),
)

# D1: alerting.
alerts_opened = Counter(
    "ittoolkit_alerts_opened_total",
    "Number of alerts opened by the evaluation loop",
)

# D1: gauges refreshed at scrape time.
agents_online = Gauge(
    "ittoolkit_agents_online",
    "Number of agents that reported within the last 15 minutes",
)
agents_total = Gauge(
    "ittoolkit_agents_total",
    "Number of registered agents (regardless of last_seen)",
)
alerts_open = Gauge(
    "ittoolkit_alerts_open",
    "Number of alerts currently with status 'open' or 'acknowledged'",
)
pending_commands = Gauge(
    "ittoolkit_pending_commands",
    "Commands issued but not yet completed by an agent",
)