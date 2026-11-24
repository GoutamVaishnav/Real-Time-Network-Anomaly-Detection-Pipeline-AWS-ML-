"""
AWS Lambda function: intrusion-scoring-fn
Triggered by S3 ObjectCreated events on the curated bucket.
Scores incoming network connection batches with a pre-trained Isolation Forest
model and publishes an SNS alert when anomalies are found.

Deploy: package this file + model_artifacts/*.pkl + dependencies into a zip
        (see scripts/package_lambda.sh) and upload as the Lambda function code.
"""
import json
import os
import urllib.parse
import boto3
import joblib
import pandas as pd

s3 = boto3.client("s3")
sns = boto3.client("sns")

MODEL_PATH = "/tmp/isolation_forest_model.pkl"
FEATURES_PATH = "/tmp/feature_columns.pkl"
MODEL_BUCKET = os.environ["MODEL_BUCKET"]
MODEL_KEY = os.environ.get("MODEL_KEY", "isolation_forest_model.pkl")
FEATURES_KEY = os.environ.get("FEATURES_KEY", "feature_columns.pkl")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
ANOMALY_SCORE_THRESHOLD = float(os.environ.get("ANOMALY_SCORE_THRESHOLD", "0"))

_model = None
_feature_columns = None


def _load_model():
    """Load model once per warm Lambda container, not on every invocation."""
    global _model, _feature_columns
    if _model is None:
        s3.download_file(MODEL_BUCKET, MODEL_KEY, MODEL_PATH)
        s3.download_file(MODEL_BUCKET, FEATURES_KEY, FEATURES_PATH)
        _model = joblib.load(MODEL_PATH)
        _feature_columns = joblib.load(FEATURES_PATH)
    return _model, _feature_columns


def lambda_handler(event, context):
    model, feature_columns = _load_model()

    results = []
    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        local_path = f"/tmp/{os.path.basename(key)}"
        s3.download_file(bucket, key, local_path)

        batch = pd.read_csv(local_path)

        missing = set(feature_columns) - set(batch.columns)
        if missing:
            print(f"WARNING: batch {key} missing expected columns: {missing}, skipping")
            continue

        X = batch[feature_columns]
        scores = model.decision_function(X)
        predictions = model.predict(X)

        batch["anomaly_score"] = scores
        batch["is_anomaly"] = predictions == -1

        anomalies = batch[batch["is_anomaly"]]

        if len(anomalies) > 0:
            _publish_alert(key, anomalies)

        results.append({"key": key, "processed": len(batch), "anomalies": len(anomalies)})

    return {"statusCode": 200, "body": json.dumps(results)}


def _publish_alert(source_key, anomalies_df):
    summary_cols = [c for c in ["duration", "src_bytes", "dst_bytes", "count", "anomaly_score"]
                     if c in anomalies_df.columns]
    preview = anomalies_df[summary_cols].head(20).to_string(index=False)

    message = (
        f"Anomalous network activity detected in {source_key}\n"
        f"Anomalies found: {len(anomalies_df)}\n\n"
        f"Preview (first 20):\n{preview}"
    )

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[Alert] {len(anomalies_df)} anomalous connections detected",
        Message=message,
    )
