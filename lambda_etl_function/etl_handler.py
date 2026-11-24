"""
AWS Lambda function: intrusion-etl-fn
Replaces AWS Glue for this project so the entire pipeline stays within the
AWS Always-Free tier (Lambda is free up to 1M requests/month, forever --
Glue bills per DPU-hour from the very first run, with no free tier).

Triggered by S3 ObjectCreated events on the RAW bucket. Cleans and encodes
each uploaded batch, then writes curated Parquet to the CURATED bucket --
which in turn triggers intrusion-scoring-fn, exactly as it did when Glue
was doing this step.

Deploy: package this file + model_artifacts/label_encoders.pkl +
        model_artifacts/feature_columns.pkl + dependencies into a zip
        (see scripts/package_etl_lambda.sh) and upload as the Lambda code.
"""
import io
import os
import urllib.parse

import boto3
import joblib
import pandas as pd

s3 = boto3.client("s3")

CURATED_BUCKET = os.environ["CURATED_BUCKET"]
MODEL_BUCKET = os.environ["MODEL_BUCKET"]
ENCODERS_KEY = os.environ.get("ENCODERS_KEY", "label_encoders.pkl")
FEATURES_KEY = os.environ.get("FEATURES_KEY", "feature_columns.pkl")

# Full NSL-KDD column layout -- matches the raw files this project uses.
# If you swap in a different log source later, update this list to match.
RAW_COLUMNS = [
    "duration", "protocol_type", "service", "flag", "src_bytes", "dst_bytes", "land",
    "wrong_fragment", "urgent", "hot", "num_failed_logins", "logged_in", "num_compromised",
    "root_shell", "su_attempted", "num_root", "num_file_creations", "num_shells",
    "num_access_files", "num_outbound_cmds", "is_host_login", "is_guest_login", "count",
    "srv_count", "serror_rate", "srv_serror_rate", "rerror_rate", "srv_rerror_rate",
    "same_srv_rate", "diff_srv_rate", "srv_diff_host_rate", "dst_host_count",
    "dst_host_srv_count", "dst_host_same_srv_rate", "dst_host_diff_srv_rate",
    "dst_host_same_src_port_rate", "dst_host_srv_diff_host_rate", "dst_host_serror_rate",
    "dst_host_srv_serror_rate", "dst_host_rerror_rate", "dst_host_srv_rerror_rate",
    "label", "difficulty",
]

CATEGORICAL_COLUMNS = ["protocol_type", "service", "flag"]

_encoders = None
_feature_columns = None


def _load_artifacts():
    """Load once per warm Lambda container, not on every invocation."""
    global _encoders, _feature_columns
    if _encoders is None:
        s3.download_file(MODEL_BUCKET, ENCODERS_KEY, "/tmp/label_encoders.pkl")
        s3.download_file(MODEL_BUCKET, FEATURES_KEY, "/tmp/feature_columns.pkl")
        _encoders = joblib.load("/tmp/label_encoders.pkl")
        _feature_columns = joblib.load("/tmp/feature_columns.pkl")
    return _encoders, _feature_columns


def lambda_handler(event, context):
    encoders, feature_columns = _load_artifacts()
    results = []

    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        local_path = f"/tmp/{os.path.basename(key)}"

        print(f"[ETL Lambda] Processing s3://{bucket}/{key}")
        s3.download_file(bucket, key, local_path)

        raw = pd.read_csv(local_path, names=RAW_COLUMNS)
        raw = raw.dropna(subset=feature_columns)

        clean = raw[feature_columns].copy()
        for col in CATEGORICAL_COLUMNS:
            encoder = encoders[col]
            clean[col] = clean[col].map(
                lambda val: encoder.transform([val])[0] if val in encoder.classes_ else -1
            )

        # Keep alongside for dashboard/debugging -- harmless extra column
        if "label" in raw.columns:
            clean["_true_label"] = raw["label"].apply(lambda x: "normal" if x == "normal" else "attack")

        buffer = io.StringIO()
        clean.to_csv(buffer, index=False)

        curated_key = f"curated/{os.path.splitext(os.path.basename(key))[0]}.csv"
        s3.put_object(Bucket=CURATED_BUCKET, Key=curated_key, Body=buffer.getvalue().encode("utf-8"))

        print(f"[ETL Lambda] Wrote {len(clean)} cleaned rows to s3://{CURATED_BUCKET}/{curated_key}")
        results.append({"input": key, "output": curated_key, "rows": len(clean)})

    return {"statusCode": 200, "batches_processed": results}
