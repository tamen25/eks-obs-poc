"""Demo service: one trace per fake order, and a log line per step carrying the trace ID.

The trace goes to the OpenTelemetry collector (OTEL_EXPORTER_OTLP_ENDPOINT); the log lines go
to stdout, where Fluent Bit picks them up like any container's. Grafana links the two by the
trace_id field.
"""
import random
import time

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

# Resource.create() reads OTEL_SERVICE_NAME; the exporter reads OTEL_EXPORTER_OTLP_ENDPOINT.
provider = TracerProvider(resource=Resource.create())
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(insecure=True)))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("demo-checkout")


def log(level, msg, **fields):
    ctx = trace.get_current_span().get_span_context()
    fields["trace_id"] = format(ctx.trace_id, "032x")
    fields["span_id"] = format(ctx.span_id, "016x")
    print(f'level={level} msg="{msg}" ' + " ".join(f"{k}={v}" for k, v in fields.items()), flush=True)


order = 0
while True:
    order += 1
    with tracer.start_as_current_span("checkout") as span:
        span.set_attribute("order.id", order)
        log("info", "order received", order=order)

        with tracer.start_as_current_span("db.query"):
            time.sleep(random.uniform(0.01, 0.05))
            log("info", "stock checked", order=order)

        with tracer.start_as_current_span("payment") as payment:
            time.sleep(random.uniform(0.02, 0.1))
            if random.random() < 0.1:
                payment.set_status(Status(StatusCode.ERROR, "card declined"))
                log("error", "payment declined", order=order)
            else:
                log("info", "payment accepted", order=order)
    time.sleep(2)
