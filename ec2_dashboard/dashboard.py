"""
Intrusion Detection Dashboard
Reads the curated + scored data from S3 and displays recent anomalies,
traffic volume, and alert history. Runs on the EC2 instance.

Run with:
    streamlit run dashboard.py --server.port 80 --server.address 0.0.0.0

Requires the EC2 instance's IAM role to have read access to the curated
S3 bucket (see iam_policies/iam_ec2_dashboard_role_policy.json).
"""
import io
import os
from datetime import datetime

import boto3
import pandas as pd
import streamlit as st

st.set_page_config(
    page_title="Intrusion Detection Dashboard",
    page_icon="🛡️",
    layout="wide",
)

# ---------------------------------------------------------------------------
# Config — set these to match your deployment, or override via env vars
# ---------------------------------------------------------------------------
CURATED_BUCKET = os.environ.get("CURATED_BUCKET", "intrusion-detection-curated-<your-account-id>")
MAX_FILES_TO_LOAD = 20   # most recent N result files, to keep the dashboard fast
REFRESH_SECONDS = 30

s3 = boto3.client("s3")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
@st.cache_data(ttl=REFRESH_SECONDS, show_spinner=False)
def load_recent_batches(bucket: str, max_files: int) -> pd.DataFrame:
    """Pull the most recently written Parquet batches from the curated bucket."""
    try:
        paginator = s3.get_paginator("list_objects_v2")
        objects = []
        for page in paginator.paginate(Bucket=bucket):
            for obj in page.get("Contents", []):
                if obj["Key"].endswith(".parquet"):
                    objects.append(obj)
    except Exception as e:
        st.error(f"Couldn't list objects in s3://{bucket} — check bucket name and IAM permissions.\n\n{e}")
        return pd.DataFrame()

    if not objects:
        return pd.DataFrame()

    objects.sort(key=lambda o: o["LastModified"], reverse=True)
    recent = objects[:max_files]

    frames = []
    for obj in recent:
        try:
            resp = s3.get_object(Bucket=bucket, Key=obj["Key"])
            body = resp["Body"].read()
            df = pd.read_parquet(io.BytesIO(body))
            df["_source_file"] = obj["Key"]
            df["_file_timestamp"] = obj["LastModified"]
            frames.append(df)
        except Exception as e:
            st.warning(f"Skipped {obj['Key']}: {e}")

    if not frames:
        return pd.DataFrame()

    return pd.concat(frames, ignore_index=True)


# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
col_title, col_refresh = st.columns([5, 1])
with col_title:
    st.title("🛡️ Intrusion Detection Dashboard")
    st.caption(f"Reading from s3://{CURATED_BUCKET} · auto-refreshes every {REFRESH_SECONDS}s")
with col_refresh:
    if st.button("🔄 Refresh now"):
        st.cache_data.clear()

data = load_recent_batches(CURATED_BUCKET, MAX_FILES_TO_LOAD)

if data.empty:
    st.info(
        "No scored data found yet. Run the Glue ETL job and confirm the Lambda "
        "trigger fired — see Part 8 of the build guide to test end-to-end."
    )
    st.stop()

# Normalize expected columns (guards against schema drift between test runs)
if "is_anomaly" not in data.columns and "prediction" in data.columns:
    data["is_anomaly"] = data["prediction"] == "ANOMALY"
if "anomaly_score" not in data.columns:
    data["anomaly_score"] = 0.0

anomalies = data[data["is_anomaly"] == True]  # noqa: E712
normal = data[data["is_anomaly"] == False]  # noqa: E712

# ---------------------------------------------------------------------------
# Top metrics
# ---------------------------------------------------------------------------
m1, m2, m3, m4 = st.columns(4)
m1.metric("Connections scored", f"{len(data):,}")
m2.metric("Anomalies flagged", f"{len(anomalies):,}")
anomaly_rate = (len(anomalies) / len(data) * 100) if len(data) else 0
m3.metric("Anomaly rate", f"{anomaly_rate:.1f}%")
m4.metric("Batches loaded", data["_source_file"].nunique())

st.divider()

# ---------------------------------------------------------------------------
# Anomaly score distribution
# ---------------------------------------------------------------------------
st.subheader("Anomaly score distribution")
st.caption("Lower (more negative) scores = more anomalous. The threshold at 0 separates normal from flagged.")
score_hist = data["anomaly_score"].value_counts(bins=20, sort=False)
st.bar_chart(score_hist)

# ---------------------------------------------------------------------------
# Anomalies over time (by batch)
# ---------------------------------------------------------------------------
st.subheader("Anomalies per batch")
by_batch = (
    data.groupby("_source_file")
    .agg(total=("is_anomaly", "size"), anomalies=("is_anomaly", "sum"))
    .sort_index()
)
st.bar_chart(by_batch)

st.divider()

# ---------------------------------------------------------------------------
# Recent anomalies table
# ---------------------------------------------------------------------------
st.subheader(f"Most recent flagged connections ({len(anomalies)} total)")

if anomalies.empty:
    st.success("No anomalies in the most recent batches. Traffic looks normal.")
else:
    display_cols = [c for c in [
        "_file_timestamp", "duration", "protocol_type", "service", "flag",
        "src_bytes", "dst_bytes", "count", "srv_count", "anomaly_score",
    ] if c in anomalies.columns]

    sorted_anomalies = anomalies.sort_values("anomaly_score").head(100)
    st.dataframe(
        sorted_anomalies[display_cols],
        use_container_width=True,
        hide_index=True,
    )

    csv = sorted_anomalies[display_cols].to_csv(index=False).encode("utf-8")
    st.download_button(
        "Download flagged connections as CSV",
        data=csv,
        file_name=f"anomalies_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv",
        mime="text/csv",
    )

st.divider()
st.caption(
    "This dashboard is read-only by design — the EC2 IAM role has no write "
    "permissions on any bucket (see iam_policies/iam_ec2_dashboard_role_policy.json)."
)
