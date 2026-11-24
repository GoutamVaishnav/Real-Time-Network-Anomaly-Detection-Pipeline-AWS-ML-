# Real-Time Network Intrusion Detection Pipeline (100% AWS Free Tier)

An unsupervised anomaly detection pipeline built entirely on AWS's Always-Free
services, using Isolation Forest to flag suspicious network connections in
near real time. Trained and validated on the NSL-KDD intrusion detection
benchmark dataset.

**This version uses two Lambda functions instead of AWS Glue** for the ETL
step, so the entire pipeline runs at **$0 cost**, indefinitely — Glue bills
per DPU-hour from its very first run with no free tier, while Lambda is
always free up to 1 million requests/month.

## Architecture

```
Raw logs -> S3 (raw zone) -> ETL Lambda (cleans + encodes)
    -> S3 (curated zone, Parquet) -> Scoring Lambda (Isolation Forest)
    -> SNS alert on anomalies -> EC2 dashboard (visualization)
```

Both S3 buckets have event notifications wired directly to their respective
Lambda — no manual job triggering, no scheduler needed. IAM roles are scoped
to least privilege at every stage (see `iam_policies/`).

## Project structure

```
lambda_etl_function/     ETL Lambda handler (replaces Glue: cleans, encodes features)
lambda_function/         Scoring Lambda handler (Isolation Forest inference, SNS alerts)
ec2_dashboard/           Streamlit dashboard + setup script for the EC2 instance
model_artifacts/         Trained Isolation Forest model + encoders + feature list
iam_policies/            Least-privilege IAM policy JSON for each component
glue_job/                Kept for reference only — NOT used in this free-tier version
scripts/
  train_and_save_model.py   Retrain the model on fresh data
  package_lambda.sh         Bundle either Lambda's code + dependencies (usage: etl|scoring)
  deploy.sh                 Full AWS CLI deployment, end to end
BUILD_GUIDE.md           Complete click-by-click console walkthrough
```

## Local results (validation before deployment)

Trained and tested on a sample of 2,000 normal + 200 attack connections from
NSL-KDD:

| contamination | attacks caught | false alarm rate |
|---|---|---|
| 0.03 | 42/200 (21%) | 1.2% |
| 0.09 | 102/200 (51%) | 4.8% |
| 0.15 | 173/200 (87%) | 7.8% |
| 0.25 | 196/200 (98%) | 17.7% |

Deployed with `contamination=0.09` as a balance between catch rate and alert
fatigue; tunable by retraining and re-uploading the model artifacts.

## Deploying

1. `aws configure` with credentials that can create IAM roles, S3 buckets,
   Lambda functions, and SNS topics.
2. Edit `scripts/deploy.sh`: set your email in Step 3.
3. From the project root: `bash scripts/deploy.sh`
4. Confirm the SNS email subscription (check your inbox).
5. Test: `aws s3 cp <any-csv> s3://<raw-bucket>/` and watch both Lambdas fire
   automatically in sequence.

For the full click-by-click console version (no CLI required), see
`BUILD_GUIDE.md`.

## Retraining the model

Run `scripts/train_and_save_model.py` on fresh/updated data, then re-upload
the three files in `model_artifacts/` to the model S3 bucket. Both Lambdas
download fresh artifacts on their next cold start.

## Cost

Every service here — S3, Lambda (x2), SNS, IAM, EC2 (t3.micro) — is free
within AWS's Always-Free or 12-month-free limits for normal test/demo
traffic. See the cost table in `BUILD_GUIDE.md` for the full breakdown.

## Known limitations (documented honestly, not glossed over)

- Isolation Forest catches "loud" anomalies (flood/scan attacks) far better
  than subtle, slow attacks that statistically resemble normal traffic —
  recall tops out around 50-90% depending on the false-alarm tolerance chosen.
- No adversarial robustness: an attacker aware of the feature set could
  potentially craft traffic that blends in.
- Single-model approach; production systems would layer this with
  signature-based rules and behavioral baselining per host/user.
- Lambda-based ETL is fine at this scale but won't out-scale a real Spark/Glue
  job on very large datasets — that trade-off is exactly why production
  systems use Glue despite the cost, and is worth mentioning in an interview.
