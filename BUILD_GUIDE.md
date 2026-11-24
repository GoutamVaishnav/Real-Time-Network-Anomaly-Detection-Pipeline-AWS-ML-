# Building the Real-Time Intrusion Detection Pipeline — Complete Step-by-Step Guide
### (100% AWS Free Tier version — no AWS Glue, no paid services)

This version replaces AWS Glue (which bills per DPU-hour with no free tier)
with a second Lambda function that does the same cleaning/encoding job.
Every service used here — S3, Lambda (x2), SNS, IAM, and EC2 within its
750-hour/month allowance — is free, indefinitely, within normal usage.

**Time estimate:** 3-4 hours for a first pass.

---

## Part 0: Before you touch AWS

### 0.1 Create your local project folder
```bash
mkdir intrusion-detection-project
cd intrusion-detection-project
```

### 0.2 Install Python and required libraries
```bash
python3 --version
```
Need 3.9+. Then:
```bash
pip install pandas scikit-learn joblib pyarrow boto3 --break-system-packages
```

### 0.3 Unzip the project files
Unzip `intrusion_detection_pipeline.zip` so you have:
```
intrusion-detection-project/
└── project/
    ├── README.md
    ├── BUILD_GUIDE.md
    ├── lambda_etl_function/       <- replaces Glue
    ├── lambda_function/           <- scoring Lambda (unchanged)
    ├── ec2_dashboard/
    ├── model_artifacts/
    ├── iam_policies/
    ├── glue_job/                  <- kept for reference only, NOT used in this version
    └── scripts/
```

### 0.4 Download the training dataset
```bash
cd project/scripts
curl -sL -o nsl_kdd_train.txt "https://raw.githubusercontent.com/jmnwong/NSL-KDD-Dataset/master/KDDTrain%2B.txt"
wc -l nsl_kdd_train.txt   # should show 125973
```

### 0.5 Train the model locally
```bash
python3 train_and_save_model.py
```
Confirms with: `Saved: isolation_forest_model.pkl, label_encoders.pkl, feature_columns.pkl`

---

## Part 1: AWS account and CLI setup

### 1.1 Create your AWS account (skip if you have one)
1. Go to **aws.amazon.com** → click **Create an AWS Account** (top-right)
2. Enter email, verify it via the code sent to your inbox
3. Set a root password → **Continue**
4. Choose **Personal** account type, fill in your details → **Continue**
5. Enter payment card (required even for free tier) → **Verify and Continue**
6. Verify phone number via SMS/call → **Continue**
7. Select **Basic support plan — Free** → **Complete sign up**
8. Click **Go to the AWS Management Console**

### 1.2 Set your region
Top-right corner of the console → click the region dropdown → select
**US East (N. Virginia) us-east-1**. Use this region for everything below.

### 1.3 Set a billing alert immediately (important for peace of mind)
1. Click your account name (top-right) → **Billing and Cost Management**
2. In the left sidebar, click **Budgets**
3. Click **Create budget**
4. Choose **Zero spend budget** (a template built exactly for this) → **Use a template**
5. Enter your email under **Email recipients**
6. Click **Create budget**

This emails you the instant any charge occurs — since this whole build should
be $0, you'll know immediately if something's misconfigured.

### 1.4 Install and configure the AWS CLI
1. Download from `aws.amazon.com/cli` for your OS, run the installer
2. Confirm: `aws --version`
3. In the console: your account name (top-right) → **Security credentials**
4. Scroll to **Access keys** → **Create access key**
5. Select **Command Line Interface (CLI)** → check the box → **Next** → **Create access key**
6. Copy both keys now (secret is shown once) — click **Download .csv file**
7. In your terminal:
   ```bash
   aws configure
   ```
   Paste the Access Key ID, Secret Access Key, type `us-east-1`, then `json`

---

## Part 2: Create the S3 buckets

You need 3 buckets now (raw, curated, models) — one fewer than the Glue
version, since there's no separate script bucket needed.

### 2.1 Find your Account ID
Click your account name (top-right) — the 12-digit ID is shown there.

### 2.2 Create the buckets
1. Search bar → type **S3** → click the **S3** result
2. Click **Create bucket**
3. Bucket name: `intrusion-detection-raw-<your-account-id>`
4. Leave region and **Block all public access** at defaults
5. Scroll down → **Create bucket**
6. Repeat for:
   - `intrusion-detection-curated-<your-account-id>`
   - `intrusion-detection-models-<your-account-id>`

### 2.3 Upload the model artifacts
1. Click into `intrusion-detection-models-<your-account-id>`
2. Click **Upload** → **Add files**
3. Select all three files from your local `project/model_artifacts/` folder
   (`isolation_forest_model.pkl`, `label_encoders.pkl`, `feature_columns.pkl`)
4. Click **Open** → scroll down → **Upload**

---

## Part 3: Create the SNS alert topic

1. Search bar → **SNS** → click the result
2. Left sidebar → **Topics** → **Create topic**
3. Type: **Standard**, Name: `security-alerts`
4. Scroll down → **Create topic**
5. Copy the **ARN** shown at the top of the topic page — you'll need it soon

### 3.1 Subscribe your email
1. On the topic page, click **Create subscription**
2. Protocol: **Email**, Endpoint: your email address
3. Click **Create subscription**
4. Check your inbox, open the AWS Notifications email, click **Confirm subscription**
5. Back in the console, refresh — status should show **Confirmed**

---

## Part 4: Create IAM roles

You need two roles now: one for the ETL Lambda, one for the scoring Lambda.

### 4.1 Create the ETL Lambda role
1. Search bar → **IAM** → **Roles** → **Create role**
2. Trusted entity type: **AWS service**
3. Use case: **Lambda** → **Next**
4. Skip attaching managed policies → **Next**
5. Role name: `intrusion-detection-etl-lambda-role` → **Create role**
6. Click into the new role → **Add permissions** dropdown → **Create inline policy**
7. Click the **JSON** tab, delete the placeholder, paste in the full contents
   of your local `project/iam_policies/iam_lambda_etl_role_policy.json`
8. Click **Next** → name it `intrusion-detection-etl-lambda-policy` → **Create policy**

### 4.2 Create the scoring Lambda role
1. **Roles** → **Create role** → Use case: **Lambda** → **Next** → **Next**
2. Role name: `intrusion-detection-lambda-role` → **Create role**
3. Click into it → **Add permissions** → **Create inline policy** → **JSON** tab
4. Paste in `project/iam_policies/iam_lambda_role_policy.json`
5. **Next** → name it `intrusion-detection-lambda-policy` → **Create policy**

---

## Part 5: Package and deploy the ETL Lambda (replaces Glue)

### 5.1 Build the deployment package
```bash
cd intrusion-detection-project/project
chmod +x scripts/package_lambda.sh
bash scripts/package_lambda.sh etl
```
Wait for `Package created: etl_lambda_deployment_package.zip`

### 5.2 Create the function in the console
1. Search bar → **Lambda** → **Create function**
2. Leave **Author from scratch** selected
3. Function name: `intrusion-etl-fn`
4. Runtime: **Python 3.11**
5. Click **Change default execution role** → **Use an existing role** → select `intrusion-detection-etl-lambda-role`
6. Click **Create function**

### 5.3 Upload the code
1. On the function page, scroll to **Code source**
2. Click **Upload from** (top-right of the panel) → **.zip file**
3. Click **Upload**, select `etl_lambda_deployment_package.zip` → **Save**
4. Wait for the upload to complete

### 5.4 Set the handler
1. **Runtime settings** panel → **Edit**
2. Handler: `etl_handler.lambda_handler`
3. **Save**

### 5.5 Set environment variables
1. **Configuration** tab → **Environment variables** → **Edit**
2. Add: Key `CURATED_BUCKET`, Value `intrusion-detection-curated-<your-account-id>`
3. Add: Key `MODEL_BUCKET`, Value `intrusion-detection-models-<your-account-id>`
4. **Save**

### 5.6 Increase timeout and memory
1. **Configuration** → **General configuration** → **Edit**
2. Memory: `512` MB, Timeout: `1` min `0` sec
3. **Save**

---

## Part 6: Package and deploy the scoring Lambda

### 6.1 Build the deployment package
```bash
bash scripts/package_lambda.sh scoring
```
Wait for `Package created: scoring_lambda_deployment_package.zip`

### 6.2 Create the function
1. **Lambda** → **Create function** → **Author from scratch**
2. Function name: `intrusion-scoring-fn`
3. Runtime: **Python 3.11**
4. **Change default execution role** → **Use an existing role** → `intrusion-detection-lambda-role`
5. **Create function**

### 6.3 Upload the code
1. **Code source** → **Upload from** → **.zip file**
2. Select `scoring_lambda_deployment_package.zip` → **Save**

### 6.4 Set the handler
1. **Runtime settings** → **Edit** → Handler: `handler.lambda_handler` → **Save**

### 6.5 Set environment variables
1. **Configuration** → **Environment variables** → **Edit**
2. Add: Key `MODEL_BUCKET`, Value `intrusion-detection-models-<your-account-id>`
3. Add: Key `SNS_TOPIC_ARN`, Value (paste the ARN from Part 3)
4. **Save**

### 6.6 Increase timeout and memory
1. **Configuration** → **General configuration** → **Edit**
2. Memory: `512` MB, Timeout: `1` min `0` sec → **Save**

---

## Part 7: Wire the S3 triggers (both of them)

### 7.1 Raw bucket → ETL Lambda
1. **S3** console → click into `intrusion-detection-raw-<your-account-id>`
2. **Properties** tab → scroll to **Event notifications** → **Create event notification**
3. Event name: `trigger-etl-lambda`
4. Event types: check **All object create events**
5. Destination: **Lambda function** → select `intrusion-etl-fn`
6. **Save changes**

### 7.2 Curated bucket → scoring Lambda
1. Click into `intrusion-detection-curated-<your-account-id>`
2. **Properties** → **Event notifications** → **Create event notification**
3. Event name: `trigger-scoring-lambda`
4. Suffix: `.parquet`
5. Event types: check **All object create events**
6. Destination: **Lambda function** → select `intrusion-scoring-fn`
7. **Save changes**

---

## Part 8: Test the whole pipeline end to end

This is now fully automatic — no manual job to run, unlike the Glue version.

### 8.1 Upload a test batch
```bash
cd intrusion-detection-project
aws s3 cp project/scripts/nsl_kdd_train.txt s3://intrusion-detection-raw-<your-account-id>/batch_001.csv
```

### 8.2 Watch it flow through automatically
1. Within seconds, the ETL Lambda should fire. Check: **Lambda** console →
   `intrusion-etl-fn` → **Monitor** tab → **View CloudWatch logs** → click the
   most recent log stream → confirm it shows rows processed and a curated
   file written
2. That curated write triggers the scoring Lambda automatically. Check:
   **Lambda** console → `intrusion-scoring-fn` → **Monitor** → **View
   CloudWatch logs** → confirm it shows connections scored and anomalies found

### 8.3 Check your email
If anomalies were found, you'll get an email from AWS Notifications within a
minute or two, subject `[Alert] N anomalous connections detected`.

### 8.4 If nothing happened
See the troubleshooting table at the bottom — most issues at this stage are
either the S3 trigger not saved correctly, or an IAM permission typo.

---

## Part 9: Launch the EC2 dashboard instance

### 9.1 Create an IAM instance profile for EC2
1. **IAM** → **Roles** → **Create role**
2. Use case: **EC2** → **Next** → skip managed policies → **Next**
3. Name: `intrusion-detection-ec2-role` → **Create role**
4. Click into it → **Add permissions** → **Create inline policy** → **JSON** tab
5. Paste in `project/iam_policies/iam_ec2_dashboard_role_policy.json`
6. **Next** → name it `intrusion-detection-ec2-policy` → **Create policy**

### 9.2 Launch the instance
1. **EC2** console → **Launch instance**
2. Name: `intrusion-detection-dashboard`
3. Application and OS Images: leave **Amazon Linux** default
4. Instance type: **t3.micro** (free-tier eligible)
5. Key pair: **Create new key pair** if needed — name it, RSA, `.pem` format, **Create key pair** (downloads a file, keep it safe)
6. Network settings → **Edit** → check **Allow SSH traffic from** → **My IP**;
   check **Allow HTTP traffic from the internet** (needed to view the dashboard)
7. **Advanced details** → expand → **IAM instance profile** → select `intrusion-detection-ec2-role`
8. Scroll down → **Launch instance**
9. Click **View all instances**, wait for status **Running**, note the **Public IPv4 address**

### 9.3 Connect and upload the dashboard files
1. Check the box next to your instance → **Connect** (top of page)
2. **EC2 Instance Connect** tab → **Connect** (opens a browser terminal)
3. In the terminal:
   ```bash
   mkdir dashboard && cd dashboard
   nano dashboard.py
   ```
   Paste in the full contents of your local `project/ec2_dashboard/dashboard.py`,
   `Ctrl+O` then `Enter` to save, `Ctrl+X` to exit. Repeat for `run_dashboard.sh`.

   *(Or use SCP from your own computer instead:
   `scp -i intrusion-detection-key.pem project/ec2_dashboard/*.py project/ec2_dashboard/*.sh ec2-user@<public-ip>:~/dashboard/`)*

### 9.4 Run the dashboard
```bash
chmod +x run_dashboard.sh
./run_dashboard.sh
```
When prompted, type your curated bucket name
(`intrusion-detection-curated-<your-account-id>`) and press Enter. Wait for
`You can now view your Streamlit app in your browser`, then open
`http://<your-ec2-public-ip>` in a new tab.

### 9.5 Keep it running after disconnecting (optional)
```bash
nohup ~/.local/bin/streamlit run dashboard.py --server.port 80 --server.address 0.0.0.0 > dashboard.log 2>&1 &
```

---

## Part 10: Clean-up (do this when done — though this stack costs $0 even left running within free-tier limits)

1. **EC2**: Instances → select instance → **Instance state** → **Terminate instance**
2. **Lambda**: select `intrusion-etl-fn` and `intrusion-scoring-fn` → **Actions** → **Delete** (for each)
3. **S3**: each bucket → **Empty** (type "permanently delete" to confirm) → then **Delete**
4. **SNS**: Topics → `security-alerts` → **Delete**
5. **IAM roles**: delete the 3 roles you created (`etl-lambda-role`, `lambda-role`, `ec2-role`)

---

## Cost summary for this version

| Service | Usage in this project | Free tier | Cost |
|---|---|---|---|
| S3 (3 buckets) | A few MB | 5GB free | $0 |
| Lambda (x2 functions) | Dozens of test invocations | 1M requests/month, always free | $0 |
| SNS | A handful of test alerts | 1M notifications/month, always free | $0 |
| IAM | Roles and policies | Always free, unlimited | $0 |
| EC2 (t3.micro) | Running during testing | 750 hours/month free (12 months, or covered by new-account credits) | $0 |

**No AWS Glue is used in this version**, so there is no DPU-hour billing at
all. This entire pipeline can run indefinitely at $0 as long as you stay
within the limits above (which, for a portfolio project's test traffic, you
will by a wide margin).

---

## Troubleshooting quick reference

| Symptom | Likely cause |
|---|---|
| ETL Lambda never fires | Re-check Part 7.1 — event notification on the *raw* bucket must be saved and point to `intrusion-etl-fn` |
| Scoring Lambda never fires | Re-check Part 7.2 — the `.parquet` suffix filter must match what the ETL Lambda writes (it does, by default) |
| Lambda times out | Increase memory (Parts 5.6 / 6.6) — pandas/sklearn need more than the 128MB default |
| "Access Denied" reading model files | Confirm the ETL Lambda's IAM policy references the exact bucket name pattern — check for typos in the account ID |
| No email received | Check spam folder; re-confirm the SNS subscription (Part 3.1) |
| Package too large to upload | See the note printed by `package_lambda.sh` — switch to a Lambda Layer or container image if needed |

You now have a fully working, fully free, real-time pipeline — every request
runs on AWS's Always-Free Lambda tier, with no DPU-hour billing anywhere in
the architecture.
