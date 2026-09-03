//! Dummy probe binary that exercises the AWS EC2, ECS and EKS resource
//! detectors from `opentelemetry-aws` and logs every resource attribute they
//! produce, then exits.
//!
//! Run with `RUST_LOG=debug` to also see the detectors' own internal
//! `tracing` events (which explain why a given attribute was skipped).

use opentelemetry::Value;
use opentelemetry_aws::detector::{
    Ec2ResourceDetector, EcsResourceDetector, EksResourceDetector,
};
use opentelemetry_sdk::resource::ResourceDetector;
use tracing::info;
use tracing_subscriber::EnvFilter;

fn main() {
    // Honour RUST_LOG; default to `debug` so the detectors' internal logs show
    // even if the caller forgot to set it.
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("debug"));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        // Plain text: CloudWatch Logs does not render ANSI colour codes.
        .with_ansi(false)
        .init();

    info!("otel-aws-probe starting: running EC2, ECS and EKS resource detectors");

    run_detector("EC2", &Ec2ResourceDetector);
    run_detector("ECS", &EcsResourceDetector);
    run_detector("EKS", &EksResourceDetector);

    info!("otel-aws-probe done");
}

/// Runs a single detector and logs the attributes it discovered, one event per
/// attribute plus a summary line, so the output is easy to grep in CloudWatch.
fn run_detector(name: &str, detector: &dyn ResourceDetector) {
    info!(detector = name, "---- running {name} detector ----");
    let resource = detector.detect();

    let mut count = 0usize;
    for (key, value) in resource.iter() {
        count += 1;
        info!(
            detector = name,
            attribute = %key,
            value = %render(value),
            "resource attribute"
        );
    }

    info!(
        detector = name,
        attribute_count = count,
        "---- {name} detector produced {count} attribute(s) ----"
    );
}

/// Renders an attribute value as a plain string for logging, flattening arrays.
fn render(value: &Value) -> String {
    match value {
        Value::String(s) => s.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::I64(i) => i.to_string(),
        Value::F64(f) => f.to_string(),
        other => format!("{other:?}"),
    }
}
