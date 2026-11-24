# 🛡️ Real-Time Network Intrusion Detection — Full Deployment Report

**Project:** Real-Time Network Intrusion Detection Pipeline on AWS Free Tier  
**Date:** November 24, 2026  
**AWS Account ID:** `509399621479`  
**Region:** `us-east-1`  
**Status:** 🟡 Pipeline Working — End-to-End Confirmation Pending

---

## 📌 Project Overview

Ek **real-time network intrusion detection system** jo AWS ke free tier pe chal raha hai.  
NSL-KDD dataset par train kiya hua **Isolation Forest** ML model network traffic logs me anomalies dhundhta hai aur **email alert** bhejta hai jab koi attack detect hota hai.

### Tech Stack
| Component | Technology |
|---|---|
| ML Model | Isolation Forest (scikit-learn 1.8.0, 200 estimators) |
| Data | NSL-KDD dataset (125,973 rows, 41 features) |
| ETL | AWS Lambda (Python 3.11) |
| Storage | AWS S3 (3 buckets) |
| ML Inference | AWS Lambda (Python 3.11) |
| Alerting | AWS SNS → Email |
| Libraries Layer | Custom-built Lambda Layer (~150 MB) |
| Cost | **$0 (100% AWS Free Tier)** |

---

## 🏗️ Full Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    USER (You / College Demo)                         │
│                                                                      │
│  Upload CSV file:                                                    │
│  aws s3 cp nsl_kdd_train.txt s3://intrusion-detection-raw-.../      │
└──────────────────────────┬──────────────────────────────────────────┘
                           │  S3 ObjectCreated trigger (automatic)
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│          S3 RAW BUCKET                                               │
│  intrusion-detection-raw-509399621479                                │
│  • Receives raw NSL-KDD CSV files                                    │
│  • 42-column format (no headers)                                     │
└──────────────────────────┬───────────────────────────────────────────┘
                           │  S3 trigger → fires automatically
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│          ETL LAMBDA:  intrusion-etl-fn                               │
│  Runtime: Python 3.11 | Memory: 512MB | Timeout: 60s                │
│                                                                      │
│  1. Downloads raw CSV from S3 to /tmp/                               │
│  2. Loads label_encoders.pkl from Models bucket                      │
│  3. Drops rows with missing feature values                           │
│  4. Encodes categorical columns:                                     │
│       protocol_type → integer (LabelEncoder)                        │
│       service       → integer (LabelEncoder)                        │
│       flag          → integer (LabelEncoder)                        │
│  5. Keeps only the 41 feature columns model needs                   │
│  6. Writes cleaned CSV to curated bucket                             │
│                                                                      │
│  Handler: etl_handler.lambda_handler                                 │
│  Code: lambda_etl_function/etl_handler.py                           │
│  Layer: intrusion-sklearn-pandas:2 (pandas + sklearn + joblib)      │
└──────────────────────────┬───────────────────────────────────────────┘
                           │  Writes CSV to curated bucket
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│          S3 CURATED BUCKET                                           │
│  intrusion-detection-curated-509399621479                            │
│  • Stores cleaned, encoded CSV files                                 │
│  • Path format: curated/<original_filename>.csv                      │
└──────────────────────────┬───────────────────────────────────────────┘
                           │  S3 trigger (suffix: .csv) → fires automatically
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│          SCORING LAMBDA:  intrusion-scoring-fn                       │
│  Runtime: Python 3.11 | Memory: 512MB | Timeout: 60s                │
│                                                                      │
│  1. Downloads cleaned CSV from curated bucket                        │
│  2. Loads isolation_forest_model.pkl from Models bucket              │
│  3. Runs Isolation Forest:                                           │
│       model.decision_function(X) → anomaly scores                   │
│       model.predict(X)           → -1 = anomaly, 1 = normal        │
│  4. Counts anomalies (predict == -1)                                 │
│  5. If anomalies > 0: publishes SNS alert                           │
│                                                                      │
│  Handler: handler.lambda_handler                                     │
│  Code: lambda_function/handler.py                                    │
│  Layer: intrusion-sklearn-pandas:2 (pandas + sklearn + joblib)      │
└──────────────────────────┬───────────────────────────────────────────┘
                           │  SNS publish (if anomalies found)
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│          AWS SNS TOPIC:  security-alerts                             │
│  ARN: arn:aws:sns:us-east-1:509399621479:security-alerts            │
│  Protocol: Email                                                     │
└──────────────────────────┬───────────────────────────────────────────┘
                           │  Email sent automatically
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│          EMAIL ALERT (apjangid330@gmail.com)                         │
│                                                                      │
│  Subject: [Alert] N anomalous connections detected                   │
│  Body:                                                               │
│    Anomalous network activity detected in curated/final.csv          │
│    Anomalies found: 11,352                                           │
│    Preview (first 20):                                               │
│    duration  src_bytes  dst_bytes  count  anomaly_score             │
│       0        491       0         511      -0.182                   │
│       ...                                                            │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 📦 ML Model Details

### Model: Isolation Forest

| Parameter | Value |
|---|---|
| Algorithm | Isolation Forest |
| n_estimators | 200 trees |
| contamination | 0.09 (9% anomalies expected) |
| random_state | 42 |
| Features | 41 (numeric + encoded categoricals) |
| Training data | 2000 normal + 200 attack samples (from NSL-KDD) |

### Dataset: NSL-KDD

- **Source:** NSL-KDD network intrusion dataset (standard benchmark)
- **Full file:** `scripts/nsl_kdd_train.txt` — 125,973 rows
- **Format:** 42 columns, no header, comma-separated
- **Labels:** `normal` vs various attack types (DoS, Probe, R2L, U2R)
- **Training script:** `scripts/train_and_save_model.py`

### Feature Columns (41 total)
```
duration, protocol_type*, service*, flag*, src_bytes, dst_bytes, land,
wrong_fragment, urgent, hot, num_failed_logins, logged_in, num_compromised,
root_shell, su_attempted, num_root, num_file_creations, num_shells,
num_access_files, num_outbound_cmds, is_host_login, is_guest_login, count,
srv_count, serror_rate, srv_serror_rate, rerror_rate, srv_rerror_rate,
same_srv_rate, diff_srv_rate, srv_diff_host_rate, dst_host_count,
dst_host_srv_count, dst_host_same_srv_rate, dst_host_diff_srv_rate,
dst_host_same_src_port_rate, dst_host_srv_diff_host_rate,
dst_host_serror_rate, dst_host_srv_serror_rate, dst_host_rerror_rate,
dst_host_srv_rerror_rate
```
`*` = categorical columns (LabelEncoder se encoded)

### Saved Model Artifacts
| File | Location | Size | Purpose |
|---|---|---|---|
| `isolation_forest_model.pkl` | `model_artifacts/` + S3 models bucket | ~1.6 MB | Trained IsolationForest model |
| `label_encoders.pkl` | `model_artifacts/` + S3 models bucket | small | LabelEncoder for 3 categorical cols |
| `feature_columns.pkl` | `model_artifacts/` + S3 models bucket | small | List of 41 feature column names |

---

## ☁️ AWS Resources Created

### S3 Buckets
| Bucket Name | Purpose |
|---|---|
| `intrusion-detection-raw-509399621479` | Raw CSV uploads (input) |
| `intrusion-detection-curated-509399621479` | Cleaned CSV files (ETL output) |
| `intrusion-detection-models-509399621479` | ML model .pkl files |

### IAM Roles
| Role Name | Used By | Permissions |
|---|---|---|
| `intrusion-detection-etl-lambda-role` | `intrusion-etl-fn` | S3 read (raw), S3 write (curated + models), CloudWatch Logs |
| `intrusion-detection-lambda-role` | `intrusion-scoring-fn` | S3 read (curated + models), SNS publish, CloudWatch Logs |

**Trust policy:** Both roles allow `lambda.amazonaws.com` to assume them.  
**Policy files:** `iam_policies/iam_lambda_etl_role_policy.json`, `iam_policies/iam_lambda_role_policy.json`

### Lambda Functions
| Function | Handler File | Memory | Timeout | Layer |
|---|---|---|---|---|
| `intrusion-etl-fn` | `lambda_etl_function/etl_handler.py` | 512 MB | 60s | `intrusion-sklearn-pandas:2` ✅ |
| `intrusion-scoring-fn` | `lambda_function/handler.py` | 512 MB | 60s | `intrusion-sklearn-pandas:2` (verify) |

**Environment Variables:**

`intrusion-etl-fn`:
```
CURATED_BUCKET = intrusion-detection-curated-509399621479
MODEL_BUCKET   = intrusion-detection-models-509399621479
ENCODERS_KEY   = label_encoders.pkl
FEATURES_KEY   = feature_columns.pkl
```

`intrusion-scoring-fn`:
```
MODEL_BUCKET          = intrusion-detection-models-509399621479
MODEL_KEY             = isolation_forest_model.pkl
FEATURES_KEY          = feature_columns.pkl
SNS_TOPIC_ARN         = arn:aws:sns:us-east-1:509399621479:security-alerts
ANOMALY_SCORE_THRESHOLD = 0
```

### Lambda Layer: `intrusion-sklearn-pandas`
| Property | Value |
|---|---|
| Layer Name | `intrusion-sklearn-pandas` |
| Version | `:2` (current, working) |
| Contents | scikit-learn, joblib, pandas, numpy, python-dateutil, pytz, tzdata |
| Unzipped Size | ~150 MB (within 250 MB Lambda limit) |
| Compatible Runtime | python3.11 |
| Built On | Windows 10 using pip manylinux flags |

**Layer v1** (broken): Had numpy tests folder deleted → `No module named 'numpy._core.tests'` error  
**Layer v2** (current): Only deleted `__pycache__` and `.dist-info` folders — numpy tests kept ✅

### S3 Triggers (Event Notifications)
| Bucket | Trigger Type | Target Lambda | Filter |
|---|---|---|---|
| `intrusion-detection-raw-509399621479` | `s3:ObjectCreated:*` | `intrusion-etl-fn` | None (any file) |
| `intrusion-detection-curated-509399621479` | `s3:ObjectCreated:*` | `intrusion-scoring-fn` | Suffix: `.csv` |

### SNS Topic
| Property | Value |
|---|---|
| Topic Name | `security-alerts` |
| ARN | `arn:aws:sns:us-east-1:509399621479:security-alerts` |
| Protocol | Email |
| Subscriber | `apjangid330@gmail.com` ✅ (confirmed) |

---

## 🔧 Lambda Layer — Full Build Process

Lambda ka 250 MB unzipped size limit hai. `pandas + scikit-learn + pyarrow` = **~350 MB** — limit exceed karta tha.

### Approaches Tried (and Why They Failed)

#### ❌ Approach 1: Klayers (Pre-built Public Layers)
```
# scikit-learn for Python 3.11 — checked via API
https://api.klayers.cloud/api/v2/p3.11/layers/latest/us-east-1/
# Result: scikit-learn NOT listed ❌
# pyarrow NOT listed ❌
# Only pandas:22 available
```
**Problem:** Klayers mein scikit-learn aur pyarrow Python 3.11 ke liye available nahi hain.

#### ❌ Approach 2: Bundle Everything in Zip
```powershell
pip install pandas scikit-learn pyarrow --target ./package
# package folder = ~350 MB unzipped
# Lambda zip limit = 250 MB
# Error: Unzipped size must be smaller than 262144000 bytes
```
**Problem:** Too large.

#### ❌ Approach 3: Use Parquet Format (requires pyarrow)
- Plan was: ETL Lambda saves Parquet, Scoring Lambda reads Parquet
- pyarrow alone = ~100 MB, combined with pandas+sklearn = >250 MB
- **Fix:** Changed to CSV format → pyarrow dependency completely removed

#### ❌ Approach 4: AWS CloudShell
- New AWS account verification 1-2 din tak pending tha
- CloudShell blocked (new account restriction)

#### ❌ Approach 5: WSL (Alpine Linux)
- No `apt-get`, no `pip` by default in Alpine
- Not productive without setup time

#### ✅ Final Solution: Custom Layer via Windows pip + manylinux flags

**Step 1: Install Linux-compatible packages on Windows**
```powershell
mkdir python
python -m pip install scikit-learn joblib pandas `
  --target python `
  --platform manylinux2014_x86_64 `
  --only-binary=:all: `
  --python-version 3.11 `
  --implementation cp `
  --abi cp311
```
> `manylinux2014_x86_64` = Linux x86_64 compatible wheels  
> `--only-binary=:all:` = no source compilation (Windows pe cross-compile nahi ho sakta)

**Step 2: Slim down (delete only safe folders)**
```powershell
# ONLY delete these — NEVER delete tests/ folders
Get-ChildItem python -Include __pycache__ -Recurse -Directory | Remove-Item -Recurse -Force
Get-ChildItem python -Include *.dist-info -Recurse -Directory | Remove-Item -Recurse -Force
# numpy._core.tests is internally required — do NOT delete
```

**Step 3: Zip in Lambda-required structure**
```powershell
# Lambda expects: python/sklearn/... python/pandas/... etc.
Compress-Archive -Path python -DestinationPath sklearn_v2.zip -Force
# Result: ~120 MB zip (~150 MB unzipped — fits in 250 MB limit!)
```

**Step 4: Upload to S3 (direct fileb:// timed out for 120 MB)**
```powershell
aws s3 cp sklearn_v2.zip s3://intrusion-detection-models-509399621479/sklearn_v2.zip --region us-east-1
```

**Step 5: Publish layer from S3**
```powershell
aws lambda publish-layer-version `
  --layer-name intrusion-sklearn-pandas `
  --content S3Bucket=intrusion-detection-models-509399621479,S3Key=sklearn_v2.zip `
  --compatible-runtimes python3.11 `
  --region us-east-1
# → Created intrusion-sklearn-pandas:2 ✅
```

**Step 6: Attach layer to ETL Lambda**
```powershell
$L = "arn:aws:lambda:us-east-1:509399621479:layer:intrusion-sklearn-pandas:2"
aws lambda update-function-configuration `
  --function-name intrusion-etl-fn `
  --layers "$L" `
  --region us-east-1
```

---

## 📂 Project Files Reference

```
project/
│
├── DEPLOYMENT_REPORT.md              ← Yahi file (full deployment notes)
├── BUILD_GUIDE.md                    ← Manual step-by-step guide
├── README.md                         ← Project overview
│
├── lambda_etl_function/
│   └── etl_handler.py                ← ETL Lambda handler (cleans CSV, encodes, writes curated)
│
├── lambda_function/
│   └── handler.py                    ← Scoring Lambda handler (Isolation Forest + SNS alert)
│
├── model_artifacts/
│   ├── isolation_forest_model.pkl    ← Trained IsolationForest model (1.6 MB)
│   ├── label_encoders.pkl            ← LabelEncoders for protocol_type, service, flag
│   └── feature_columns.pkl           ← List of 41 feature column names
│
├── scripts/
│   ├── train_and_save_model.py       ← Model training script (run locally)
│   ├── nsl_kdd_train.txt             ← NSL-KDD dataset (125,973 rows)
│   ├── deploy_windows.ps1            ← Full PowerShell deployment script
│   ├── cleanup_windows.ps1           ← Removes all AWS resources
│   └── package_lambda.sh             ← Linux packaging script (reference)
│
├── iam_policies/
│   ├── iam_lambda_etl_role_policy.json   ← ETL Lambda permissions
│   ├── iam_lambda_role_policy.json       ← Scoring Lambda permissions
│   └── lambda_trust_policy.json          ← Trust policy (lambda.amazonaws.com)
│
├── glue_job/
│   └── intrusion_detection_etl.py    ← Old Glue script (NOT USED — replaced by Lambda ETL)
│
├── ec2_dashboard/
│   └── dashboard.py                  ← Streamlit dashboard (optional visualization)
│
├── etl_only.zip                      ← Lambda zip (etl_handler.py only, ~5 KB)
├── scoring_only.zip                  ← Lambda zip (handler.py only, ~5 KB)
├── sklearn_v2.zip                    ← Custom layer zip (~120 MB)
└── python/                           ← Layer source (scikit-learn, pandas, joblib, numpy...)
```

---

## 🕐 Complete Timeline: Kya Kiya Step-by-Step

| Step | Action | Result |
|---|---|---|
| 1 | Local env setup: Python 3.13, pandas, sklearn, joblib verified | ✅ |
| 2 | `train_and_save_model.py` run → 3 .pkl files created | ✅ |
| 3 | AWS CLI configured (Access Key, us-east-1) | ✅ |
| 4 | 3 S3 buckets created (raw, curated, models) | ✅ |
| 5 | 3 .pkl model files uploaded to models bucket | ✅ |
| 6 | SNS topic `security-alerts` created | ✅ |
| 7 | Email subscription confirmed (apjangid330@gmail.com) | ✅ |
| 8 | IAM roles created (etl-role, scoring-role) | ✅ |
| 9 | Tried Klayers for sklearn/pyarrow → NOT available for Python 3.11 | ❌ |
| 10 | Tried bundling all deps in zip → 350 MB > 250 MB limit | ❌ |
| 11 | Switched from Parquet → CSV format (removed pyarrow dependency) | ✅ |
| 12 | Built custom layer on Windows with manylinux flags | ✅ |
| 13 | Layer v1 failed: `numpy._core.tests` module missing (deleted tests folder) | ❌ |
| 14 | Layer v2 built: only deleted `__pycache__` and `.dist-info` | ✅ |
| 15 | Uploaded 120 MB layer zip to S3 (direct fileb:// timed out) | ✅ |
| 16 | Published `intrusion-sklearn-pandas:2` layer | ✅ |
| 17 | Attached layer to `intrusion-etl-fn` via CLI | ✅ |
| 18 | Fixed env var bug: `MODEL_BUCKET` had trailing space → `Invalid bucket name` | ✅ |
| 19 | ETL Lambda + Scoring Lambda deployed (handler-only zips, ~5 KB each) | ✅ |
| 20 | S3 triggers wired (raw → ETL, curated → scoring with .csv suffix) | ✅ |
| 21 | Uploaded test file: `nsl_kdd_train.txt` → `s3://raw-bucket/final.csv` | ✅ |
| 22 | ETL Lambda fired: logs confirmed `[ETL Lambda] Processing s3://...` | ✅ |
| 23 | sklearn 1.8.0 vs 1.7.2 version warning appeared (non-fatal, acceptable) | ⚠️ |
| 24 | Scoring Lambda execution + email confirmation pending | 🔄 |

---

## ⚠️ Errors Encountered & Fixes

| Error | Root Cause | Fix |
|---|---|---|
| `AccessDeniedException` on Klayers | Wrong layer version numbers tried (11, 12, 3) | Checked API — sklearn/pyarrow NOT available for py3.11 |
| `Unzipped size must be smaller than 262144000 bytes` | sklearn+pyarrow+pandas = ~350 MB | Removed pyarrow, switched to CSV format |
| `No module named 'joblib'` | Layer not attached (console save failed silently) | Attached via CLI: `aws lambda update-function-configuration --layers` |
| `Invalid bucket name "...models-509399621479 "` | Trailing space in MODEL_BUCKET env var | Fixed via `aws lambda update-function-configuration --environment` |
| `No module named 'numpy._core.tests'` | Deleted `tests/` dirs during layer size reduction | Rebuild layer v2 keeping tests, only delete `__pycache__` and `.dist-info` |
| `InconsistentVersionWarning sklearn 1.8.0 vs 1.7.2` | Model trained locally on 1.8.0, layer has 1.7.2 | Non-fatal warning — pipeline proceeds normally |
| `curl -L` fails in PowerShell | PS aliases `curl` to `Invoke-WebRequest` | Used `curl.exe -L` or `Invoke-WebRequest -Uri` |
| `-- More --` pager blocking CLI | AWS CLI pager enabled by default | `aws configure set cli_pager ""` |
| Direct zip upload timeout | 120 MB zip too large for `fileb://` direct upload | Upload to S3 first → `--content S3Bucket=...,S3Key=...` |
| CloudShell blocked | New account verification pending (1-2 days) | Used Windows PowerShell + pip manylinux approach instead |

---

## 🧪 How to Test (End-to-End)

### 1. Upload test file
```powershell
aws s3 cp scripts\nsl_kdd_train.txt s3://intrusion-detection-raw-509399621479/test_run.csv --region us-east-1
```

### 2. Watch ETL Lambda logs (real-time)
```powershell
aws configure set cli_pager ""
aws logs tail /aws/lambda/intrusion-etl-fn --follow --region us-east-1
```
**Expected output:**
```
[ETL Lambda] Processing s3://intrusion-detection-raw-509399621479/test_run.csv
[ETL Lambda] Wrote 125973 cleaned rows to s3://intrusion-detection-curated-.../curated/test_run.csv
```

### 3. Watch Scoring Lambda logs
```powershell
aws logs tail /aws/lambda/intrusion-scoring-fn --follow --region us-east-1
```
**Expected output:**
```
Processed 125973 rows, found ~11000 anomalies
SNS published to arn:aws:sns:us-east-1:509399621479:security-alerts
```

### 4. Check email
- Inbox: `apjangid330@gmail.com`
- Subject: `[Alert] XXXXX anomalous connections detected`
- Contains: anomaly preview table with scores

---

## ✅ What Is Done

- [x] ML Model trained (IsolationForest, 41 features, NSL-KDD)
- [x] 3 S3 buckets created
- [x] Model files uploaded to S3
- [x] SNS topic + email subscription (confirmed)
- [x] IAM roles created with correct policies
- [x] ETL Lambda deployed (`intrusion-etl-fn`)
- [x] Scoring Lambda deployed (`intrusion-scoring-fn`)
- [x] Custom Lambda Layer built (`intrusion-sklearn-pandas:2`, ~150 MB)
- [x] Layer attached to ETL Lambda ✅
- [x] S3 triggers wired (raw → ETL, curated → scoring)
- [x] ETL Lambda fired successfully (confirmed in logs)
- [x] Format changed: Parquet → CSV (removed pyarrow dependency)

---

## 🔄 What Is Remaining / To Verify

| Item | Command | Priority |
|---|---|---|
| Attach layer to Scoring Lambda | See command below | 🔴 HIGH |
| Verify Scoring Lambda env vars (no trailing spaces) | See command below | 🔴 HIGH |
| End-to-end test: upload → ETL → scoring → email | `aws s3 cp ... final.csv` | 🟡 MEDIUM |
| Email received with anomaly alert | Check inbox | 🟡 MEDIUM |

### Fix Scoring Lambda Layer (run this now):
```powershell
# Get latest layer ARN
$L = (aws lambda list-layer-versions --layer-name intrusion-sklearn-pandas --query "LayerVersions[0].LayerVersionArn" --output text --region us-east-1)
Write-Host "Layer ARN: $L"

# Attach to scoring Lambda
aws lambda update-function-configuration --function-name intrusion-scoring-fn --layers "$L" --region us-east-1
```

### Fix Scoring Lambda env vars (run this):
```powershell
aws lambda update-function-configuration `
  --function-name intrusion-scoring-fn `
  --environment "Variables={MODEL_BUCKET=intrusion-detection-models-509399621479,SNS_TOPIC_ARN=arn:aws:sns:us-east-1:509399621479:security-alerts}" `
  --region us-east-1
```

---

## 💰 Cost Summary (AWS Free Tier)

| Service | Free Tier Limit | Our Usage | Cost |
|---|---|---|---|
| S3 Storage | 5 GB / month | ~50 MB | **$0** |
| S3 Requests | 20,000 GET, 2,000 PUT | <100 requests | **$0** |
| Lambda Requests | 1,000,000 / month | ~10 invocations | **$0** |
| Lambda Duration | 400,000 GB-sec / month | <1 GB-sec | **$0** |
| SNS Email | 1,000 emails / month | <10 emails | **$0** |
| CloudWatch Logs | 5 GB ingestion | <1 MB | **$0** |
| IAM | Always free | 2 roles | **$0** |
| **TOTAL** | | | **$0** |

> ⚠️ Note: AWS Glue was originally planned but dropped — Glue has **no free tier** (bills per DPU-hour from first run). Lambda replaced it completely at $0 cost.

---

## 🧹 Cleanup (When Done)

Sab kuch delete karna ho toh:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\cleanup_windows.ps1
```

Ya manually:
```powershell
aws s3 rb s3://intrusion-detection-raw-509399621479 --force --region us-east-1
aws s3 rb s3://intrusion-detection-curated-509399621479 --force --region us-east-1
aws s3 rb s3://intrusion-detection-models-509399621479 --force --region us-east-1
aws lambda delete-function --function-name intrusion-etl-fn --region us-east-1
aws lambda delete-function --function-name intrusion-scoring-fn --region us-east-1
aws sns delete-topic --topic-arn arn:aws:sns:us-east-1:509399621479:security-alerts --region us-east-1
aws iam delete-role-policy --role-name intrusion-detection-etl-lambda-role --policy-name etl-lambda-policy
aws iam delete-role --role-name intrusion-detection-etl-lambda-role
aws iam delete-role-policy --role-name intrusion-detection-lambda-role --policy-name scoring-lambda-policy
aws iam delete-role --role-name intrusion-detection-lambda-role
```

---

## 📋 Presentation Summary (College Submission)

**What we built:** End-to-end serverless ML pipeline on AWS for real-time network intrusion detection

**Input:** Network traffic logs (NSL-KDD format CSV)  
**Output:** Automated email alerts when anomalies detected

**Key decisions:**
1. **Lambda over Glue** — Glue costs money; Lambda is free
2. **CSV over Parquet** — removed pyarrow (too large for Lambda layer)
3. **Custom Layer** — Klayers didn't have sklearn for Python 3.11
4. **IsolationForest** — unsupervised ML; doesn't need labeled attack data at inference time
5. **Windows-compatible deployment** — manylinux pip flags, no WSL/Docker needed

**Tech complexity demonstrated:**
- Event-driven serverless architecture
- Custom Lambda Layer build process (cross-platform pip compilation)
- ML model deployment on AWS
- Automated alerting pipeline

---

*Report last updated: November 24, 2026 | Account: 509399621479 | Region: us-east-1*
